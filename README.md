# Brilliant HomeView

An Apple HomeView-style photo face for **Brilliant** smart-home control panels, driven by
**Home Assistant**. A big clock, the weather, your photos with a frosted-glass caption, and
large "attention" chips that only appear when something needs you: an unlocked door, a
package waiting, the dryer finished. Tap a chip to act on it (lock the door, open the
package box). Whatever the room's Apple TV or Sonos is playing shows as a Now Playing card
with artwork; tap it for play/pause, skip, progress and volume. Touch a physical slider and
a level indicator follows your finger.

The panel's **physical cap-touch sliders keep working exactly as before**: Brilliant's own
app stays running, just invisibly.

> Unofficial. Not affiliated with Brilliant NextGen or Apple. You are modifying a device
> you own, as root; keep `uninstall.sh` handy.

## How it works

- **Brilliant's UI keeps running, offscreen.** A systemd drop-in starts Brilliant's
  `switch-ui` with `QT_QPA_PLATFORM=offscreen`. It still reads the sliders and drives your
  lights, the mesh, voice and the Brilliant backend; it just no longer owns the screen. The
  touchscreen and framebuffer go to HomeView.
- **HomeView is a native QML app** (`qmlscene`, Qt 5.15 eglfs), not a web page. The panel's
  QtWebEngine is far too slow for Home Assistant's frontend; QML idles at ~0% CPU / ~50 MB.
- **Live data** comes from the Home Assistant websocket API (`subscribe_entities`, only the
  entities you configure).
- **Photos and frosted glass.** The `panel_photo` Home Assistant integration renders each new
  photo into screen-sized JPEGs, including a heavily blurred copy that lines up pixel for
  pixel with the screen. Every glass pane samples its own patch of that image in a tiny
  GLSL shader, so it looks like live backdrop blur at no runtime cost.
- **Slider indicator.** `hv_sliders.py` watches the cap-touch input device (without
  grabbing it) and streams finger position to the app over a local WebSocket. Once
  Brilliant's hidden UI decides it's idle it stops forwarding slider touches to Linux, so
  the app also shows the indicator whenever a configured slider light's brightness changes.
  While the indicator is up, the face underneath isn't drawn at all (an opaque pre-darkened
  photo + a plain card), so it runs at a steady 60 fps.
- **Night mode.** Optional per panel. Brilliant's hidden UI still runs an "art handler" that
  owns the screen (it switches the backlight off within seconds of anything else turning it
  on), so HomeView steers Brilliant's own display settings instead of the backlight:
  by day, motion wake on with a 24 h off-timeout (Brilliant's stock "on with motion", which it
  holds steadily) and the screen schedule set to the day window; at night, motion wake off and
  screen off. Brilliant evaluates `screen_on_range` in **UTC** (the panel clock), so the
  helper converts and splits the window. A tap at night adds a short window to wake it.
  `hv_bus_set.py` applies these through Brilliant's own message-bus client.
- **Slider taps.** Offscreen, Brilliant's cached light state goes stale, so a tap can
  "toggle" a light to the state it is already in. The helper reports taps; if HA shows no
  change 2.5 s later, HomeView flips the light itself. The kernel only reports axes that
  changed, so slider positions are kept per slot across touches.
- **GPU speed.** Brilliant's UI throttles the GPU (`galcore/gpu3DClockScale` = 4/64) while it
  thinks the screen is idle, which offscreen is always. That leaves any other app at ~2 fps.
  `hv_sliders.py` restores full speed every 2 s unless the SoC is at 85 °C or hotter.

Everything installs under `/etc`, which survives Brilliant's OSTree OTA updates
(`/usr` and `/data` do not).

## Requirements

- A Brilliant panel with root SSH (tested: Brilliant Embedded Linux 4.0.11 "kirkstone",
  i.MX6, Qt 5.15.7, 720x1280 portrait). 1-gang and 3-gang panels both have the slider device.
- Home Assistant with a long-lived access token for the panel.
- A photo source exposed as an HA `image` entity, e.g. the
  immich_frames custom integration (give each display its own feed so they differ).

## Install

