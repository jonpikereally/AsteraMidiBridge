# AsteraMidiBridge

A macOS app that controls Astera lights over Bluetooth through **AsteraApp**, over DMX, or both.
Use an Akai MPK mini IV, other controllers, a DAW, or any app that can send MIDI.

Pads launch scenes (effects), knobs set brightness, and the window shows what's playing with
Astera's own tile artwork.

## Install

1. Download [dist/AsteraMidiBridge.zip](dist/AsteraMidiBridge.zip), unzip it, and move
   **Astera MIDI Bridge.app** to Applications. It's built for Apple Silicon Macs on macOS 13 or later.
2. The app isn't notarized, so the first time, right-click it and choose **Open**.
3. In AsteraApp, open the sidebar, go to **APP SETTINGS**, then **Remote Control**, and set
   **Active** and **Auto start** to ON. Keep the AsteraApp window open.

The app appears in the Dock and Cmd+Tab by default. To hide it from both, click the purple-and-orange
menu bar icon and turn off **Show in Dock**. The app remembers your choice and you can still use
**Open Configure** or **Open Control** from the menu bar. Closing the windows leaves the bridge running.
**Check for Updates…** downloads the latest version and restarts the app.

## Configure

- **Map a pad to a scene:** click **+ Scene mapping**, press the pad, pick the scene.
- **Map a knob to brightness:** click **+ Brightness mapping**, turn the knob, pick the target.
  "All Lights (master)" is the master brightness. Tick **Relative knob** for endless encoders in Rel mode.
  Use the **Max** slider to cap how bright that control can go, for example a lower front wash in a
  small room. Everything the control sends is scaled below the cap.
- **Duplicates:** if a pad or knob is already assigned, the app asks whether to reassign it or keep both.
- **Connections & Fixtures:** set up MIDI inputs and the virtual port, select Bluetooth, DMX, or both,
  and edit the AsteraApp connection, DMX interface, and fixture patch. Use **Apply Setup** to activate changes.
- **Add a target:** create the target in AsteraApp first, then add its select note and brightness CC
  under **MIDI Mappings**. Use **Remove Target Controls** to remove its virtual-port mappings.
- **Fades:** scene changes follow each effect's own Crossfade setting from AsteraApp. Effects with no
  crossfade cut instantly. AsteraApp's remote control can only cut, so the bridge fades by dimming the
  master brightness to black and back up. It isn't as smooth as AsteraApp's own crossfade. Untick the
  checkbox under **MIDI Mappings** to turn it off.
- **Save Settings… / Load Settings…:** keep mappings in a file, or move them to another Mac.

## Control

- **Now Playing** shows the current effect with its Astera tile and color.
- **Send** triggers a scene, target selection, or power mapping. Target selection is exclusive.
- **Brightness** lets you send levels as you move the sliders or stage a level and press **Send**.
- **Targets and power** shows AsteraApp's reported brightness for each target, refreshed every 2 seconds.
- **DMX Blackout** blacks out fixtures while DMX output is active.
- **Show MIDI clips** displays clip export for mappings that listen to the virtual port
  (normally **Astera Bridge**). Drag a clip into Ableton's timeline on a track that sends to that port,
  or use **Copy**. Scene clips start the scene on the first beat. Brightness clips can set a level,
  fade in or out, or produce beat hits.
- **Keep on top** floats Control above other apps.

The first time it reads AsteraApp's effect settings, macOS may ask whether the app can access data
from other apps. Click **Allow**. Without it, scene changes always cut and Now Playing only tracks
scenes launched through the bridge.

## Writing lighting clips with Claude

[docs/SONG_CLIP_GUIDE.md](docs/SONG_CLIP_GUIDE.md) is a self-contained guide to give a Claude chat so it
can write per-song lighting MIDI clips for Ableton: the MIDI the bridge understands, how the lights
behave, a house style, and a dependency-free script that writes the `.mid` file. It's kept up to date
with the app.

## DMX output

Besides AsteraApp over Bluetooth, the bridge can drive the lights itself over DMX, for example through an
Enttec Open DMX USB into an AsteraBox that transmits wireless DMX (CRMX). The same MIDI notes and CCs
work in both modes, so existing clips don't change.

- **Fixtures:** each light in **DIM RGBW** mode (5 channels: dimmer, red, green, blue, white), one pixel,
  input set to CRMX and linked to the transmitter, each with its own start address.
- **Looks:** the bridge generates them. A steady look is one colour; a pulse look is a brightness wave that
  travels across the stage lights. Scene changes crossfade.
- **Groups:** lights are `stage` or `front`. Front lights show `front_color` and only follow brightness.
- **Interface:** any `/dev/cu.usbserial-*` FTDI device (`"port": "auto"` picks the first). The Open DMX USB
  depends on the computer for its timing; a busy computer can make it flicker.

Edit the fixture patch in Configure. For advanced look and target-group settings, use the `dmx` block
in `config.json`, then choose DMX in Configure:

```json
"output_mode": "dmx",
"dmx": {
  "port": "auto",
  "crossfade_seconds": 0.4,
  "pulse_seconds": 1.0,
  "front_color": [0, 0, 0, 1],
  "fixtures": [
    {"name": "Stage 1", "address": 1, "group": "stage"},
    {"name": "Front 1", "address": 31, "group": "front"}
  ],
  "groups_by_target": {"4": "stage", "3": "front", "1": "master"},
  "looks": [
    {"uuid": "<program uuid used by a launch mapping>", "name": "Red Calm", "color": [1, 0, 0, 0], "effect": "static"},
    {"uuid": "<another program uuid>", "name": "Red Big", "color": [1, 0, 0, 0], "effect": "pulse"}
  ]
}
```

- `looks` gives a DMX look to each scene a launch mapping refers to, by its program `uuid`. Colours are
  red, green, blue, white from 0 to 1.
- `groups_by_target` says which group a brightness mapping's `target` controls. `master` scales everything.

## How it works

- AsteraApp has a built-in Remote Control web server on port 8080. The bridge calls its HTTP API:
  `/api/launch`, `/api/set_brightness`, `/api/select_target`, `/api/set_power`, `/api/programs`,
  `/api/targets`, `/api/program_tile`.
- Per-effect crossfade times and the last started effect are read (read-only) from AsteraApp's local
  database.
- Settings are stored in `~/Library/Application Support/AsteraMidiBridge/config.json`.

## Building and releasing

Requires the Xcode Command Line Tools (no Xcode needed).

```bash
./app/build.sh                      # builds build/Astera MIDI Bridge.app
```

To publish an update: bump `app/VERSION`, then

```bash
./app/release.sh "What changed"     # writes dist/AsteraMidiBridge.zip and version.json
```

Commit and push. Running copies find it through **Check for Updates…**.

## Command-line bridge

`astera_midi.py` is an earlier Python version of the bridge that uses the same `config.json` format.
It has no window, fades or Now Playing.

```bash
python3 -m venv .venv && .venv/bin/python -m pip install -r requirements.txt
.venv/bin/python astera_midi.py run
```
