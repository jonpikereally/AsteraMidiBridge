# Notes for Claude sessions working on this repo

## Keep the song clip guide in step with the app

`docs/SONG_CLIP_GUIDE.md` tells other Claude chats how to write per-song lighting MIDI clips for this
app. Other chats rely on it without seeing the code, so it must match what the app does.

Whenever a change affects anything the guide describes, update the guide **in the same commit**:

- the MIDI the bridge responds to (notes, CCs, channels, the select note, the colour order)
- the default show mappings or targets
- how scenes, selection, brightness, fades or timing behave on the lights
- clip format or length rules (including the Control & Clips window's clips)
- how to get clips into Ableton

Also update the "bridge version" line near the top of the guide when you release a new version.
If a change doesn't affect the guide, leave it alone.

## Releasing

Bump `app/VERSION`, run `./app/release.sh "what changed"`, commit, push to `main`. Running copies of
the app update themselves from `version.json` and `dist/AsteraMidiBridge.zip`. Push only when Jon asks.

## Testing

Never send SIGABRT to the app (it pops a crash dialog). Restart it with `pkill -TERM -x AsteraMidiBridge`
and reopen `build/Astera MIDI Bridge.app`. Use a copy of the settings via `ASTERA_BRIDGE_CONFIG` for tests.
