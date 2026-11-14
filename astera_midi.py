#!/usr/bin/env python3
"""
MIDI -> AsteraApp bridge.

Listens to any number of MIDI sources (an Akai MPK mini IV, other controllers,
a DAW, Network MIDI, ...) and drives AsteraApp's built-in Remote Control web
server (port 8080).

Enable it in AsteraApp: Sidebar -> APP SETTINGS -> Remote Control -> Active ON.

Commands:
  python astera_midi.py ports     # list MIDI inputs
  python astera_midi.py learn     # print every MIDI message with its source
  python astera_midi.py list      # show Astera targets + programs (ids/uuids/names)
  python astera_midi.py run       # run the bridge using config.json
"""
import json
import os
import sys
import threading
import time
import urllib.parse
import urllib.request
from pathlib import Path

import mido
import rtmidi

HERE = Path(__file__).resolve().parent
CONFIG_PATH = HERE / "config.json"


# ---------------------------------------------------------------- config
def load_config():
    with open(CONFIG_PATH) as f:
        return json.load(f)


def base_url(cfg):
    a = cfg.get("astera", {})
    return f"http://{a.get('host', '127.0.0.1')}:{a.get('port', 8080)}"


# ---------------------------------------------------------------- astera api
class Astera:
    def __init__(self, url, verbose=True):
        self.url = url
        self.verbose = verbose

    def get(self, path, **params):
        q = urllib.parse.urlencode(params, quote_via=urllib.parse.quote)
        full = f"{self.url}{path}" + (f"?{q}" if q else "")
        try:
            with urllib.request.urlopen(full, timeout=2) as r:
                body = r.read()
            if self.verbose:
                print(f"  -> {path}?{q}  [{r.status}]")
            return body
        except Exception as e:
            print(f"  !! {full}  failed: {e}")
            return None

    def get_json(self, path):
        body = self.get(path)
        try:
            return json.loads(body) if body else None
        except ValueError:
            return None

    def launch(self, spec):
        # spec: {"name": ...} | {"uuid": ...} | {"page": n, "tile": n}
        return self.get("/api/launch", **spec)

    def select_target(self, target_id):
        return self.get("/api/select_target", id=target_id)

    def set_brightness(self, target_id, pct):
        return self.get("/api/set_brightness", id=target_id, brightness=int(pct))

    def set_power(self, on):
        return self.get("/api/set_power", value=1 if on else 0)


class Coalescer:
    """Sends only the latest value per key at a limited rate, so turning a
    knob fast doesn't flood the app with hundreds of requests."""

    def __init__(self, send, rate_hz=20):
        self.send = send
        self.interval = 1.0 / rate_hz
        self.pending = {}
        self.lock = threading.Lock()
        self.event = threading.Event()
        threading.Thread(target=self._loop, daemon=True).start()

    def put(self, key, value):
        with self.lock:
            self.pending[key] = value
        self.event.set()

    def _loop(self):
        while True:
            self.event.wait()
            with self.lock:
                items, self.pending = self.pending, {}
                self.event.clear()
            for key, value in items.items():
                self.send(key, value)
            time.sleep(self.interval)


# ---------------------------------------------------------------- midi inputs
def input_patterns(cfg):
    """`midi_inputs` is a list of name fragments; "*" means every input.
    The older single `midi_input` key is still accepted."""
    pats = cfg.get("midi_inputs")
    if pats is None:
        pats = [cfg["midi_input"]] if cfg.get("midi_input") else ["*"]
    return [p.lower() for p in pats]


def wanted(name, pats, exclude):
    low = name.lower()
    if any(x.lower() in low for x in exclude):
        return False
    return any(p == "*" or p in low for p in pats)


def list_input_names():
    """Fresh CoreMIDI client each time so newly plugged devices show up."""
    mi = rtmidi.MidiIn()
    try:
        return mi.get_ports()
    finally:
        mi.delete()


