#!/usr/bin/env python3
"""Live cap-touch slider state for the HomeView QML app on Brilliant panels.

Brilliant's switch-ui (running offscreen) still reads the sliders and drives the
lights. This only *watches* the same input device (no grab) so HomeView can draw
the on-screen level indicator Brilliant's hidden UI no longer shows.

ws://127.0.0.1:8765/ws streams every change as a text frame, at most ~30 per second
(one persistent socket: per-update HTTP requests made the on-screen bar stutter).
GET /backlight?on=0|1 sets the screen backlight (night mode); held every 2 s, and the
last daytime level is restored on wake.
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

state = {"seq": 0, "active": False, "slider": 0, "level": 0}
cond = threading.Condition()


def publish(**kw):
    with cond:
        changed = any(state.get(k) != v for k, v in kw.items())
        if changed:
            state.update(kw)
            state["seq"] += 1
            cond.notify_all()


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
        slot, contacts = 0, {}
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
                            contacts[slot] = {"x": None, "y": None}
                        else:
                            contacts.pop(slot, None)
                            if not contacts:
                                publish(active=False)
                    elif slot in contacts:
                        c = contacts[slot]
                        if code == ABS_MT_POSITION_X:
                            c["x"] = value
                        elif code == ABS_MT_POSITION_Y:
                            c["y"] = value
                        if c["x"] is not None and c["y"] is not None:
                            publish(active=True, slider=max(0, c["x"] - 1), level=max(0, min(100, round(c["y"] / 10))))
        except OSError:
            time.sleep(2)
        finally:
            os.close(fd)


GPU_SCALE = "/sys/bus/platform/drivers/galcore/gpu3DClockScale"
THERMAL = "/sys/class/thermal/thermal_zone0/temp"


BACKLIGHT = "/sys/class/backlight/backlight_lcd/brightness"
screen = {"on": True, "saved": None}


def keepers():
    while True:
        try:
            cur = int(open(BACKLIGHT).read().strip())
            if not screen["on"]:
                if cur != 0:
                    screen["saved"] = cur
                    open(BACKLIGHT, "w").write("0")
            elif cur == 0 and screen["saved"]:
                open(BACKLIGHT, "w").write(str(screen["saved"]))
                screen["saved"] = None
        except (OSError, ValueError):
            pass
        gpu_keep()
        time.sleep(2)


def set_screen(on):
    screen["on"] = on
    try:
        cur = int(open(BACKLIGHT).read().strip())
        if not on and cur != 0:
            screen["saved"] = cur
            open(BACKLIGHT, "w").write("0")
        elif on and cur == 0:
            open(BACKLIGHT, "w").write(str(screen["saved"] or 8))
            screen["saved"] = None
    except (OSError, ValueError):
        pass


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
        if u.path == "/backlight":
            set_screen((q.get("on") or ["1"])[0] == "1")
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
