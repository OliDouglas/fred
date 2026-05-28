#!/usr/bin/env bash
set -euo pipefail

SITE_URL="https://chaturbate.com/milabunny_/"

username=$(echo "$SITE_URL" | sed -E 's#https?://[^/]+/([^/]+)/?#\1#')
timestamp=$(TZ='Asia/Manila' date +%Y-%m-%d_%H_%M)
filename="${username}_${timestamp}.mp4"

OUT_DIR="${1:-$(pwd)}"

mkdir -p "$OUT_DIR"

cd "$OUT_DIR"

echo "[1/3] Resolving HLS URLs from $SITE_URL"
MAP_OUTPUT=$(torsocks -i yt-dlp -f "bestvideo[height<=480]+bestaudio/best[height<=720]" -g "$SITE_URL" 2>/dev/null || true)

VIDEO_URL=$(printf '%s\n' "$MAP_OUTPUT" | grep -m1 'chunklist_.*_video_.*\.m3u8')
AUDIO_URL=$(printf '%s\n' "$MAP_OUTPUT" | grep -m1 'chunklist_.*_audio_.*\.m3u8')

if [[ -z "$VIDEO_URL" || -z "$AUDIO_URL" ]]; then
  echo "Could not resolve HLS video/audio URLs." >&2
  echo "Raw output from yt-dlp -g:" >&2
  printf '%s\n' "$MAP_OUTPUT" >&2
  exit 1
fi

ffmpeg \
  -i "$VIDEO_URL" \
  -i "$AUDIO_URL" \
  -c copy \
  "$filename"

# echo "[2/3] Downloading video stream"
# yt-dlp -v --hls-use-mpegts -o 'stream_video.mp4' "$VIDEO_URL"

# echo "[3/3] Downloading audio stream"
# yt-dlp -v --hls-use-mpegts -o 'stream_audio.m4a' "$AUDIO_URL"

echo "Done. Files are in $OUT_DIR"