#!/usr/bin/env bash
set -uo pipefail

export PATH="$PATH:/usr/local/bin:/usr/bin:$HOME/bin"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODEL_LIST_FILE="$SCRIPT_DIR/model_list.txt"
LOG_DIR="$SCRIPT_DIR/logs"
LIVE_FILE="$SCRIPT_DIR/live_model.txt"

# Run the scraper once per loop to refresh live_model.txt
SCRAPER_PROXY="${SCRAPER_PROXY:-socks5://127.0.0.1:9050}"
SCRAPER_CMD=(python3 "$SCRIPT_DIR/live_followed_cb.py" --proxy "$SCRAPER_PROXY")
SCRAPE_TIMEOUT=240

TOR_SERVICE_NAME="${TOR_SERVICE_NAME:-tor}"
TOR_SOCKS_HOST="${TOR_SOCKS_HOST:-127.0.0.1}"
TOR_SOCKS_PORT="${TOR_SOCKS_PORT:-9050}"
TOR_READY_MAX_WAIT="${TOR_READY_MAX_WAIT:-120}"

ENABLE_API_DEBUG=0

timestamp() { date '+%y/%m/%d %H:%M:%S'; }

LAST_SEP=""
LAST_BLANK=0

print_sep_once() {
    local id="$1"
    if [[ "$LAST_SEP" != "$id" ]]; then
        printf "\n\033[1;33m══════════════════════════════════════════════════════\033[0m\n"
        LAST_SEP="$id"
        LAST_BLANK=0
    fi
}

spacer() {
    if (( LAST_BLANK == 0 )); then
        printf "\n"
        LAST_BLANK=1
    fi
}

log() {
    local level="$1" msg="$2" color reset
    reset="\033[0m"
    case "$level" in
        DEBUG) color="\033[1;35m" ;;
        INFO)  color="\033[1;34m" ;;
        WARN)  color="\033[1;33m" ;;
        ERROR) color="\033[1;31m" ;;
        *)     color="\033[0m" ;;
    esac
    LAST_BLANK=0
    printf "%s %b%s%b %s\n" "$(timestamp)" "$color" "$level:" "$reset" "$msg" >&2
}

dbg() { echo "$(timestamp) DEBUG: $*" >&2; }

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
    local tor_log="/tmp/tor_multi_cb.log"

    if ! command -v tor >/dev/null 2>&1; then
        log ERROR "tor is not installed"
        return 1
    fi

    if tor_port_open "$TOR_SOCKS_HOST" "$TOR_SOCKS_PORT"; then
        log INFO "Tor SOCKS proxy already reachable"
        return 0
    fi

    if command -v systemctl >/dev/null 2>&1; then
        if systemctl is-active --quiet "$TOR_SERVICE_NAME" 2>/dev/null; then
            log INFO "Tor service already active"
        else
            log INFO "Starting Tor via systemctl: $TOR_SERVICE_NAME"
            sudo systemctl start "$TOR_SERVICE_NAME" >/dev/null 2>&1 || true
        fi
    elif command -v service >/dev/null 2>&1; then
        log INFO "Starting Tor via service: $TOR_SERVICE_NAME"
        service "$TOR_SERVICE_NAME" start >/dev/null 2>&1 || true
    fi

    if ! tor_port_open "$TOR_SOCKS_HOST" "$TOR_SOCKS_PORT"; then
        log INFO "Starting Tor directly in background..."
        nohup tor \
            --SocksPort "${TOR_SOCKS_HOST}:${TOR_SOCKS_PORT}" \
            --Log "notice file ${tor_log}" \
            >/dev/null 2>&1 &
    fi

    log INFO "Waiting for Tor SOCKS proxy on ${TOR_SOCKS_HOST}:${TOR_SOCKS_PORT}..."

    while (( waited < TOR_READY_MAX_WAIT )); do
        if tor_port_open "$TOR_SOCKS_HOST" "$TOR_SOCKS_PORT"; then
            if curl -fsS --max-time 10 --socks5-hostname "${TOR_SOCKS_HOST}:${TOR_SOCKS_PORT}" https://check.torproject.org/api/ip >/dev/null 2>&1; then
                log INFO "Tor is running and reachable"
                return 0
            fi
        fi

        sleep 2
        waited=$((waited + 2))
    done

    log ERROR "Tor did not become ready within ${TOR_READY_MAX_WAIT}s"
    if [[ -f "$tor_log" ]]; then
        log INFO "Tor log tail:"
        tail -n 30 "$tor_log" | sed 's/^/    /' >&2 || true
    fi
    return 1
}

