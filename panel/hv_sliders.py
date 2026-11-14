#!/usr/bin/env python3
"""Live cap-touch slider state for the HomeView QML app on Brilliant panels.

Brilliant's switch-ui (running offscreen) still reads the sliders and drives the
lights. This only *watches* the same input device (no grab) so HomeView can draw
the on-screen level indicator Brilliant's hidden UI no longer shows.

ws://127.0.0.1:8765/ws streams every change as a text frame, at most ~30 per second
(one persistent socket: per-update HTTP requests made the on-screen bar stutter).
GET /screen?mode=day|night|wake&start=22&end=7&off=<utc offset min>&wake=<s> steers night
mode through Brilliant's own display settings, which its art handler enforces (writing the
backlight directly just fights it):
  day   motion wake on with a 24 h off-timeout (Brilliant's stock "on with motion", which it
        holds steadily) + screen schedule = our day window + screen_on
  night motion wake off + screen off; the schedule (Brilliant evaluates it in UTC) keeps it off
  wake  the day window plus "now + wake seconds", screen on
GET http://127.0.0.1:8765/state?since=<seq> long-polls (25 s) for the next change:
  {"seq": 12, "active": true, "slider": 0, "level": 63}
level is the finger position 0-100 (bottom..top); slider is 0-based (the device
reports ABS_MT_POSITION_X 1..N on 3-gang panels, so it is shifted down by one).
GET /fake?slider=0&level=60 (and /fake?active=0) drives the indicator for testing
without touching the real slider (writing to the evdev node would dim real lights).

Also keeps the GPU unthrottled: Brilliant's switch-ui has a GPUThrottler that drops
/sys/bus/platform/drivers/galcore/gpu3DClockScale to 4/64 while it thinks the screen
is idle, which (offscreen, it always does) left HomeView at ~2 fps. We restore 64
every 2 s unless the SoC is hot (>= 85 C), so real thermal throttling still wins.
Stdlib only (the panel's /usr/bin/python3 has no extras).
"""
import base64
import fcntl
import subprocess
import glob
import hashlib
import json
import os
import select
import struct
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

EVENT = struct.Struct("llHHi")
EV_ABS, ABS_MT_SLOT, ABS_MT_POSITION_X, ABS_MT_POSITION_Y, ABS_MT_TRACKING_ID = 3, 0x2F, 0x35, 0x36, 0x39

# A short touch with little movement is a tap (Brilliant toggles the light). Reported as a
# counter so HomeView can make sure the light really changed: offscreen, Brilliant's cached
# light state goes stale and a tap can "toggle" to the state the light is already in.
TAP_S, TAP_MOVE = 0.4, 80

state = {"seq": 0, "active": False, "slider": 0, "level": 0, "taps": 0, "tap_slider": 0}
cond = threading.Condition()


def publish(**kw):
    with cond:
        changed = any(state.get(k) != v for k, v in kw.items())
        if changed:
            state.update(kw)
            state["seq"] += 1
            cond.notify_all()


def absval(fd, code):
    """Current value of an absolute axis (EVIOCGABS)."""
    buf = fcntl.ioctl(fd, 0x80184540 + code, bytes(24))
    return struct.unpack("6i", buf)[0]


def find_device():
    for n in glob.glob("/sys/class/input/event*/device/name"):
        try:
            if open(n).read().strip() == "brilliant_captouch":
                return "/dev/input/" + n.split("/")[4]
        except OSError:
            pass
    return None


