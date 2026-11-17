# Making per-song lighting MIDI clips for Astera MIDI Bridge

Give this file to a Claude chat to have it write lighting MIDI clips for one song at a time. The clip
is a `.mid` file that Jon drags into Ableton at the song's start; when Ableton plays it, the Astera
MIDI Bridge app turns the notes and CCs into lighting changes in AsteraApp.

Everything a chat needs is in this file, including a script that writes the `.mid` with no extra
software. It works whether or not the chat can read Jon's files.

Rig and app state as of 2026-11-17, bridge version 1.6.

---

## 1. The rig

- **YBMW Stage**: the stage tubes. Gets colour looks (scenes) and brightness.
- **Front Wash**: two tubes lighting the band from the front. **Static white, brightness only.**
  Never send it a scene or a colour.
- Lights are Astera AX1 tubes controlled by AsteraApp over Bluetooth. Ableton sends MIDI to a
  virtual port called **Astera Bridge**; the bridge app passes it to AsteraApp.

## 2. The MIDI the bridge understands

Everything on **MIDI channel 1**. Note names are Ableton's (middle C = C3 = 60).

| MIDI | Does |
|---|---|
| Note 24 (C0) | Select YBMW Stage, so the following scenes land on the stage only |
| Notes 36–45 (C1–A1) | **Calm** look in colours 1–10 (steady colour) |
| Notes 48–57 (C2–A2) | **Big** look in colours 1–10 (the same colour, moving) |
| CC 20 | Stage brightness |
| CC 21 | Front wash brightness |

Colours, in this order for both rows:

