#!/usr/bin/env bash
set -euo pipefail

# download_chaturbate_hls.sh — live recorder/uploader using torsocks for yt-dlp HLS URL extraction
# Keeps HLS URL resolution via torsocks while adding yt4-style segmented capture and upload.

OFFLINE_MAX_WAIT=600
RETRY_DELAY=10
TOPIC="yt-dlp-notify"
FORMAT="bestvideo[height<=720]+bestaudio/best[height<=720]"
BACKUP_REMOTES=(gd31 gd32 gd33 gd34 gd35)
BASE_FOLDER="Streams"
SEGMENT_TIME=60
BUFFER_FLUSH_INTERVAL=10
MAX_ERROR_RETRIES=10
MAX_UPLOAD_FAILS_BEFORE_SWITCH=3
COUNTER_REMOTE="${COUNTER_REMOTE:-gdrive:yt4_counts}"
COUNTER_DIR="${COUNTER_DIR:-$HOME/.yt4_counts}"
GET_URL_MAX_TRIES=5
GET_URL_RETRY_DELAY=5
SEGMENT_STALL_TIMEOUT=75
SEGMENT_CHECK_INTERVAL=2
SEGMENT_DIR="/tmp/stream_segments_$$"
STOP_REASON_FILE=""

TOR_SERVICE_NAME="${TOR_SERVICE_NAME:-tor}"
TOR_SOCKS_HOST="${TOR_SOCKS_HOST:-127.0.0.1}"
TOR_SOCKS_PORT="${TOR_SOCKS_PORT:-9050}"
TOR_READY_MAX_WAIT="${TOR_READY_MAX_WAIT:-120}"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
UPLOADER_FILE="$SCRIPT_DIR/uploader.txt"

if [[ -r "$UPLOADER_FILE" ]]; then
    mapfile -t _uploader_cfg < "$UPLOADER_FILE"
    UPLOADER="${_uploader_cfg[0]:-A1}"
    DEFAULT_REMOTE="${_uploader_cfg[1]:-gd1}"
else
    UPLOADER="${UPLOADER:-A1}"
    DEFAULT_REMOTE="${DEFAULT_REMOTE:-gd1}"
fi

log_ts() {
    TZ="Asia/Manila" date '+%Y-%m-%d %H:%M:%S'
}

tor_port_open() {
    local host="$1"
    local port="$2"

    if (exec 3<>"/dev/tcp/${host}/${port}") 2>/dev/null; then
        exec 3>&- 3<&-
        return 0
    fi

    return 1
}

ensure_tor_running() {
    local waited=0
    local tor_log="/tmp/tor_${MODEL:-session}.log"

    if ! command -v tor >/dev/null 2>&1; then
        echo "$(log_ts) ❌ tor is not installed"
        exit 1
    fi

    if tor_port_open "$TOR_SOCKS_HOST" "$TOR_SOCKS_PORT"; then
        echo "$(log_ts) ✅ Tor SOCKS proxy already reachable"
        return 0
    fi

    if command -v systemctl >/dev/null 2>&1; then
        if systemctl is-active --quiet "$TOR_SERVICE_NAME" 2>/dev/null; then
            echo "$(log_ts) ℹ️ Tor service already active"
        else
            echo "$(log_ts) ℹ️ Starting Tor via systemctl: $TOR_SERVICE_NAME"
            sudo systemctl start "$TOR_SERVICE_NAME" >/dev/null 2>&1 || true
        fi
    elif command -v service >/dev/null 2>&1; then
        echo "$(log_ts) ℹ️ Starting Tor via service: $TOR_SERVICE_NAME"
        service "$TOR_SERVICE_NAME" start >/dev/null 2>&1 || true
    fi

    if ! tor_port_open "$TOR_SOCKS_HOST" "$TOR_SOCKS_PORT"; then
        echo "$(log_ts) ℹ️ Starting Tor directly in background..."
        nohup tor \
            --SocksPort "${TOR_SOCKS_HOST}:${TOR_SOCKS_PORT}" \
            --Log "notice file ${tor_log}" \
            >/dev/null 2>&1 &
    fi

    echo "$(log_ts) 🔍 Waiting for Tor SOCKS proxy on ${TOR_SOCKS_HOST}:${TOR_SOCKS_PORT}..."

    while (( waited < TOR_READY_MAX_WAIT )); do
        if tor_port_open "$TOR_SOCKS_HOST" "$TOR_SOCKS_PORT"; then
            if torsocks curl -fsS --max-time 10 https://check.torproject.org/api/ip >/dev/null 2>&1; then
                echo "$(log_ts) ✅ Tor is running and reachable"
                return 0
            fi
        fi

        sleep 2
        waited=$((waited + 2))
    done

    echo "$(log_ts) ❌ Tor did not become ready within ${TOR_READY_MAX_WAIT}s"
    if [[ -f "$tor_log" ]]; then
        echo "$(log_ts) ℹ️ Tor log tail:"
        tail -n 30 "$tor_log" | sed 's/^/    /'
    fi
    exit 1
}

