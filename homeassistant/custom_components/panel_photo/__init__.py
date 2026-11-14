"""Panel Photo: re-renders Home Assistant image entities into wall-panel-ready JPEGs.

Each time a source image entity changes (e.g. an immich_frames slideshow), this
renders, per panel:

  full.jpg   screen-sized photo with a soft legibility scrim baked in
  clean.jpg  the same without the scrim
  soft.jpg   softened + dimmed (wallpaper behind tiles)
  frost.jpg  heavy blur, pixel-aligned with the screen: a client draws "frosted
             glass" by sampling its own patch of it (no live blur needed)
  tile.jpg   cover crop for a photo tile, rounded corners baked in

and serves them at /api/panel_photo/<key>/[<panel>/]<name>.jpg. Low-power panels
can't easily send HA auth headers, so the view is unauthenticated and the random
key in the path is the gate. JPEGs are baseline (small decoders can't do
progressive). After each render, sensor.panel_photo[_<panel>]_version is bumped
so clients know to re-download.

Photos whose shape fights the screen (portrait on landscape, or landscape on a
portrait panel) are fitted and feathered into a blur of themselves instead of
being cover-cropped; letterbox bars are trimmed first.

configuration (YAML, e.g. packages/panel_photo.yaml):

panel_photo:
  source: image.living_room_frame_image   # default panel, /api/panel_photo/<key>/<name>.jpg
  key: !secret panel_photo_key            # 16+ random characters
  width: 1024
  height: 600
  panels:                                 # optional extra panels, /<key>/<name>/...
    - name: kitchen
      source: image.kitchen_panel_image
      width: 720
      height: 1280
"""

from __future__ import annotations

import asyncio
import hmac
import io
import logging
import math

from aiohttp import web
import voluptuous as vol

from homeassistant.components.http import HomeAssistantView
from homeassistant.components.image import async_get_image
from homeassistant.const import EVENT_HOMEASSISTANT_STARTED
from homeassistant.core import CoreState, Event, HomeAssistant, callback
from homeassistant.helpers import config_validation as cv
from homeassistant.helpers.event import (
    async_track_state_change_event,
    async_track_time_interval,
)
from homeassistant.helpers.typing import ConfigType

from datetime import timedelta

_LOGGER = logging.getLogger(__name__)

DOMAIN = "panel_photo"
VERSION_ENTITY = "sensor.panel_photo_version"

PANEL_FIELDS = {
    vol.Required("source"): cv.entity_id,
    vol.Optional("width", default=1024): cv.positive_int,
    vol.Optional("height", default=600): cv.positive_int,
    vol.Optional("tile_width", default=480): cv.positive_int,
    vol.Optional("tile_height", default=320): cv.positive_int,
    vol.Optional("tile_x", default=24): cv.positive_int,
    vol.Optional("tile_y", default=86): cv.positive_int,
    vol.Optional("tile_radius", default=28): cv.positive_int,
}

CONFIG_SCHEMA = vol.Schema(
    {
        DOMAIN: vol.Schema(
            {
                **PANEL_FIELDS,
                vol.Required("key"): vol.All(cv.string, vol.Length(min=16)),
                vol.Optional("panels", default=[]): [
                    vol.Schema({vol.Required("name"): cv.slug, **PANEL_FIELDS})
                ],
            }
        )
    },
    extra=vol.ALLOW_EXTRA,
)


def _trim_letterbox(img):
    """Crop flat padding bars (immich_frames letterboxes to 1280x800)."""
    from PIL import ImageChops, Image

    rgb = img.convert("RGB")
    corner = rgb.getpixel((0, 0))
    bg = Image.new("RGB", rgb.size, corner)
    diff = ImageChops.difference(rgb, bg).convert("L").point(lambda p: 255 if p > 18 else 0)
    box = diff.getbbox()
    if not box:
        return rgb
    w, h = rgb.size
    bw, bh = box[2] - box[0], box[3] - box[1]
    # Only trim when it looks like bars, not a dark photo edge: bars run the
    # full length of one axis (pillarbox or letterbox), and what is left must
    # still be a real picture (a 9:16 phone shot is ~35% of a 16:10 frame).
    if not (bw >= w * 0.9 or bh >= h * 0.9) or bw * bh < 0.12 * w * h:
        return rgb
    return rgb.crop(box)