class RawInput:
    """A MIDI input read by polling rtmidi's own C++ queue.

    No Python callback ever runs on CoreMIDI's thread. mido's inputs always
    use one internally, and on macOS that deadlocks when another port is
    opened while a busy device (e.g. a DJ controller) is sending."""

    def __init__(self, name, virtual=False):
        self.name = name
        self.rt = rtmidi.MidiIn(queue_size_limit=4096)
        self.rt.ignore_types(sysex=True, timing=True, active_sense=True)
        if virtual:
            self.rt.open_virtual_port(name)
        else:
            names = self.rt.get_ports()
            if name not in names:
                self.rt.delete()
                raise OSError(f"port {name!r} not found")
            self.rt.open_port(names.index(name))

    def pending(self):
        while True:
            item = self.rt.get_message()
            if item is None:
                return
            try:
                yield mido.Message.from_bytes(item[0])
            except ValueError:
                pass  # ignore malformed / unsupported messages

    def close(self):
        try:
            self.rt.close_port()
            self.rt.delete()
        except Exception:
            pass


class MidiHub:
    """Opens every matching MIDI input (plus an optional virtual port that
    other apps can send to) and yields (source_name, message) from all of them.
    Rescans so devices plugged in or unplugged later are picked up."""

    def __init__(self, cfg, rescan_s=2.0, poll_s=0.002):
        self.pats = input_patterns(cfg)
        self.exclude = cfg.get("exclude_inputs", [])
        self.virtual = cfg.get("virtual_port")
        self.rescan_s = rescan_s
        self.poll_s = poll_s
        self.ports = {}
        if self.virtual:
            self.exclude = self.exclude + [self.virtual]
            try:
                self.ports[self.virtual] = RawInput(self.virtual, virtual=True)
                print(f"Virtual MIDI port '{self.virtual}' created - other apps can send to it.")
            except Exception as e:
                print(f"Could not create virtual port '{self.virtual}': {e}")
        self.scan()

    def scan(self):
        names = set(list_input_names())
        for n in sorted(names):
            if n not in self.ports and wanted(n, self.pats, self.exclude):
                try:
                    self.ports[n] = RawInput(n)
                    print(f"+ listening to: {n}")
                except Exception as e:
                    print(f"! could not open {n}: {e}")
        for n in list(self.ports):
            if n != self.virtual and n not in names:
                self.ports.pop(n).close()
                print(f"- disconnected: {n}")

    def __iter__(self):
        next_scan = time.monotonic() + self.rescan_s
        while True:
            got = False
            for name, port in list(self.ports.items()):
                for msg in port.pending():
                    got = True
                    yield name, msg
            if time.monotonic() >= next_scan:
                try:
                    self.scan()
                except Exception as e:
                    print(f"rescan error: {e}")
                next_scan = time.monotonic() + self.rescan_s
            if not got:
                time.sleep(self.poll_s)


# ---------------------------------------------------------------- mapping logic
def matches(m, source, msg):
    src = m.get("source")  # optional: only react to inputs whose name contains this
    if src and src.lower() not in source.lower():
        return False
    ch = m.get("channel")  # 1-16, optional (omit = any channel)
    if ch is not None and msg.channel != ch - 1:
        return False
    if "note" in m:
        return msg.type in ("note_on", "note_off") and msg.note == m["note"]
    if "cc" in m:
        return msg.type == "control_change" and msg.control == m["cc"]
    if "program_change" in m:
        return msg.type == "program_change" and msg.program == m["program_change"]
    return False


def relative_delta(value):
    """Akai-style relative encoder: 1..63 = +steps, 65..127 = -steps."""
    if value == 0 or value == 64:
        return 0
    return value if value < 64 else value - 128


