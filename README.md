# Astera App Midi Bridge

A macOS app that controls Astera lights over Bluetooth through **AsteraApp**.
Use an Akai MPK mini IV, other controllers, a DAW, or any app that can send MIDI.

Pads launch scenes (effects), knobs set brightness, and the window shows what's playing with
Astera's own tile artwork.

## Install

1. Download [dist/AsteraMidiBridge.zip](dist/AsteraMidiBridge.zip), unzip it, and move
   **Astera App Midi Bridge.app** to Applications. It's built for Apple Silicon Macs on macOS 13 or later.
2. The app isn't notarized, so the first time, right-click it and choose **Open**.
3. In AsteraApp, open the sidebar, go to **APP SETTINGS**, then **Remote Control**, and set
   **Active** and **Auto start** to ON. Keep the AsteraApp window open.

Use **Show in Dock** and **Show Menu Bar Icon** in the app’s **View** menu or the purple-and-orange
menu bar icon menu. The app remembers your choices. If you hide your only visible icon, the app shows
the other one so you can reopen it. Closing the windows leaves the bridge running.

Choose **Check for Updates…** from the **Astera App Midi Bridge** menu or the menu bar icon menu to download
the latest version and restart.

## Configure

- **Maximum Brightness:** set a limit for **All Lights (master)** and each AsteraApp target
  at the top of Configure. Every MIDI brightness mapping and manual brightness send for a target
  shares that target's limit. A 50% input with an 80% maximum sends 40% brightness.
  If AsteraApp reports a current level above the new limit, the bridge lowers it to match.
  When upgrading, the lowest saved mapping maximum for a target becomes its starting limit.
- **Map a pad to a scene:** click **+ Scene mapping**, press the pad, pick the scene.
- **Map a knob to brightness:** click **+ Brightness mapping**, turn the knob, pick the target.
  "All Lights (master)" is the master brightness. Tick **Relative knob** for endless encoders in Rel mode.
- **Duplicates:** if a pad or knob is already assigned, the app asks whether to reassign it or keep both.
- **Connections:** set up MIDI inputs, the virtual port, and the AsteraApp connection.
  Use **Apply Setup** to activate changes.
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
- Right-click a scene or control for **Send Now** or **Assign MIDI…**. Assign MIDI opens its mapping
  in Configure to learn a controller or enter the MIDI source, channel, and trigger manually.
- **Scenes** can be shown as a list or a grid of square launch tiles. Use **List** or **Grid** in that section.
- Drag the handle on a Control section and drop it onto another section to change their order.
  The app remembers your scene layout and section order.
- **Brightness** lets you send levels as you move the sliders or stage a level and press **Send**.
  Levels follow the target's **Maximum Brightness** setting.
- **Targets and power** shows AsteraApp's reported brightness for each target, refreshed every 2 seconds.
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
./app/build.sh                      # builds build/Astera App Midi Bridge.app
```

To publish an update: bump `app/VERSION`, then

```bash
./app/release.sh "What changed"     # writes dist/AsteraMidiBridge.zip and version.json
```

Commit and push. Running copies find it through **Check for Updates…**.

## Command-line bridge

`astera_midi.py` is an earlier Python version of the bridge that reads the MIDI mappings in `config.json`.
It predates per-target brightness limits, fades, and Now Playing.

```bash
python3 -m venv .venv && .venv/bin/python -m pip install -r requirements.txt
.venv/bin/python astera_midi.py run
```