set_stop_reason() {
    local reason="$1"
    if [[ -n "${STOP_REASON_FILE:-}" ]]; then
        printf '%s' "$reason" > "$STOP_REASON_FILE" 2>/dev/null || true
    fi
}

get_stop_reason() {
    if [[ -n "${STOP_REASON_FILE:-}" && -f "$STOP_REASON_FILE" ]]; then
        cat "$STOP_REASON_FILE" 2>/dev/null || true
    fi
}

clear_stop_reason() {
    if [[ -n "${STOP_REASON_FILE:-}" ]]; then
        : > "$STOP_REASON_FILE" 2>/dev/null || true
    fi
}

infer_stop_reason_from_ffmpeg_log() {
    if [[ -f /tmp/ffmpeg.log ]]; then
        if grep -q "HTTP error 403 Forbidden" /tmp/ffmpeg.log 2>/dev/null; then
            echo "ffmpeg_http_403_forbidden"
            return 0
        fi
        if grep -q "Error opening input" /tmp/ffmpeg.log 2>/dev/null; then
            echo "ffmpeg_input_open_failed"
            return 0
        fi
    fi
    return 1
}

get_remote_counter() {
    local model="$1"
    local remote_val
    remote_val=$(rclone cat "${COUNTER_REMOTE}/${model}.txt" 2>/dev/null || echo "0")
    echo "${remote_val//[^0-9]/}" | sed -e 's/^$/0/'
}