1. **Home Assistant:** copy `homeassistant/custom_components/panel_photo` into
   `/config/custom_components/`, add a package like `homeassistant/packages/panel_photo.yaml`
   (one `panels:` entry per Brilliant, `width: 720`, `height: 1280`), put a random
   `panel_photo_key` in `secrets.yaml`, and restart HA.
2. **Panel config:** copy `panel/config.example.js` to e.g. `kitchen.config.js` and fill in
   the HA URL and token, the photo URL and version sensor, and your entities.
3. **Install:**
   ```sh
   ./install.sh <panel-ip> kitchen.config.js America/Los_Angeles
   ```
   The timezone (3rd argument) goes to `/etc/homeview/env`; the panel's clock is UTC.
4. **Uninstall** (back to stock Brilliant):
   ```sh
   ./uninstall.sh <panel-ip>
   ```

## Configuration

All home-specific settings live in `config.js` on the panel (`panel/config.example.js` is
documented). The main ones:

| Key | What |
|---|---|
| `WS`, `TOKEN` | Home Assistant websocket URL and long-lived token |
| `PHOTO`, `PHOTO_VERSION` | panel_photo URL for this panel and its version sensor |
| `FEED` | optional immich_frames feed slug, for the photo caption and tap-for-next |
| `SLIDERS`, `SLIDER_LIGHTS` | slider labels (top to bottom) and the light each dims |
| `LOCKS` | `[[entity_id, "Name"], ...]` shown as a chip when unlocked |
| `DELIVERY` | package box flag/lock/script, mail flag, "arriving today" sensors |
| `DONE` | `{entity, states, icon, text}` alerts, e.g. "Washer is done" |
| `WEATHER`, `CLOCK_24H`, `IDLE_MS` | weather entity, 24-hour clock, card auto-close |
| `MEDIA` | Now Playing: media players in priority order (first playing wins) |
| `SLIDER_CONTROL` | drive sliders Brilliant leaves unassigned (lights, stepped fans) |
| `NIGHT`, `WAKE_MS` | optional `{start, end}` hours for a black screen + backlight off, and tap-to-wake time |

## Gotchas learned the hard way

- `pkill -f "qmlscene ..."` over SSH matches the SSH shell's own command line and kills the
  session mid-script. Use `pkill -x qmlscene`.
- A hand-started offscreen `switch-ui` is not stopped by `systemctl stop switch_ui_app`;
  stacking copies (~113 MB each) runs the panel out of memory.
- Brilliant's `bootsplash.service` runs `fbi`, which lingers and fights for the framebuffer;
  `install.sh` masks it (so boot shows black until HomeView starts).
- QML: properties can't start with a capital letter or with `on` + capital (that's signal
  handler syntax); `prop: { ... }; next: x` on one line is a syntax error.
- Night mode changes Brilliant's own display settings (motion wake, screen schedule,
  brightness may be raised). `uninstall.sh` doesn't restore them; reset them in the
  Brilliant app if you go back to stock.
- `systemctl restart switch_ui_app` right after a stop can get the start killed; it retries
  on its own, but its unit reboots the panel after 6 failures in 120 s, so don't loop it.
- Measure frame times with `QSG_RENDER_TIMING=1` in the service environment (journalctl).
- Screenshot the panel: read `/sys/class/graphics/fb0/pan` for the visible page, then
  `dd if=/dev/fb0 bs=2880 skip=<y> count=1280` (BGRA, 720x1280).

## Layout

```
panel/
  main.qml               the app
  config.example.js      per-panel settings
  hv_sliders.py          slider watcher, GPU keeper, night-mode control (stdlib Python)
  hv_bus_set.py          sets Brilliant message-bus variables (runs under Brilliant's Python)
  fonts/                 Inter (OFL) + Material Design Icons (Apache 2.0)
  system/                homeview.service, hv-sliders.service, switch_ui offscreen drop-in
homeassistant/
  custom_components/panel_photo/   photo renderer + server
  packages/panel_photo.yaml        example config
install.sh / uninstall.sh
```

## License

MIT for this project's code. Inter is under the SIL Open Font License 1.1; Material Design
Icons are under the Apache License 2.0.