def reader():
    while True:
        dev = find_device()
        if not dev:
            time.sleep(10)
            continue
        fd = os.open(dev, os.O_RDONLY | os.O_NONBLOCK)
        # The kernel only reports axes that CHANGED, per slot. Touching the same slider
        # again sends no new X, so positions must persist across contacts (resetting them
        # per touch made every repeat touch on a slider invisible). Seed from the device.
        slot, live, pos = 0, set(), {}
        try:
            pos[0] = {"x": absval(fd, ABS_MT_POSITION_X), "y": absval(fd, ABS_MT_POSITION_Y)}
        except OSError:
            pass

        def emit(sl):
            c = pos.get(sl)
            if sl in live and c and c["x"] is not None and c["y"] is not None:
                publish(active=True, slider=max(0, c["x"] - 1), level=max(0, min(100, round(c["y"] / 10))))

        try:
            while True:
                select.select([fd], [], [], 30)
                try:
                    data = os.read(fd, EVENT.size * 64)
                except BlockingIOError:
                    continue
                for i in range(0, len(data) - EVENT.size + 1, EVENT.size):
                    _, _, kind, code, value = EVENT.unpack_from(data, i)
                    if kind != EV_ABS:
                        continue
                    if code == ABS_MT_SLOT:
                        slot = value
                    elif code == ABS_MT_TRACKING_ID:
                        if value >= 0:
                            live.add(slot)
                            c = pos.setdefault(slot, {"x": None, "y": None})
                            c["t0"], c["y0"], c["ymax"] = time.monotonic(), None, 0
                            emit(slot)
                        else:
                            live.discard(slot)
                            c = pos.get(slot) or {}
                            tap = (c.get("t0") is not None and time.monotonic() - c["t0"] < TAP_S
                                   and c.get("ymax", 0) < TAP_MOVE and c.get("x") is not None)
                            extra = {"taps": state["taps"] + 1, "tap_slider": max(0, c["x"] - 1)} if tap else {}
                            if not live or extra:
                                publish(active=bool(live), **extra)
                    elif code in (ABS_MT_POSITION_X, ABS_MT_POSITION_Y):
                        c = pos.setdefault(slot, {"x": None, "y": None})
                        c["x" if code == ABS_MT_POSITION_X else "y"] = value
                        if code == ABS_MT_POSITION_Y and c.get("t0") is not None:
                            if c.get("y0") is None:
                                c["y0"] = value
                            c["ymax"] = max(c.get("ymax", 0), abs(value - c["y0"]))
                        emit(slot)
        except OSError:
            time.sleep(2)
        finally:
            os.close(fd)


GPU_SCALE = "/sys/bus/platform/drivers/galcore/gpu3DClockScale"
THERMAL = "/sys/class/thermal/thermal_zone0/temp"


BUS_PY = "/data/switch-embedded/env/bin/python"
BUS_SET = os.path.join(os.path.dirname(os.path.abspath(__file__)), "hv_bus_set.py")
BACKLIGHT = "/sys/class/backlight/backlight_lcd/brightness"
screen = {"applied": None, "mode": None, "poked": 0.0}


def bus_set(bundle):
    """{peripheral: {variable: value}} applied by Brilliant's own bus client."""
    threading.Thread(target=lambda: subprocess.run(
        [BUS_PY, BUS_SET, json.dumps(bundle)],
        timeout=90, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL), daemon=True).start()


def schedule_value(ranges):
    """Thrift-binary ScreenOnRange: every day of the week, [(start_s, end_s) UTC]."""
    b = b"\x0f\x00\x03\x08" + struct.pack(">i", 7) + b"".join(struct.pack(">i", d) for d in range(7))
    b += b"\x0f\x00\x04\x0c" + struct.pack(">i", len(ranges))
    for start, end in ranges:
        b += b"\x08\x00\x01" + struct.pack(">i", start) + b"\x08\x00\x02" + struct.pack(">i", end)
        b += b"\x08\x00\x03" + struct.pack(">i", 0) + b"\x08\x00\x04" + struct.pack(">i", 0) + b"\x00"
    return base64.b64encode(b + b"\x00").decode()


def utc_ranges(start_s, end_s):
    """Local-to-UTC window, split in two when it wraps past midnight UTC."""
    start_s %= 86400
    end_s %= 86400
    if start_s < end_s:
        return [(start_s, end_s)]
    return [(start_s, 86399), (0, end_s)]