def _cover(img, w, h, focus_x=0.5, focus_y=0.5):
    from PIL import Image

    sw, sh = img.size
    scale = max(w / sw, h / sh)
    nw, nh = max(w, round(sw * scale)), max(h, round(sh * scale))
    img = img.resize((nw, nh), Image.LANCZOS)
    left = min(max(0, round((nw - w) * focus_x)), nw - w)
    top = min(max(0, round((nh - h) * focus_y)), nh - h)
    return img.crop((left, top, left + w, top + h))


def _mask(w, h, fn):
    """Build a smooth L mask by evaluating fn(u, v)->0..1 on a small grid."""
    from PIL import Image

    gw, gh = 96, 56
    m = Image.new("L", (gw, gh))
    px = m.load()
    for y in range(gh):
        for x in range(gw):
            px[x, y] = max(0, min(255, round(255 * fn(x / (gw - 1), y / (gh - 1)))))
    return m.resize((w, h), Image.BICUBIC)


def _darken(img, mask):
    from PIL import Image

    black = Image.new("RGB", img.size, (0, 0, 0))
    return Image.composite(black, img, mask)


def _jpeg(img, quality=88) -> bytes:
    buf = io.BytesIO()
    img.save(buf, "JPEG", quality=quality, progressive=False, optimize=False)
    return buf.getvalue()


