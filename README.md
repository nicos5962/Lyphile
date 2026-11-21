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

## Version
1.0

## Author
nicos
