#!/usr/bin/env bash
set -uo pipefail

export PATH="$PATH:/usr/local/bin:/usr/bin:$HOME/bin"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PAIRS_FILE="$SCRIPT_DIR/model_list.txt"
LOG_DIR="$SCRIPT_DIR/logs"
LIVE_FILE="$SCRIPT_DIR/live_model.txt"

# Run the scraper once per loop to refresh live_model.txt
SCRAPER_PROXY="${SCRAPER_PROXY:-socks5://127.0.0.1:9050}"
SCRAPER_CMD=(python3 "$SCRIPT_DIR/live_followed_cb.py" --proxy "$SCRAPER_PROXY")
SCRAPE_TIMEOUT=240

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

end_notification() {
    local TITLE="$1"
    local MSG="$2"

    if command -v termux-notification >/dev/null 2>&1; then
        timeout 3 termux-notification --title "$TITLE" --content "$MSG" \
            || echo "⚠️ Notification failed or timeout for $TITLE" >&2
    else
        echo "⚠️ termux-notification not found" >&2
    fi
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

load_pairs() {
    local file="$1"
    local -a new_base=() new_raw=()
    local raw_line line raw_model base_model

    if [[ ! -s "$file" ]]; then
        log WARN "pairs file missing/empty: $file"
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

rclone_update_pairs() {
    if ! command -v rclone >/dev/null 2>&1; then
        log WARN "rclone not installed; skipping pairs update"
        return 1
    fi

    if rclone copy gdrive:cb_list/ "$SCRIPT_DIR/" >/dev/null 2>&1; then
        if [[ -s "$PAIRS_FILE" ]]; then
            if load_pairs "$PAIRS_FILE"; then
                return 0
            else
                log ERROR "Failed to parse new model_list.txt after rclone copy; keeping previous models"
                return 1
            fi
        else
            log WARN "rclone copy created empty/missing $PAIRS_FILE; skipping reload"
            return 1
        fi
    else
        log WARN "rclone copy failed (exit non-zero)"
        return 1
    fi
}

declare -A LIVE_SET=()

refresh_live_models() {
    local line
    local scraper_log="$LOG_DIR/scraper.last.log"

    if ! timeout "${SCRAPE_TIMEOUT}s" "${SCRAPER_CMD[@]}" >"$scraper_log" 2>&1; then
        log WARN "scraper failed; last output:"
        tail -n 20 "$scraper_log" >&2 || true
        return 1
    fi

    if [[ ! -s "$LIVE_FILE" ]]; then
        log WARN "live file missing/empty: $LIVE_FILE"
        return 1
    fi

    LIVE_SET=()
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%$'\r'}"
        line="$(awk '{$1=$1; print}' <<< "$line")"
        [[ -z "$line" ]] && continue
        LIVE_SET["$line"]=1
    done < "$LIVE_FILE"

    log INFO "Loaded ${#LIVE_SET[@]} live models from $LIVE_FILE"
    return 0
}

is_live_model() {
    local model="$1"
    [[ -n "${LIVE_SET[$model]+x}" ]]
}

if ! load_pairs "$PAIRS_FILE"; then
    echo "$(timestamp) ERROR: initial load of model_list failed; fix $PAIRS_FILE and restart" >&2
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
OFFLINE_LIMIT=600

LOOP_COUNTER=0
RCLONE_EVERY=1
LIVE_REFRESH_EVERY=1

while true; do
    echo -e "\n\033[1;32m═════════════════════════════════════════════════════════\033[0m"

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
    if (( LOOP_COUNTER % RCLONE_EVERY == 0 )); then
        rclone_update_pairs || dbg "rclone update attempt failed or skipped"
    fi

    printf "⏱️ Next check in 6..."
    echo -e "\n\033[1;31m═════════════════════════════════════════════════════════\033[0m"
    sleep 60
done