def _render(raw: bytes, cfg: dict) -> dict[str, bytes]:
    from PIL import Image, ImageEnhance, ImageFilter

    from PIL import ImageDraw

    w, h = cfg["width"], cfg["height"]
    tw, th = cfg["tile_width"], cfg["tile_height"]
    src = _trim_letterbox(Image.open(io.BytesIO(raw)))
    tall_screen = h > w
    # A photo whose shape fights the screen gets the "fitted over its own
    # blur" treatment instead of a brutal cover crop.
    portrait = (not tall_screen) and src.size[0] / src.size[1] < 1.15
    wide_on_tall = tall_screen and src.size[0] / src.size[1] > 0.85

    cover = _cover(src, w, h)

    def heavy_blur(img, brightness, color=1.35):
        small = img.resize((w // 8, h // 8), Image.BILINEAR).filter(ImageFilter.GaussianBlur(4))
        out = small.resize((w, h), Image.BICUBIC).filter(ImageFilter.GaussianBlur(3))
        out = ImageEnhance.Color(out).enhance(color)
        return ImageEnhance.Brightness(out).enhance(brightness)

    if portrait:
        # The whole portrait photo flush right, its left edge feathered into
        # a blurred fill of itself; the clock sits over the fill on the left.
        scale = h / src.size[1]
        fitted = src.resize((max(1, round(src.size[0] * scale)), h), Image.LANCZOS)
        fw = fitted.size[0]
        clean = heavy_blur(cover, 0.8)
        feather = min(120, fw // 3)
        fmask = _mask(fw, h, lambda u, v: min(1.0, u * fw / feather))
        clean.paste(fitted, (w - fw, 0), fmask)
    elif wide_on_tall:
        # Landscape photo on a portrait screen: full width, centred a little
        # low (clock lives up top), top and bottom edges feathered into blur.
        scale = w / src.size[0]
        fitted = src.resize((w, max(1, round(src.size[1] * scale))), Image.LANCZOS)
        fh = fitted.size[1]
        clean = heavy_blur(cover, 0.8)
        feather = min(140, fh // 3)
        fmask = _mask(w, fh, lambda u, v: min(1.0, v * fh / feather, (1 - v) * fh / feather))
        clean.paste(fitted, (0, min(h - fh, round(h * 0.56 - fh / 2))), fmask)
    else:
        clean = cover

    # Frosted-glass source: every glass tile/pill on the panel shows its own
    # patch of this image, so it must stay pixel-aligned with `clean`.
    frost = heavy_blur(clean, 0.72)
    # Home/Climate wallpaper: the photo softened and dimmed, so frosted tiles
    # read as lighter panes floating over it.
    soft = clean.resize((w // 3, h // 3), Image.BILINEAR).filter(ImageFilter.GaussianBlur(1.5))
    soft = soft.resize((w, h), Image.BICUBIC)
    soft = ImageEnhance.Brightness(ImageEnhance.Color(soft).enhance(1.15)).enhance(0.5)

    # Photo face: soft radial scrim top-left (clock) + bottom band (captions).
    def scrim(u, v):
        radial = max(0.0, 1.0 - math.hypot(u / 0.62, v / 0.8)) * 0.62
        bottom = max(0.0, (v - 0.72) / 0.28) * 0.5
        top_right = max(0.0, 1.0 - math.hypot((1 - u) / 0.3, v / 0.2)) * 0.35
        return max(radial, bottom, top_right)

    full = _darken(clean, _mask(w, h, scrim))

    # Portraits: bias the crop up, where faces usually are.
    tile = _cover(src, tw, th, focus_x=0.55, focus_y=0.3 if (portrait or (tall_screen and not wide_on_tall)) else 0.5)
    tile = _darken(tile, _mask(tw, th, lambda u, v: max(0.0, (v - 0.55) / 0.45) * 0.62))
    # Bake the rounded corners against the exact patch of blur the tile sits
    # on, so the panel never has to clip (LVGL corner clipping is slow).
    tx, ty, r = cfg["tile_x"], cfg["tile_y"], cfg["tile_radius"]
    ss = 4
    mask = Image.new("L", (tw * ss, th * ss), 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, tw * ss - 1, th * ss - 1), r * ss, fill=255)
    mask = mask.resize((tw, th), Image.LANCZOS)
    tile = Image.composite(tile, soft.crop((tx, ty, tx + tw, ty + th)), mask)

    return {
        "clean": _jpeg(clean),
        "full": _jpeg(full),
        "soft": _jpeg(soft, 85),
        "frost": _jpeg(frost, 85),
        "tile": _jpeg(tile),
    }


class PanelPhotoView(HomeAssistantView):
    """Serve rendered JPEGs; the path key is the only gate."""

    url = "/api/panel_photo/{key}/{name}"
    extra_urls = ["/api/panel_photo/{key}/{panel}/{name}"]
    name = "api:panel_photo"
    requires_auth = False

    def __init__(self, store: dict) -> None:
        self._store = store

    async def get(self, request: web.Request, key: str, name: str, panel: str = "") -> web.Response:
        if not hmac.compare_digest(key, self._store["key"]):
            return web.Response(status=404)
        stem = name.removesuffix(".jpg")
        body = self._store["panels"].get(panel, {}).get(stem)
        if body is None:
            return web.Response(status=404)
        return web.Response(
            body=body,
            content_type="image/jpeg",
            headers={"Cache-Control": "no-store"},
        )


async def async_setup(hass: HomeAssistant, config: ConfigType) -> bool:
    cfg = config[DOMAIN]
    store: dict = {"key": cfg["key"], "panels": {}}
    hass.data[DOMAIN] = store
    hass.http.register_view(PanelPhotoView(store))

    panels = [("", {k: v for k, v in cfg.items() if k not in ("panels", "key")})]
    panels += [(p["name"], p) for p in cfg["panels"]]
    for name, pcfg in panels:
        _setup_panel(hass, store, name, pcfg)
    return True


def _setup_panel(hass: HomeAssistant, store: dict, name: str, cfg: dict) -> None:
    lock = asyncio.Lock()
    pending = {"again": False}
    state = {"version": 0}
    entity = VERSION_ENTITY if not name else f"sensor.panel_photo_{name}_version"
    store["panels"][name] = {}

    async def _process() -> None:
        if lock.locked():
            pending["again"] = True
            return
        async with lock:
            while True:
                pending["again"] = False
                try:
                    image = await async_get_image(hass, cfg["source"], timeout=20)
                    rendered = await hass.async_add_executor_job(_render, image.content, cfg)
                except Exception as err:  # noqa: BLE001 - keep last good images
                    _LOGGER.warning("Panel photo render failed (%s): %s", name or "default", err)
                    break
                store["panels"][name] = rendered
                state["version"] += 1
                src_state = hass.states.get(cfg["source"])
                hass.states.async_set(
                    entity,
                    str(state["version"]),
                    {
                        "friendly_name": f"Panel Photo {name.title() + ' ' if name else ''}Version",
                        "icon": "mdi:image-sync",
                        "source": cfg["source"],
                        "source_state": src_state.state if src_state else None,
                        "size": f"{cfg['width']}x{cfg['height']}",
                        "bytes": {k: len(v) for k, v in rendered.items()},
                    },
                )
                if not pending["again"]:
                    break

    @callback
    def _changed(event: Event) -> None:
        new = event.data.get("new_state")
        if new is None or new.state in ("unavailable", "unknown"):
            return
        hass.async_create_task(_process())

    async_track_state_change_event(hass, [cfg["source"]], _changed)

    # Safety net: if a change event was missed, re-render every 10 minutes.
    async def _periodic(_now) -> None:
        await _process()

    async_track_time_interval(hass, _periodic, timedelta(minutes=10))

    async def _start(_event=None) -> None:
        await _process()

    if hass.state is CoreState.running:
        hass.async_create_task(_start())
    else:
        hass.bus.async_listen_once(EVENT_HOMEASSISTANT_STARTED, _start)