def set_screen(mode, night_start, night_end, off_min, wake_s):
    off = off_min * 60
    day = utc_ranges(int(night_end * 3600) - off, int(night_start * 3600) - off)
    if mode == "wake":
        now = int(time.time()) % 86400
        day = day + utc_ranges(now - 60, now + wake_s)
    screen["mode"] = mode
    key = (mode, night_start, night_end, off_min) if mode != "wake" else ("wake", int(time.time()) // 10)
    if screen["applied"] == key:
        return
    screen["applied"] = key
    screen["poked"] = time.monotonic()
    hw = {"screen_on_range": schedule_value(day), "screen_on": "0" if mode == "night" else "1"}
    if mode == "night":
        motion = {"trigger_screen": "0"}
    else:
        motion = {"trigger_screen": "1", "trigger_screen_off": "1", "trigger_screen_off_timeout_sec": "86400"}
    bundle = {"motion_detection_config_peripheral": motion, "hardware_peripheral": hw}
    if mode == "day":
        bundle["faceplate_peripheral"] = {"enable_screen_motion_detection": "1"}
    bus_set(bundle)


def screen_keeper():
    """Inside the allowed window Brilliant only refrains from turning the screen OFF; it
    never turns it back on by itself (that normally takes a touch or motion). So in day /
    wake mode, if the backlight is dark, ask Brilliant for screen_on=1 (at most every 30 s)."""
    if screen["mode"] not in ("day", "wake") or time.monotonic() - screen["poked"] < 30:
        return
    try:
        if int(open(BACKLIGHT).read().strip()) == 0:
            screen["poked"] = time.monotonic()
            bus_set({"hardware_peripheral": {"screen_on": "1"}})
    except (OSError, ValueError):
        pass


def keepers():
    while True:
        gpu_keep()
        screen_keeper()
        time.sleep(2)


def gpu_keep():
    try:
        hot = int(open(THERMAL).read().strip()) >= 85000
        if not hot and open(GPU_SCALE).read().strip() != "64":
            with open(GPU_SCALE, "w") as f:
                f.write("64")
    except (OSError, ValueError):
        pass


WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
MIN_GAP = 1 / 50


def ws_frame(text):
    data = text.encode()
    n = len(data)
    head = bytes([0x81, n]) if n < 126 else bytes([0x81, 126]) + n.to_bytes(2, "big")
    return head + data


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def stream(self):
        key = self.headers.get("Sec-WebSocket-Key", "")
        accept = base64.b64encode(hashlib.sha1((key + WS_GUID).encode()).digest()).decode()
        self.send_response(101)
        self.send_header("Upgrade", "websocket")
        self.send_header("Connection", "Upgrade")
        self.send_header("Sec-WebSocket-Accept", accept)
        self.end_headers()
        self.wfile.flush()
        seq, last = -1, 0.0
        try:
            while True:
                with cond:
                    cond.wait_for(lambda: state["seq"] != seq, timeout=20)
                    snap = dict(state)
                gap = MIN_GAP - (time.monotonic() - last)
                if gap > 0:
                    time.sleep(gap)
                    with cond:
                        snap = dict(state)
                self.wfile.write(ws_frame(json.dumps(snap)))
                self.wfile.flush()
                seq, last = snap["seq"], time.monotonic()
        except OSError:
            pass
        self.close_connection = True

    def do_GET(self):
        u = urlparse(self.path)
        if u.path == "/ws" and self.headers.get("Upgrade", "").lower() == "websocket":
            return self.stream()
        q = parse_qs(u.query)
        if u.path == "/screen":
            g = lambda k, d: (q.get(k) or [d])[0]
            set_screen(g("mode", "day"), float(g("start", "22")), float(g("end", "7")), int(g("off", "0")), int(g("wake", "30")))
            self.send_response(204)
            self.end_headers()
            return
        if u.path == "/fake":
            publish(active=(q.get("active") or ["1"])[0] == "1",
                    slider=int((q.get("slider") or ["0"])[0]), level=int((q.get("level") or ["50"])[0]))
            self.send_response(204)
            self.end_headers()
            return
        since = int((q.get("since") or ["-1"])[0])
        with cond:
            cond.wait_for(lambda: state["seq"] != since, timeout=25)
            body = json.dumps(state).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


if __name__ == "__main__":
    threading.Thread(target=reader, daemon=True).start()
    threading.Thread(target=keepers, daemon=True).start()
    ThreadingHTTPServer(("127.0.0.1", 8765), Handler).serve_forever()
