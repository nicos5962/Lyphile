# Lyphile

Lyrion Music Server (LMS) plugin and skin based on the Default skin. It adds *external player* helpers that play files and DVDs through VLC, mpv or ffmpeg while Lyrion keeps full control (play, pause, seek, audio stream, chapters, volume).

## Features
- **Lyphile skin** based on the Default skin.
- **Player helpers** (`Bin/`), selected per Lyrion player in *Select Player*:
  - `vlc-Player`: VLC controlled through its `oldrc` interface
  - `vlc-Player-lua`: VLC controlled through the Lua HTTP interface
  - `mpv-Player`: mpv controlled through its IPC socket
  - `FFmpeg-Player`: ffmpeg with a filter graph, controlled with `zmqsend`
  - VLC and mpv output goes through a fifo into ffmpeg (`-readrate 1`) to stdout.
- **Transcoding rules** per player: mp3 / flc / pcm format boxes, and overrides for audio / dvd / video source groups (rules `<src>-<fmt>-*-<mac>`).
- **Transcode preferences**: bit depth, sample rate, always downmix to stereo.
- Settings pages for every player: audio stream choice (only usable streams are listed), chapters, stream and statistics information, cover art.
- Live equalizer for the ffmpeg player (not available with VLC and mpv).
- Log files viewer.

## Requirements
- Lyrion Music Server 9.x
- `ffmpeg` (with `zmq` support) and `zmqsend`, `ffprobe`
- `vlc` and / or `mpv` for the corresponding helpers
- `socat`
- The `custom-init.sh` of the Docker setup installs these packages

## Installation
Copy the `Lyphile` folder into the `Plugins` directory of the server cache (for example `/config/cache/Plugins`) and restart Lyrion. Then pick the helper for each player under *Settings > Plugins > Lyphile > Select Player*.

## Files
| File | Purpose |
| --- | --- |
| `Plugin.pm` | Plugin entry point, applies the per-player transcoding rules |
| `Settings.pm`, `HTML/` | Settings pages |
| `VLC/`, `MPV/`, `FFmpeg/` | Player backends (control, progress, streams, equalizer) |
| `Bin/` | Helper programs started by the transcoding rules |
| `custom-convert.conf` | Base transcoding rules |
| `strings.txt` | Text strings |

`Bin/save`, `Bin/save3` and `HTML/EN/plugins/Lyphile/settings/vlc/save` are older copies kept as backups.

## Changelog

### 1.1
- Bug fix: the VLC player page no longer shows for a player set to "none" (it shows only for the `vlc-Player` helper).
- Bug fix (VLC oldrc): a pause followed by a resume left VLC paused for good, so VLC, ffmpeg and the helper stayed running and the player page kept reporting "oldrc interface active" while another track played. A paused VLC is now recognised, so it resumes and is cleaned up.
- Bug fix: the answers of the JSON endpoints of the player pages (`vlc`, `vlclua`, `mpv`, `ffmpeg`), of the kill buttons and of the log page were sent twice, so on a browser connection that is kept open the answer to the next request was the wrong one. Symptoms: the playlist panel or a page showing raw JSON, a log page showing garbage, now and then. Every endpoint now returns its answer once.
- Bug fix: on every player page (VLC, VLC Lua, mpv, ffmpeg), after switching an audio stream or chapter, opening another tab of the settings asked to save the settings. The settings page of the server counts a control as changed when its value differs from its `defaultValue` (a select has none); the controls of these pages now report their current value as default, as there is nothing to save on them.
- Change: Bit depth and Sample rate (Control tab of the VLC, VLC Lua, mpv and ffmpeg pages) are now saved with the Apply button instead of at once. Changing one and then opening another sub tab or another tab of the Settings asks "Some settings were changed. Do you want to save them?" (Yes saves, No puts back the saved values, Cancel stays). A value is still refused while a track plays. The other controls of the pages act at once and never ask.
- Improved "Now playing" frame on the main page: the bitrate line shows the details of the audio stream being played (as on the player page, text between parentheses left out) and follows an audio-stream switch.
- A log page that cannot find a log now writes the requested player and type to the server log.

### 1.0
- First release.

## Version
1.1

## Author
nicos
