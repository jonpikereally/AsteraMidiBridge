# AsteraMidiBridge

A macOS menu bar app that controls **AsteraApp** from MIDI: an Akai MPK mini IV, other controllers,
a DAW, or any app that can send MIDI.

Pads launch scenes (effects), knobs set brightness, and the window shows what's playing with
Astera's own tile artwork.

## Install

1. Download [dist/AsteraMidiBridge.zip](dist/AsteraMidiBridge.zip), unzip it, and move
   **Astera MIDI Bridge.app** to Applications. It's built for Apple Silicon Macs on macOS 13 or later.
2. The app isn't notarized, so the first time, right-click it and choose **Open**.
3. In AsteraApp, open the sidebar, go to **APP SETTINGS**, then **Remote Control**, and set
   **Active** and **Auto start** to ON. Keep the AsteraApp window open.

The app lives in the menu bar (purple and orange icon) and has no Dock icon. Choose **Show Window** from its menu.

## Using it

- **Map a pad to a scene:** click **+ Scene mapping**, press the pad, pick the scene.
- **Map a knob to brightness:** click **+ Brightness mapping**, turn the knob, pick the target.
  "All Lights (master)" is the master brightness. Tick **Relative knob** for endless encoders in Rel mode.
  Use the **Max** slider to cap how bright that control can go, for example a lower front wash in a
  small room. Everything the control sends is scaled below the cap.
- **Duplicates:** if a pad or knob is already assigned, the app asks whether to reassign it or keep both.
- **Now Playing:** shows the current effect with its Astera tile and color.
- **Fades:** scene changes follow each effect's own Crossfade setting from AsteraApp. Effects with no
  crossfade cut instantly. AsteraApp's remote control can only cut, so the bridge fades by dimming the
  master brightness to black and back up. It isn't as smooth as AsteraApp's own crossfade. Untick the
  checkbox to turn it off.
- **Save Settings… / Load Settings…:** keep mappings in a file, or move them to another Mac.
- **Check for Updates…:** downloads the latest version from this repo and restarts the app.
- **Other apps:** the bridge creates a virtual MIDI port called **Astera Bridge**. Choose it as a MIDI
  output in any app to send to the bridge.

The first time it reads AsteraApp's effect settings, macOS may ask whether the app can access data
from other apps. Click **Allow**. Without it, scene changes always cut and Now Playing only tracks
scenes launched through the bridge.

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