def run(cfg):
    astera = Astera(base_url(cfg), verbose=cfg.get("verbose", True))
    if astera.get("/api/status") is None:
        print("Warning: AsteraApp Remote Control not reachable yet - "
              "turn it on in AsteraApp settings. Continuing anyway.")

    # current brightness per target, so relative knobs start from the real value
    level = {}
    for t in astera.get_json("/api/targets") or []:
        level[str(t.get("Id"))] = t.get("Brightness", 50)

    bright = Coalescer(lambda tid, v: astera.set_brightness(tid, v))
    power_state = {"on": True}
    cc_last = {}  # for treating CC buttons as triggers (rising edge)

    def fire(m):
        a = m["action"]
        if a == "launch":
            astera.launch(m["program"])
        elif a == "select_target":
            astera.select_target(m["target"])
        elif a == "power":
            v = m.get("value", "toggle")
            power_state["on"] = (not power_state["on"]) if v == "toggle" else (v == "on")
            astera.set_power(power_state["on"])

    def brightness(m, msg):
        tid = str(m["target"])
        lo, hi = m.get("range", [0, 100])
        if m.get("mode") == "relative" and msg.type == "control_change":
            step = m.get("step", 1)
            cur = level.get(tid, 50) + relative_delta(msg.value) * step
        else:
            raw = msg.value if msg.type == "control_change" else msg.velocity
            cur = lo + (hi - lo) * raw / 127
        cur = max(lo, min(hi, round(cur)))
        level[tid] = cur
        bright.put(m["target"], cur)

    mappings = cfg.get("mappings", [])
    hub = MidiHub(cfg)
    print(f"Bridge running -> {astera.url}  ({len(mappings)} mappings). Ctrl+C to stop.")
    for source, msg in hub:
        if not hasattr(msg, "channel"):
            continue
        for m in mappings:
            if not matches(m, source, msg):
                continue
            label = m.get("label", m["action"])
            if m["action"] == "brightness":
                brightness(m, msg)
            elif msg.type == "note_on" and msg.velocity > 0:
                print(f"[{source}] {msg}  => {label}")
                fire(m)
            elif msg.type == "program_change":
                print(f"[{source}] {msg}  => {label}")
                fire(m)
            elif msg.type == "control_change":
                key = (source, msg.channel, msg.control)
                was = cc_last.get(key, 0)
                cc_last[key] = msg.value
                if was < 64 <= msg.value:
                    print(f"[{source}] {msg}  => {label}")
                    fire(m)


def learn(cfg):
    # optional filter, e.g. `learn MPK`, to hide chatty devices like DJ controllers
    only = sys.argv[2].lower() if len(sys.argv) > 2 else None
    hub = MidiHub(cfg)
    print(f"Press pads / turn knobs on {only or 'any source'}. Ctrl+C to stop.\n")
    for source, msg in hub:
        if only and only not in source.lower():
            continue
        s = f"[{source}]"
        if msg.type in ("note_on", "note_off"):
            print(f"{s} {msg.type:8} channel={msg.channel + 1:<2} note={msg.note:<3} velocity={msg.velocity}")
        elif msg.type == "control_change":
            print(f"{s} cc       channel={msg.channel + 1:<2} cc={msg.control:<5} value={msg.value}")
        elif msg.type == "program_change":
            print(f"{s} program  channel={msg.channel + 1:<2} program_change={msg.program}")
        elif msg.type not in ("clock", "active_sensing"):
            print(f"{s} {msg}")


def list_astera(cfg):
    astera = Astera(base_url(cfg), verbose=False)
    status = astera.get_json("/api/status")
    print("Status:", json.dumps(status) if status else "NOT REACHABLE")
    print("\nTargets (use Id as \"target\"):")
    for t in astera.get_json("/api/targets") or []:
        print(f"  id {t['Id']:<3} {t.get('NameLocalized') or t.get('Name'):<20} brightness {t.get('Brightness')}")
    print("\nPrograms (use {\"uuid\": ...} as \"program\"):")
    for p in astera.get_json("/api/programs") or []:
        pos = p.get("Position", 0)
        print(f"  page {pos >> 16}  slot {pos & 0xFFFF:>2}  {p.get('NameLocalized') or '(unnamed)':<22} {p['UniqueId']}")


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else "run"
    try:
        if cmd == "ports":
            print("\n".join(list_input_names()) or "(no MIDI inputs)")
        else:
            cfg = load_config()
            {"run": run, "learn": learn, "list": list_astera}.get(cmd, run)(cfg)
    except KeyboardInterrupt:
        print("\nStopped.")
        os._exit(0)  # skip rtmidi port teardown, which can hang on macOS
