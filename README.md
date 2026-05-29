# fred

`download_chaturbate_hls.sh` is a Chaturbate live recorder/uploader that keeps HLS URL resolution via `torsocks` while recording to MPEG-TS segments and uploading them via `rclone`.

## Usage

```bash
./download_chaturbate_hls.sh <Chaturbate URL or model name>
```

## Features

- Uses `torsocks` for `yt-dlp` HLS URL extraction
- Records live streams into `.ts` segments with `ffmpeg`
- Uploads segments to remote storage via `rclone`
- Supports per-model locking, retry logic, remote failover, and upload counters

## Requirements

- `yt-dlp`
- `torsocks`
- `ffmpeg`
- `ffprobe`
- `rclone`
- `flock`