| # | Colour | Calm note | Big note |
|---|---|---|---|
| 1 | Teal | 36 (C1) | 48 (C2) |
| 2 | Gold | 37 (C#1) | 49 (C#2) |
| 3 | Purple | 38 (D1) | 50 (D2) |
| 4 | Red | 39 (D#1) | 51 (D#2) |
| 5 | Light Blue | 40 (E1) | 52 (E2) |
| 6 | Green | 41 (F1) | 53 (F2) |
| 7 | Pink | 42 (F#1) | 54 (F#2) |
| 8 | Cool White | 43 (G1) | 55 (G2) |
| 9 | Deep Blue | 44 (G#1) | 56 (G#2) |
| 10 | Orange | 45 (A1) | 57 (A2) |

- A scene fires on **note-on** (velocity above 0). Note length doesn't matter; use 1 beat.
- Brightness: CC value = `round(percent × 127 ÷ 100)`. 100% = 127, 50% = 64, 0 = 0.
- Jon may cap brightness per venue with the bridge's **Max** slider; the clips should still use the
  full 0–100% range.

**Not available yet:** colours other than the ten above, changing the front wash colour, per-tube
control. Ask Jon to add a scene in AsteraApp and map it in the bridge if a song needs a new look.

## 3. How the lights behave (design around this)

1. **Send note 24 first, at the very start of every clip.** Scenes go to whatever target is selected
   in AsteraApp; the select note makes it the stage alone. Without it, a scene could land on the
   front wash.
2. **Scene changes cut instantly.** There's no crossfade between looks.
3. **Brightness ramps look stepped.** Each step is a separate Bluetooth command. Jumps between levels
   look fine; slow ramps (2 seconds or more) look acceptable; fast ramps look choppy.
4. **Timing has a small, slightly variable delay** (Bluetooth). Changes on bar lines and section
   starts work well. On-beat hits are possible but may look loose; keep them for special moments.
5. Only send a scene note when the look actually changes, and don't repeat a CC value that's already
   set. Fewer messages means a steadier result.
6. Put a scene note before the brightness CC when both happen at the same moment.

## 4. House style for a song

Pick **one colour** for the song (or two for a song with a big change, such as a key change or a
bridge that feels different). Then follow the song's sections:

| Section | Look | Stage | Front |
|---|---|---|---|
| Count-in | – | 0% | fade up to 100% over the count-in |
| Intro, re-intro, turnaround | Calm | 50% | 100% |
| Verse | Calm | 45% | 100% |
| Pre-chorus, build | Calm | 70% | 100% |
| Chorus, post-chorus, tag | **Big** | 100% | 100% |
| Bridge | Calm | 80% | 100% |
| Solo, instrumental | **Big** | 80% | 100% |
| Down chorus, breakdown, a cappella | Calm | 25% | 40% |
| Outro | Calm | 50% | 100% |
| End (last 1–2 bars) | – | fade to 0 | fade to 0 |

- **Start of clip:** note 24, stage 0, front 0, then the Calm note half a beat later.
- **End of clip:** both groups at 0.
- **Beat hits** for a special moment (example in use: the Sparks Fly bridge): stage to 100% on every
  beat and down to 25% half a beat later, on the Calm look. Use sparingly.
- Era colours Jon has used: Fearless era Gold, Speak Now Purple, Red era Red, 1989 Light Blue,
  Reputation Green, Lover Pink, folklore/evermore Cool White, Midnights Deep Blue, debut Teal.
  These are suggestions; Jon decides.

## 5. What to ask Jon for

For each song you need:

1. **Song name and tempo** (BPM), and time signature (assume 4/4).
2. **The section list with bar numbers**, counted from bar 1 at the start of the clip. For example:
   `1 Count in, 3 Intro, 7 Verse, 15 Pre, 19 Chorus, …, 87 Out`, plus where the song ends.
3. **Colour** (or let you suggest one).
4. Any **special moments** (hits, blackouts, a down section).

Jon's Ableton set has a `SECTIONS` track with a named clip per section, and a marker at each song's
start, so he can read the bar numbers off his timeline. If the chat can read files, ask Jon where his
Ableton set is. A `.als` file is gzipped XML; read it only, never modify it. Jon also has a generator
script that builds clips for the whole set at once; ask him for it if that would help.

Before writing the file, show Jon a **cue sheet** (bar, section, look, stage %, front %) and get his
OK.

## 6. The script

Python 3, no extra packages. Fill in `SONG`, run it, and it writes `<name>.mid` next to the script.
Bars count from 1 at the clip's start; positions can use fractions (`17.5` = halfway through bar 17).

```python
#!/usr/bin/env python3
"""Writes one song's lighting clip for Astera MIDI Bridge as a Standard MIDI File."""

SONG = {
    "name": "Example Song",
    "beats_per_bar": 4,
    "end_bar": 41,              # the bar after the last one; the clip ends here
    "colour": "Purple",         # default look colour for the song
    # (bar, section, look, stage %, front %). look: "calm", "big", or None to keep the current look.
    # Use "fade" for a level to ramp from the previous value over the section, e.g. ("fade", 0).
    "cues": [
        (1,  "Count in", None,   0,    ("fade", 100)),
        (3,  "Intro",    "calm", 50,   100),
        (7,  "Verse",    "calm", 45,   100),
        (15, "Pre",      "calm", 70,   100),
        (19, "Chorus",   "big",  100,  100),
        (27, "Down ch",  "calm", 25,   40),
        (35, "Chorus",   "big",  100,  100),
        (39, "Out",      None,   ("fade", 0), ("fade", 0)),
    ],
    # Optional on-beat hits: (start bar, end bar, high %, low %)
    "hits": [],
}

# ---- the bridge's MIDI contract (don't change unless the bridge's mappings change) ----
CHANNEL = 0                       # MIDI channel 1
NOTE_SELECT_STAGE = 24
CC_STAGE, CC_FRONT = 20, 21
COLOURS = ["Teal", "Gold", "Purple", "Red", "Light Blue", "Green", "Pink", "Cool White", "Deep Blue", "Orange"]
CALM = {c: 36 + i for i, c in enumerate(COLOURS)}
BIG = {c: 48 + i for i, c in enumerate(COLOURS)}
TPQ = 480                         # ticks per beat


def build(song):
    bpb = song["beats_per_bar"]
    beat = lambda bar: (bar - 1) * bpb
    end = beat(song["end_bar"])
    ev = []                       # (beat, order, bytes)
    state = {"look": None, CC_STAGE: None, CC_FRONT: None}

    def note(t, n):
        ev.append((t, 0, [0x90 | CHANNEL, n, 100]))
        ev.append((t + 1, -1, [0x80 | CHANNEL, n, 0]))

    def cc(t, ctrl, pct):
        v = max(0, min(127, round(pct * 127 / 100)))
        if state[ctrl] != v:
            state[ctrl] = v
            ev.append((t, 1, [0xB0 | CHANNEL, ctrl, v]))

    def ramp(t0, t1, ctrl, target):
        start = (state[ctrl] or 0) * 100 / 127
        steps = max(1, int((t1 - t0) / 0.25))           # a value every quarter beat
        for i in range(1, steps + 1):
            cc(t0 + (t1 - t0) * i / steps, ctrl, start + (target - start) * i / steps)

    def look(t, kind, colour):
        n = (CALM if kind == "calm" else BIG)[colour]
        if state["look"] != n:
            state["look"] = n
            note(t, n)

    note(0, NOTE_SELECT_STAGE)
    cc(0, CC_STAGE, 0)
    cc(0, CC_FRONT, 0)
    look(0.5, "calm", song["colour"])

    cues = sorted(song["cues"], key=lambda c: c[0])
    for i, (bar, _name, lk, stage, front) in enumerate(cues):
        t = beat(bar)
        nxt = beat(cues[i + 1][0]) if i + 1 < len(cues) else end
        if lk:
            colour = lk[1] if isinstance(lk, tuple) else song["colour"]
            look(t, lk[0] if isinstance(lk, tuple) else lk, colour)
        for ctrl, val in ((CC_STAGE, stage), (CC_FRONT, front)):
            if isinstance(val, tuple) and val[0] == "fade":
                ramp(t, nxt, ctrl, val[1])
            elif val is not None:
                cc(t, ctrl, val)

    for start, stop, hi, lo in song.get("hits", []):
        t = beat(start)
        while t < beat(stop) - 0.01:
            state[CC_STAGE] = None
            cc(t, CC_STAGE, hi)
            cc(t + 0.5, CC_STAGE, lo)
            t += 1

    state[CC_STAGE] = state[CC_FRONT] = None
    cc(end, CC_STAGE, 0)
    cc(end, CC_FRONT, 0)
    return ev, end


def vlq(n):
    out = [n & 0x7F]
    n >>= 7
    while n:
        out.insert(0, (n & 0x7F) | 0x80)
        n >>= 7
    return bytes(out)


def write_mid(path, name, ev, length):
    track = b"\x00\xff\x03" + bytes([len(name.encode()[:100])]) + name.encode()[:100]
    now = 0
    for t, _, data in sorted(ev, key=lambda e: (round(e[0] * TPQ), e[1])):
        tick = max(now, round(t * TPQ))
        track += vlq(tick - now) + bytes(data)
        now = tick
    track += vlq(max(0, round(length * TPQ) - now)) + b"\xff\x2f\x00"
    head = b"MThd" + (6).to_bytes(4, "big") + (0).to_bytes(2, "big") + (1).to_bytes(2, "big") + TPQ.to_bytes(2, "big")
    with open(path, "wb") as f:
        f.write(head + b"MTrk" + len(track).to_bytes(4, "big") + track)


if __name__ == "__main__":
    import os
    ev, length = build(SONG)
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), f"{SONG['name']}.mid")
    write_mid(path, f"Lights - {SONG['name']}", ev, length)
    print(f"Wrote {path}: {sum(1 for e in ev if e[1] >= 0)} cues over {length / SONG['beats_per_bar']:g} bars")
```

Notes on the script:

- A cue's `look` can also name a different colour for that section: `("big", "Gold")`.
- `None` for a level means "leave it as it is".
- Positions are in bars from the clip start, so the clip must be dropped exactly at the song's start
  marker in Ableton.
- Check the output: every scene note is in 36–45 or 48–57, the clip starts with note 24, and it
  ends with CC 20 and CC 21 at 0.

If the chat can't run Python, give Jon the script and the `SONG` block and he can run it with
`python3 script.py` in Terminal.

## 7. Putting the clip in Ableton (Jon does this)

1. The bridge app must be running, so the **Astera Bridge** MIDI port exists.
2. Ableton → Settings → Link, Tempo & MIDI: **Track** on for the **Astera Bridge** output.
3. Use a MIDI track with **MIDI To** set to **Astera Bridge**, channel 1 (Jon's is called
   "MIDI - Lights").
4. Drag the `.mid` onto that track, starting exactly at the song's marker. If Ableton asks about
   tempo, decline.
5. Play from the song's marker, so the select note at the start is sent.

If the lights don't react: in Ableton's MIDI settings turn Track off and on for Astera Bridge
(Ableton can lose the port when the bridge restarts), and check AsteraApp is connected to the lights.

Jon can also build or tweak cues by hand: the bridge's **Control & Clips** window has a draggable clip
for every look and for brightness levels, fades and beat hits.