check_model_status_api() {
    local model="$1"
    local api_json room_status attempt debugfile first_char

    for attempt in 1 2 3; do
        if command -v torsocks >/dev/null 2>&1; then
            api_json="$(timeout 20s torsocks -i curl -sS --max-time 20 \
                -H "User-Agent: Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36" \
                -H "Accept: application/json" \
                "https://chaturbate.com/api/chatvideocontext/${model}/" \
                || true)"
        else
            api_json="$(timeout 20s curl -sS --max-time 20 \
                -H "User-Agent: Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36" \
                -H "Accept: application/json" \
                "https://chaturbate.com/api/chatvideocontext/${model}/" \
                || true)"
        fi

        if [[ -z "$api_json" ]]; then
            sleep $((attempt))
            continue
        fi

        first_char="${api_json:0:1}"
        if [[ "$first_char" != "{" && "$first_char" != "[" ]]; then
            if [[ "${ENABLE_API_DEBUG:-0}" -eq 1 ]]; then
                debugfile="$LOG_DIR/${model}_api_debug_$(date +%Y%m%d_%H%M%S).txt"
                printf '%s\n' "$api_json" > "$debugfile" 2>/dev/null || true
                dbg "Wrote API debug to $debugfile"
            fi
            sleep $((attempt))
            continue
        fi

        room_status="$(printf '%s' "$api_json" | jq -r '.room_status' 2>/dev/null || true)"

        if [[ -z "$room_status" ]]; then
            room_status="$(printf '%s' "$api_json" | sed -n 's/.*"room_status"[[:space:]]*:[[:space:]]*"\([^\"]*\)".*/\1/p' || true)"
            if [[ -n "$room_status" ]]; then
                dbg "sed recovered room_status='$room_status' for $model"
            else
                if [[ "${ENABLE_API_DEBUG:-0}" -eq 1 ]]; then
                    debugfile="$LOG_DIR/${model}_api_debug_$(date +%Y%m%d_%H%M%S).txt"
                    printf '%s\n' "$api_json" > "$debugfile" 2>/dev/null || true
                    dbg "jq parse error for $model"
                    dbg "Wrote API debug to $debugfile"
                else
                    dbg "jq parse error for $model — API debug suppressed"
                fi
                echo jq_error
                return
            fi
        fi

        if [[ "$room_status" == "public" ]]; then
            echo live
        else
            echo offline
        fi
        return
    done

    echo offline
}

dbg "Script started in $SCRIPT_DIR"
mkdir -p "$LOG_DIR" || {
    echo "$(timestamp) ERROR: mkdir -p $LOG_DIR failed" >&2
    exit 1
}

display_list() {
    awk '{ printf " \033[1;93m%2d.\033[0m %s\n", NR, $0 }' "$1" >&2
}

sanitize_for_filename() {
    local s="$1"
    s="${s//@/_}"
    s="${s//./_}"
    printf "%s" "$s"
}

is_running_for() {
    local model_raw="$1"
    local pids

    pids="$(pgrep -f "[d]l_cb.sh $model_raw" || true)"
    [[ -z "$pids" ]] && return 1

    while read -r pid; do
        [[ -z "$pid" ]] && continue
        if ps -o args= -p "$pid" 2>/dev/null | grep -F " $model_raw" >/dev/null; then
            return 0
        fi
    done < <(printf "%s\n" $pids)

    return 1
}

kill_for() {
    local model_raw="$1"
    local pids

    pids="$(pgrep -f "[d]l_cb.sh $model_raw" || true)"
    [[ -z "$pids" ]] && return

    while read -r pid; do
        [[ -z "$pid" ]] && continue
        if ps -o args= -p "$pid" 2>/dev/null | grep -F " $model_raw" >/dev/null; then
            dbg "killing pid $pid for $model_raw"
            kill "$pid" 2>/dev/null || kill -9 "$pid" 2>/dev/null
        fi
    done < <(printf "%s\n" $pids)
}

declare -a MONITOR_BASE_MODELS=()
declare -a MONITOR_RAW_MODELS=()

load_model_list() {
    local file="$1"
    local -a new_base=() new_raw=()
    local raw_line line raw_model base_model

    if [[ ! -s "$file" ]]; then
        log WARN "model list file missing/empty: $file"
        return 1
    fi

    while IFS= read -r raw_line || [[ -n "$raw_line" ]]; do
        line="${raw_line%$'\r'}"
        line="$(awk '{$1=$1; print}' <<< "$line")"

        [[ -z "$line" ]] && continue
        [[ "$line" =~ ^# ]] && continue

        raw_model="$line"

        if [[ "$raw_model" == *_gd* ]]; then
            base_model="${raw_model%_gd*}"
        else
            base_model="$raw_model"
        fi

        new_base+=("$base_model")
        new_raw+=("$raw_model")
    done < "$file"

    if (( ${#new_base[@]} == 0 )); then
        log ERROR "No valid models parsed from $file"
        return 1
    fi

    MONITOR_BASE_MODELS=("${new_base[@]}")
    MONITOR_RAW_MODELS=("${new_raw[@]}")

    log INFO "Loaded ${#MONITOR_BASE_MODELS[@]} models from $file"
    return 0
}

rclone_update_model_list() {
    if ! command -v rclone >/dev/null 2>&1; then
        log WARN "rclone not installed; skipping model list update"
        return 1
    fi

    if rclone copy gdrive:cb_list/ "$SCRIPT_DIR/" >/dev/null 2>&1; then
        if [[ -s "$MODEL_LIST_FILE" ]]; then
            if load_model_list "$MODEL_LIST_FILE"; then
                return 0
            else
                log ERROR "Failed to parse new model_list.txt after rclone copy; keeping previous models"
                return 1
            fi
        else
            log WARN "rclone copy created empty/missing $MODEL_LIST_FILE; skipping reload"
            return 1
        fi
    else
        log WARN "rclone copy failed (exit non-zero)"
        return 1
    fi
}

declare -A LIVE_SET=()

refresh_live_models() {
    local line status
    local scraper_log="$LOG_DIR/scraper.last.log"

    if timeout "${SCRAPE_TIMEOUT}s" "${SCRAPER_CMD[@]}" >"$scraper_log" 2>&1; then
        if [[ -s "$LIVE_FILE" ]]; then
            LIVE_SET=()
            while IFS= read -r line || [[ -n "$line" ]]; do
                line="${line%$'\r'}"
                line="$(awk '{$1=$1; print}' <<< "$line")"
                [[ -z "$line" ]] && continue
                LIVE_SET["$line"]=1
            done < "$LIVE_FILE"

            log INFO "Loaded ${#LIVE_SET[@]} live models from scraper"
            return 0
        fi
    fi

    log WARN "scraper failed or empty; falling back to API checks"
    if (( ${#MONITOR_BASE_MODELS[@]} > 0 )); then
        LIVE_SET=()
        for model in "${MONITOR_BASE_MODELS[@]}"; do
            status="$(check_model_status_api "$model" 2>/dev/null || echo offline)"
            if [[ "$status" == "live" ]]; then
                LIVE_SET["$model"]=1
            fi
        done
        log INFO "Loaded ${#LIVE_SET[@]} live models via API fallback"
        return 0
    else
        log ERROR "No models to check via API"
        return 1
    fi
}

is_live_model() {
    local model="$1"
    [[ -n "${LIVE_SET[$model]+x}" ]]
}

if ! load_model_list "$MODEL_LIST_FILE"; then
    log WARN "model_list.txt missing/empty; attempting to download it first"
    rclone_update_model_list || true
fi

if ! load_model_list "$MODEL_LIST_FILE"; then
    echo "$(timestamp) ERROR: initial load of model_list failed; fix $MODEL_LIST_FILE and restart" >&2
    exit 1
fi

if ! ensure_tor_running; then
    echo "$(timestamp) ERROR: Tor is required for the monitor loop" >&2
    exit 1
fi

spacer
printf "%s\n" "$(timestamp) ✅ Monitoring the following models:" >&2
for i in "${!MONITOR_BASE_MODELS[@]}"; do
    printf "  - %s >>> log: %s/%s_monitor.log\n" \
        "${MONITOR_BASE_MODELS[i]}" \
        "$LOG_DIR" \
        "${MONITOR_BASE_MODELS[i]}" >&2
done
spacer

declare -A OFFLINE_SINCE
OFFLINE_LIMIT=1000

LOOP_COUNTER=0
RCLONE_EVERY=1
LIVE_REFRESH_EVERY=1

while true; do
    echo -e "\n\033[1;32m═════════════════════════════════════════════════════════\033[0m"

    if (( LOOP_COUNTER % RCLONE_EVERY == 0 )); then
        rclone_update_model_list || dbg "rclone update attempt failed or skipped"
    fi

    if (( LOOP_COUNTER % LIVE_REFRESH_EVERY == 0 )); then
        refresh_live_models || dbg "live-model refresh failed; using previous live set"
    fi

    for idx in "${!MONITOR_BASE_MODELS[@]}"; do
        model_base="${MONITOR_BASE_MODELS[idx]}"
        model_raw="${MONITOR_RAW_MODELS[idx]}"
        KEY="$model_base"

        if is_live_model "$model_base"; then
            status="live"
        else
            status="offline"
        fi

        printf "[%s]\n📺 %s >>> %s\n" \
            "$(timestamp)" "$model_base" "$status"

        if [[ $status == live ]]; then
            unset OFFLINE_SINCE["$KEY"] 2>/dev/null

            if ! is_running_for "$model_raw"; then
                printf "\n🚀 Starting\n"
                LOG_FILE="$LOG_DIR/${model_base}_monitor.log"

                mkdir -p "$LOG_DIR" 2>/dev/null || true

                if : >"$LOG_FILE" 2>/dev/null; then
                    dbg "Truncated log $LOG_FILE"
                else
                    dbg "Failed to truncate $LOG_FILE (continuing anyway)"
                fi

                setsid "$SCRIPT_DIR/dl_cb.sh" "$model_raw" \
                    >"$LOG_FILE" 2>&1 < /dev/null & disown
                sleep 2
            else
                printf "ℹ️   dl_cb.sh already running\n"
            fi

        elif [[ $status == offline ]]; then
            if is_running_for "$model_raw"; then
                if [[ -z "${OFFLINE_SINCE[$KEY]+x}" ]]; then
                    OFFLINE_SINCE["$KEY"]=$(date +%s)
                    printf "⏳ reported OFFLINE — starting ${OFFLINE_LIMIT}s timer\n"
                else
                    now=$(date +%s)
                    offline_time=$(( now - OFFLINE_SINCE["$KEY"] ))
                    if (( offline_time >= OFFLINE_LIMIT )); then
                        printf "\033[1;31m🛑 offline for $offline_time sec — killing dl_cb.sh\033[0m\n"
                        kill_for "$model_raw"
                        unset OFFLINE_SINCE["$KEY"]
                    else
                        printf "⏳offline for ${offline_time}s (waiting for ${OFFLINE_LIMIT}s)\n"
                    fi
                fi
            else
                unset OFFLINE_SINCE["$KEY"] 2>/dev/null
            fi
        else
            unset OFFLINE_SINCE["$KEY"] 2>/dev/null
        fi

        echo -e "\033[1;33m══════════════════════════════════════════════════════\033[0m"
        sleep 0.7
    done

    LOOP_COUNTER=$((LOOP_COUNTER + 1))

    printf "⏱️ Next check in 10 seconds..."
    echo -e "\n\033[1;31m═════════════════════════════════════════════════════════\033[0m"
    sleep 10
done