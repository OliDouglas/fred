# fred

Downloads HLS streams from Chaturbate with video and audio separated, then muxes them together.

## Usage

```bash
./download_chaturbate_hls.sh [output_directory]
```

- `output_directory` (optional): Where to save the downloaded streams. Defaults to current directory.

## Features

- Downloads video stream at 480p resolution
- Downloads audio stream separately
- Uses `torsocks` for anonymity
- Outputs: `stream_video.mp4` and `stream_audio.m4a`

## Requirements

- `yt-dlp`
- `torsocks` (optional, for Tor routing)