build_remotes_list() {
    remotes_list=()
    remotes_list+=("$REMOTE")
    for r in "${BACKUP_REMOTES[@]}"; do
        if [[ "$r" != "$REMOTE" ]]; then
            remotes_list+=("$r")
        fi
    done
    if [[ ${#remotes_list[@]} -eq 0 ]]; then
        remotes_list+=("$REMOTE")
    fi
    current_remote_index=0
}

switch_remote() {
    local prev_remote
    prev_remote="${remotes_list[$current_remote_index]}"
    current_remote_index=$(( (current_remote_index + 1) % ${#remotes_list[@]} ))
    REMOTE="${remotes_list[$current_remote_index]}"
    echo "$(log_ts) 🔁 Switching remote from $prev_remote -> $REMOTE due to repeated upload failures."
    printf "\033[1;33m══════════════════════════════════════════════════════\033[0m\n"
    curl -s -d "$(log_ts) 🔁 Switching remote from $prev_remote -> $REMOTE for $MODEL (reason: repeated upload failures)" "https://ntfy.sh/$TOPIC" >/dev/null 2>&1 || true
    echo "$(log_ts) 📁 Ensuring folder exists on new remote: $REMOTE:$FOLDER"
    rclone mkdir "$REMOTE:$FOLDER" || echo "$(log_ts) ⚠️ Failed to create $REMOTE:$FOLDER (will retry on upload)."
    UPLOAD_FAIL_COUNT=0
}

is_playable_segment() {
    local f="$1"
    local v_pkts a_pkts

    v_pkts=$(ffprobe -v error -select_streams v:0 -count_packets \
        -show_entries stream=nb_read_packets -of csv=p=0 "$f" 2>/dev/null | tail -n1)

    a_pkts=$(ffprobe -v error -select_streams a:0 -count_packets \
        -show_entries stream=nb_read_packets -of csv=p=0 "$f" 2>/dev/null | tail -n1)

    [[ "${v_pkts:-0}" =~ ^[0-9]+$ ]] || v_pkts=0
    [[ "${a_pkts:-0}" =~ ^[0-9]+$ ]] || a_pkts=0

    (( v_pkts > 0 && a_pkts > 0 ))
}

get_stream_urls() {
    local tries=0
    while (( tries < GET_URL_MAX_TRIES )); do
        mapfile -t M3U8_URLS < <(
            torsocks -i yt-dlp --get-url -f "$FORMAT" "$URL" 2>/dev/null | awk 'NF { print $1 }'
        )

        if [[ ${#M3U8_URLS[@]} -ge 1 ]]; then
            echo "$(log_ts) ✅ Got ${#M3U8_URLS[@]} stream URL(s)"
            return 0
        fi

        tries=$((tries + 1))
        echo "$(log_ts) ⚠️ Failed to fetch stream URL(s), retry $tries/$GET_URL_MAX_TRIES..."
        sleep "$GET_URL_RETRY_DELAY"
    done

    return 1
}

probe_stream_status() {
    local tries=0
    local output status

    while (( tries < GET_URL_MAX_TRIES )); do
        set +e
        output=$(torsocks -i yt-dlp --simulate -f "$FORMAT" "$URL" 2>&1)
        status=$?
        set -e

        CHECK_OUTPUT="$output"
        STATUS="$status"

        if (( STATUS == 0 )); then
            return 0
        fi

        if echo "$CHECK_OUTPUT" | grep -q "Room is currently offline"; then
            return 0
        fi

        if echo "$CHECK_OUTPUT" | grep -E -q "Room is currently in a private show|Performer is currently away|Hidden session in progress|Room is password protected"; then
            return 0
        fi

        if echo "$CHECK_OUTPUT" | grep -q "HTTP Error 404"; then
            return 0
        fi

        tries=$((tries + 1))
        echo "$(log_ts) ⚠️ torsocks/yt-dlp probe failed (exit $STATUS), retry $tries/$GET_URL_MAX_TRIES..."
        printf "\033[1;33m══════════════════════════════════════════════════════\033[0m\n"
        sleep "$GET_URL_RETRY_DELAY"
    done

    return 1
}

watch_same_segment_runtime() {
    local current_file=""
    local current_since=0
    local now newest_file

    while kill -0 "$CAPTURE_PID" 2>/dev/null; do
        sleep "$SEGMENT_CHECK_INTERVAL"
        now=$SECONDS

        newest_file=$(ls -1t "$SEGMENT_DIR"/segment_*.ts 2>/dev/null | head -n 1 || true)
        if [[ -z "$newest_file" ]]; then
            continue
        fi

        if [[ "$newest_file" != "$current_file" ]]; then
            current_file="$newest_file"
            current_since=$now
            echo "$(log_ts) ℹ️ Active segment is now: $(basename "$current_file")"
            continue
        fi

        if (( now - current_since >= SEGMENT_STALL_TIMEOUT )); then
            echo "$(log_ts) ⚠️ Active segment has been the same for >${SEGMENT_STALL_TIMEOUT}s: $(basename "$current_file")"
            stop_capture "same_segment_active_too_long:$(basename "$current_file")"
            return 1
        fi
    done

    return 0
}

upload_segment() {
    local segment_file="$1"
    if ! [[ -f "$segment_file" ]]; then
        return
    fi

    if ! is_playable_segment "$segment_file"; then
        echo "$(log_ts) ⚠️ Skipping invalid segment without both audio/video streams: $segment_file"
        return
    fi

    local segment_name segment_number remote_segment remote_path rclone_output rcode
    segment_name=$(basename "$segment_file")
    segment_number=${segment_name##*_}
    segment_number=${segment_number%.ts}
    remote_segment="${folder_count}_${MODEL}_segment_${segment_number}.ts"
    remote_path="$REMOTE:$FOLDER/$remote_segment"

    echo "$(log_ts) 📤 Uploading segment: rclone moveto \"$segment_file\" \"$remote_path\""
    printf "\033[1;33m══════════════════════════════════════════════════════\033[0m\n"

    rclone_output=$(mktemp)
    if rclone moveto "$segment_file" "$remote_path" --progress --no-traverse &> "$rclone_output"; then
        echo "$(log_ts) ✅ Segment uploaded successfully: $FOLDER/$remote_segment (remote: $REMOTE)"
        printf "\033[1;32m══════════════════════════════════════════════════════\033[0m\n"
        UPLOAD_FAIL_COUNT=0
    else
        rcode=$?
        echo "$(log_ts) ❌ Segment upload failed (exit $rcode): $FOLDER/$remote_segment (remote: $REMOTE)"
        printf "\033[1;33m══════════════════════════════════════════════════════\033[0m\n"
        tail -n 20 "$rclone_output" | sed 's/^/    /'
        curl -s -d "$(log_ts) ❌ Segment upload failed: $FOLDER/$remote_segment (remote: $REMOTE). rclone exit $rcode" "https://ntfy.sh/$TOPIC" >/dev/null 2>&1 || true
        UPLOAD_FAIL_COUNT=$((UPLOAD_FAIL_COUNT + 1))
        echo "$(log_ts) ⚠️ Consecutive upload failures: $UPLOAD_FAIL_COUNT/${MAX_UPLOAD_FAILS_BEFORE_SWITCH}"
        if [[ "$UPLOAD_FAIL_COUNT" -ge "$MAX_UPLOAD_FAILS_BEFORE_SWITCH" ]]; then
            switch_remote
        fi
    fi

    rm -f "$rclone_output" 2>/dev/null || true
}

stop_capture() {
    local reason="$1"
    set_stop_reason "$reason"
    echo "$(log_ts) 🛑 Stopping FFmpeg: $reason"
    kill -TERM "$CAPTURE_PID" 2>/dev/null || true
}

cleanup() {
    echo "$(log_ts) 🛑 Received interrupt, finalizing segments and uploading..."
    printf "\033[1;33m══════════════════════════════════════════════════════\033[0m\n"

    if [[ -n "${SEGMENT_WATCHER_PID:-}" ]]; then
        kill -TERM "$SEGMENT_WATCHER_PID" 2>/dev/null || true
        wait "$SEGMENT_WATCHER_PID" 2>/dev/null || true
    fi

    if [[ -n "${CAPTURE_PID:-}" ]]; then
        kill -TERM "$CAPTURE_PID" 2>/dev/null || true
        wait "$CAPTURE_PID" 2>/dev/null || true
    fi

    if [[ -f /tmp/ffmpeg.log ]]; then
        echo "$(log_ts) ℹ️ Last ffmpeg log lines:"
        tail -n 30 /tmp/ffmpeg.log | sed 's/^/    /'
    fi

    if [[ -d "$SEGMENT_DIR" ]]; then
        shopt -s nullglob
        for segment in "$SEGMENT_DIR"/segment_*.ts; do
            upload_segment "$segment"
        done
        shopt -u nullglob
        rm -rf "$SEGMENT_DIR"
    fi

    if [[ -n "${STOP_REASON_FILE:-}" ]]; then
        rm -f "$STOP_REASON_FILE" 2>/dev/null || true
    fi

    echo "$(log_ts) ✅ Cleanup complete."
    printf "\033[1;32m══════════════════════════════════════════════════════\033[0m\n"
    exit 0
}

run_capture() {
    local url_attempts=0
    local url_max_attempts=3

    while (( url_attempts < url_max_attempts )); do
        if get_stream_urls; then
            break
        fi
        url_attempts=$((url_attempts + 1))
        if (( url_attempts < url_max_attempts )); then
            echo "$(log_ts) ⚠️ Failed to get stream URLs (attempt $url_attempts/$url_max_attempts), retrying in 5s..."
            sleep 5
        else
            set_stop_reason "url_refresh_failed_before_ffmpeg"
            echo "$(log_ts) ❌ Could not refresh stream URLs after $url_attempts attempts. Returning to main loop."
            return 0
        fi
    done

    if [[ ${#M3U8_URLS[@]} -ge 2 ]]; then
        VIDEO_URL="${M3U8_URLS[0]}"
        AUDIO_URL="${M3U8_URLS[1]}"

        echo "$(log_ts) 📺 Starting ffmpeg with separate video/audio inputs"
        printf "\033[1;33m══════════════════════════════════════════════════════\033[0m\n"

        ffmpeg \
            -hide_banner \
            -nostdin \
            -loglevel warning \
            -fflags +genpts+discardcorrupt \
            -err_detect ignore_err \
            -thread_queue_size 4096 \
            -reconnect 1 -reconnect_streamed 1 -reconnect_delay_max 5 \
            -i "$VIDEO_URL" \
            -thread_queue_size 4096 \
            -reconnect 1 -reconnect_streamed 1 -reconnect_delay_max 5 \
            -i "$AUDIO_URL" \
            -map 0:v:0 \
            -map 1:a:0 \
            -c:v copy \
            -c:a copy \
            -max_interleave_delta 0 \
            -max_muxing_queue_size 4096 \
            -avoid_negative_ts make_zero \
            -f segment \
            -segment_time "$SEGMENT_TIME" \
            -segment_time_delta 0.5 \
            -break_non_keyframes 1 \
            -segment_format mpegts \
            -reset_timestamps 1 \
            "$SEGMENT_PREFIX" -y &> /tmp/ffmpeg.log
    else
        STREAM_URL="${M3U8_URLS[0]}"

        echo "$(log_ts) 📺 Starting ffmpeg with single stream input"
        printf "\033[1;33m══════════════════════════════════════════════════════\033[0m\n"

        ffmpeg \
            -hide_banner \
            -nostdin \
            -loglevel warning \
            -fflags +genpts+discardcorrupt \
            -err_detect ignore_err \
            -reconnect 1 -reconnect_streamed 1 -reconnect_delay_max 5 \
            -i "$STREAM_URL" \
            -c copy \
            -f segment \
            -segment_time "$SEGMENT_TIME" \
            -segment_time_delta 0.5 \
            -break_non_keyframes 1 \
            -segment_format mpegts \
            -reset_timestamps 1 \
            "$SEGMENT_PREFIX" -y &> /tmp/ffmpeg.log
    fi
}

trap cleanup SIGINT SIGTERM

for cmd in ffmpeg ffprobe yt-dlp curl rclone flock torsocks; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "$(log_ts) ❌ ERROR: '$cmd' is not installed or not in PATH"
        exit 1
    fi
done

if [[ $# -lt 1 ]]; then
    echo "$(log_ts) ❗ Usage: $0 <Chaturbate URL or model name>"
    exit 1
fi

INPUT="$1"

if [[ "$INPUT" =~ :// ]] || [[ "$INPUT" == *"chaturbate.com"* ]]; then
    URL="$INPUT"
    MODEL=$(echo "$URL" | sed -E 's|.*chaturbate\.com/([^/]+)/?$|\1|')
    if [[ -z "$MODEL" ]]; then
        echo "$(log_ts) ❌ ERROR: Could not extract model name from URL"
        exit 1
    fi
else
    if [[ "$INPUT" == *_gd* ]]; then
        remote_suffix="${INPUT##*_}"
        if [[ "$remote_suffix" == gd* ]]; then
            REMOTE="$remote_suffix"
            MODEL="${INPUT%_*}"
        else
            MODEL="$INPUT"
        fi
    else
        MODEL="$INPUT"
    fi
    URL="https://chaturbate.com/${MODEL}/"
fi

LOCK_FILE="/tmp/yt4_${MODEL}.lock"
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
    echo "$(log_ts) ❌ Another instance is already running for $MODEL"
    exit 1
fi

ensure_tor_running

STOP_REASON_FILE="/tmp/yt4_${MODEL}_stop_reason_$$"
: > "$STOP_REASON_FILE" 2>/dev/null || true

echo "....................${MODEL}...................."

offline_start=""
ERROR_COUNT=0
UPLOAD_FAIL_COUNT=0
REMOTE="${REMOTE:-$DEFAULT_REMOTE}"

mkdir -p "$COUNTER_DIR"
COUNTER_FILE="$COUNTER_DIR/${MODEL}.txt"
if [[ -f "$COUNTER_FILE" ]]; then
    local_val=$(<"$COUNTER_FILE")
else
    local_val=0
fi
remote_val=$(get_remote_counter "$MODEL")
if ! [[ "$local_val" =~ ^[0-9]+$ ]]; then local_val=0; fi
if ! [[ "$remote_val" =~ ^[0-9]+$ ]]; then remote_val=0; fi

if [[ "$remote_val" -gt "$local_val" ]]; then
    folder_count="$remote_val"
    echo "$(log_ts) ℹ️ Using higher remote counter for $MODEL: $folder_count (local: $local_val)"
else
    folder_count="$local_val"
    echo "$(log_ts) ℹ️ Using local counter for $MODEL: $folder_count (remote: $remote_val)"
fi

build_remotes_list

while true; do
    printf "\n\033[1;36m═════════════════════════════════════════════════════════\033[0m\n"
    echo "$(log_ts) 🔍 Checking stream status..."
    printf "\033[1;33m══════════════════════════════════════════════════════\033[0m\n"

    probe_stream_status || true

    if echo "$CHECK_OUTPUT" | grep -q "Room is currently offline"; then
        now=$SECONDS
        if [[ -z "$offline_start" ]]; then
            offline_start=$now
            echo "$(log_ts) ⚠️ Model is offline — starting offline timer."
            printf "\033[1;33m══════════════════════════════════════════════════════\033[0m\n"
        else
            elapsed=$(( now - offline_start ))
            echo "$(log_ts) ⏳ Still offline for ${elapsed}s"
            printf "\033[1;33m══════════════════════════════════════════════════════\033[0m\n"
            if [[ "$elapsed" -ge "$OFFLINE_MAX_WAIT" ]]; then
                printf "══════════════════════════════════════════════════════\n"
                echo "$(log_ts) ❌ Offline too long (${OFFLINE_MAX_WAIT}s) — stopping."
                printf "══════════════════════════════════════════════════════\n"
                echo "[DONE_SIGNAL]"
                curl -s -d "$(log_ts) ✳️💯❇️Stopped: Offline for $((OFFLINE_MAX_WAIT / 60)) min: $URL (remote: $REMOTE)" "https://ntfy.sh/$TOPIC" >/dev/null 2>&1 || true
                rm -f "$STOP_REASON_FILE" 2>/dev/null || true
                exit 0
            fi
        fi

    elif echo "$CHECK_OUTPUT" | grep -E -q "Room is currently in a private show|Performer is currently away|Hidden session in progress|Room is password protected"; then
        echo "$(log_ts) ⏸️ Private, away, hidden, or password-protected session — will keep retrying."
        printf "\033[1;33m══════════════════════════════════════════════════════\033[0m\n"

    elif [[ $STATUS -eq 0 ]]; then
        ERROR_COUNT=0
        offline_start=""
        clear_stop_reason
        echo "$(log_ts) 📡 Stream is LIVE — starting streaming..."
        printf "\033[1;32m══════════════════════════════════════════════════════\033[0m\n"

        attempts=0
        max_attempts=8
        while true; do
            attempts=$((attempts + 1))
            remote_now=$(get_remote_counter "$MODEL")
            if ! [[ "$remote_now" =~ ^[0-9]+$ ]]; then remote_now=0; fi
            candidate=$((remote_now + 1))
            if [[ "$candidate" -le "$folder_count" ]]; then
                candidate=$((folder_count + 1))
            fi
            tmpf=$(mktemp) || tmpf="/tmp/yt4_counter_${MODEL}_$$"
            printf "%d" "$candidate" > "$tmpf"
            if rclone copyto "$tmpf" "${COUNTER_REMOTE}/${MODEL}.txt" --no-traverse 2>/tmp/rclone_counter_err.log; then
                remote_verify=$(get_remote_counter "$MODEL")
                if [[ "$remote_verify" -eq "$candidate" ]]; then
                    folder_count="$candidate"
                    printf "%d" "$folder_count" > "$COUNTER_FILE"
                    echo "$(log_ts) ✅ Claimed counter $folder_count for $MODEL (attempt $attempts)."
                    rm -f "$tmpf"
                    break
                else
                    echo "$(log_ts) ⚠️ Race detected: remote counter became $remote_verify (expected $candidate). Retrying..."
                fi
            else
                echo "$(log_ts) ⚠️ rclone failed to write remote counter (attempt $attempts). See /tmp/rclone_counter_err.log"
            fi
            rm -f "$tmpf" 2>/dev/null || true
            if [[ $attempts -ge $max_attempts ]]; then
                echo "$(log_ts) ❌ Failed to claim counter after $attempts attempts — falling back to remote value $remote_now."
                folder_count="$remote_now"
                printf "%d" "$folder_count" > "$COUNTER_FILE"
                break
            fi
            sleep $(( (RANDOM % 3) + 1 ))
        done

        echo "$(log_ts) 📦 Current session count for $MODEL: $folder_count"
        folder_ts=$(TZ="Asia/Manila" date +"%Y-%m-%d_%H_%M")
        FOLDER="$BASE_FOLDER/$MODEL/${UPLOADER:+${UPLOADER}_}${MODEL}_${folder_ts}"

        echo "$(log_ts) 📁 Creating folder $REMOTE:$FOLDER..."
        printf "\033[1;33m══════════════════════════════════════════════════════\033[0m\n"
        rclone mkdir "$REMOTE:$FOLDER"

        mkdir -p "$SEGMENT_DIR"
        rm -f /tmp/ffmpeg.log
        SEGMENT_PREFIX="$SEGMENT_DIR/segment_%03d.ts"

        run_capture &
        CAPTURE_PID=$!

        watch_same_segment_runtime &
        SEGMENT_WATCHER_PID=$!

        while kill -0 "$CAPTURE_PID" 2>/dev/null; do
            sleep "$BUFFER_FLUSH_INTERVAL"
            shopt -s nullglob
            segment_files=("$SEGMENT_DIR"/segment_*.ts)
            shopt -u nullglob
            if [[ ${#segment_files[@]} -gt 1 ]]; then
                num_to_upload=$((${#segment_files[@]} - 1))
                for (( i=0; i<num_to_upload; i++ )); do
                    upload_segment "${segment_files[i]}"
                done
            fi
        done

        if [[ -n "${SEGMENT_WATCHER_PID:-}" ]]; then
            kill -TERM "$SEGMENT_WATCHER_PID" 2>/dev/null || true
            wait "$SEGMENT_WATCHER_PID" 2>/dev/null || true
        fi

        wait "$CAPTURE_PID"
        CAPTURE_EXIT=$?

        stop_reason="$(get_stop_reason)"
        if [[ -z "$stop_reason" && "$CAPTURE_EXIT" -eq 8 ]]; then
            stop_reason="$(infer_stop_reason_from_ffmpeg_log || true)"
            if [[ -n "$stop_reason" ]]; then
                set_stop_reason "$stop_reason"
            fi
        fi

        echo "$(log_ts) ℹ️ ffmpeg/yt-dlp pipeline exited with code: $CAPTURE_EXIT"
        echo "$(log_ts) ℹ️ Stop reason: ${stop_reason:-unknown}"

        if [[ -f /tmp/ffmpeg.log ]]; then
            echo "$(log_ts) ℹ️ Last ffmpeg log lines:"
            tail -n 30 /tmp/ffmpeg.log | sed 's/^/    /'
        fi

        echo "$(log_ts) 📤 Uploading final segments..."
        printf "\033[1;33m══════════════════════════════════════════════════════\033[0m\n"
        shopt -s nullglob
        for segment in "$SEGMENT_DIR"/segment_*.ts; do
            upload_segment "$segment"
        done
        shopt -u nullglob
        rm -rf "$SEGMENT_DIR"

        if [[ "${stop_reason:-}" == same_segment_active_too_long:* ]]; then
            echo "$(log_ts) 🔁 Restarting capture because the same segment stayed active too long."
            printf "\033[1;33m══════════════════════════════════════════════════════\033[0m\n"
            sleep 2
            continue
        fi

        if [[ "$CAPTURE_EXIT" -eq 8 ]] || [[ "${stop_reason:-}" == url_refresh_failed_before_ffmpeg ]]; then
            echo "$(log_ts) 🔁 Capture will restart (reason: ${stop_reason:-unknown})."
            printf "\033[1;33m══════════════════════════════════════════════════════\033[0m\n"
            sleep 2
            continue
        fi

        echo "$(log_ts) ✅ Streaming finished!"
        printf "\033[1;33m══════════════════════════════════════════════════════\033[0m\n"
        curl -s -d "$(log_ts) ✅ Streaming complete: $FOLDER from $URL (remote: $REMOTE)" "https://ntfy.sh/$TOPIC" >/dev/null 2>&1 || true

        ERROR_COUNT=0
        offline_start=""

    elif echo "$CHECK_OUTPUT" | grep -q "HTTP Error 404"; then
        ERROR_COUNT=$((ERROR_COUNT + 1))
        echo "$(log_ts) ⚠️ Stream ended or unavailable (404 Not Found). Retrying. (error attempt $ERROR_COUNT/${MAX_ERROR_RETRIES})"
        printf "\033[1;33m══════════════════════════════════════════════════════\033[0m\n"
        if [[ "$ERROR_COUNT" -ge "$MAX_ERROR_RETRIES" ]]; then
            echo "$(log_ts) ❌ Too many errors ($ERROR_COUNT). Stopping."
            printf "\033[1;31m══════════════════════════════════════════════════════\033[0m\n"
            echo "[DONE_SIGNAL]"
            curl -s -d "$(log_ts) ❌ Stopped: Too many errors ($ERROR_COUNT) for $URL (remote: $REMOTE)" "https://ntfy.sh/$TOPIC" >/dev/null 2>&1 || true
            rm -f "$STOP_REASON_FILE" 2>/dev/null || true
            exit 1
        fi

    elif echo "$CHECK_OUTPUT" | grep -Eq "HTTP Error 502|HTTP Error 503|HTTP Error 504|Read timed out|timed out|Unable to download webpage|Unable to download JSON metadata|HTTP Error 403"; then
        ERROR_COUNT=$((ERROR_COUNT + 1))
        echo "$(log_ts) ⚠️ Temporary error (e.g., timeout, bad gateway, or 403). Retrying. (error attempt $ERROR_COUNT/${MAX_ERROR_RETRIES})"
        printf "\033[1;33m══════════════════════════════════════════════════════\033[0m\n"
        curl -s -d "$(log_ts) ⚠️ Temporary error while checking $URL (remote: $REMOTE) — attempt $ERROR_COUNT/${MAX_ERROR_RETRIES}" "https://ntfy.sh/$TOPIC" >/dev/null 2>&1 || true
        if [[ "$ERROR_COUNT" -ge "$MAX_ERROR_RETRIES" ]]; then
            echo "$(log_ts) ❌ Too many errors ($ERROR_COUNT). Stopping."
            printf "\033[1;31m══════════════════════════════════════════════════════\033[0m\n"
            echo "[DONE_SIGNAL]"
            curl -s -d "$(log_ts) ❌ Stopped: Too many errors ($ERROR_COUNT) for $URL (remote: $REMOTE)" "https://ntfy.sh/$TOPIC" >/dev/null 2>&1 || true
            rm -f "$STOP_REASON_FILE" 2>/dev/null || true
            exit 1
        fi

    else
        ERROR_COUNT=$((ERROR_COUNT + 1))
        echo "$(log_ts) ⚠️ Unexpected response while checking stream. Retrying. (error attempt $ERROR_COUNT/${MAX_ERROR_RETRIES})"
        printf "\033[1;33m══════════════════════════════════════════════════════\033[0m\n"
        if [[ "$ERROR_COUNT" -ge "$MAX_ERROR_RETRIES" ]]; then
            echo "$(log_ts) ❌ Too many errors ($ERROR_COUNT). Stopping."
            printf "\033[1;31m══════════════════════════════════════════════════════\033[0m\n"
            echo "[DONE_SIGNAL]"
            curl -s -d "$(log_ts) ❌ Stopped: Too many errors ($ERROR_COUNT) for $URL (remote: $REMOTE)" "https://ntfy.sh/$TOPIC" >/dev/null 2>&1 || true
            rm -f "$STOP_REASON_FILE" 2>/dev/null || true
            exit 1
        fi
    fi

    sleep "$RETRY_DELAY"
done