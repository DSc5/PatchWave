#!/bin/bash

# Shared functions for PatchWave scripts.
# Source patchwave-config.sh before this file. Expected variables:
#   LOG_FILE            - Path to the log file (may be unset early in script lifecycle)
#   HOSTNAME            - Hostname for notifications
#   TLS_INSECURE        - "true" to skip TLS verification for all curl calls
#   NTFY_TOPIC          - (optional) ntfy.sh notification URL, empty to disable
#   NOTIFY_LEVEL        - Notification level: "always" or "errors_only"
#   WEBHOOK_ON_SUCCESS  - (optional) URL to POST JSON payload on success
#   WEBHOOK_ON_FAIL     - (optional) URL to POST JSON payload on failure
#   EVENT_LOG           - (optional) Path to JSON Lines event log file

# Execute a curl request respecting TLS_INSECURE.
do_curl() {
    local opts=("-s")
    [ "${TLS_INSECURE:-false}" = "true" ] && opts+=("-k")
    CURL_RESPONSE=$(curl "${opts[@]}" "$@" 2>&1)
    CURL_EXIT=$?
}

log() {
    local message="${1:-}"
    if [ -n "$message" ]; then
        local entry
        entry="$(date '+%Y-%m-%d %H:%M:%S') $message"
        if [ -n "${LOG_FILE:-}" ]; then
            echo "$entry" | tee -a "$LOG_FILE"
        else
            echo "$entry" >&2
        fi
    fi
}

# Send a push notification via ntfy.sh.
# Notifications with priority "high" are always sent (error events).
# Notifications with any other priority are suppressed when NOTIFY_LEVEL=errors_only.
send_notification() {
    if [ -z "${NTFY_TOPIC:-}" ]; then
        return 0
    fi

    local title="${1:-PatchWave Notification}"
    local priority="${2:-default}"
    local tags="${3:-package}"
    local body="${4:-}"

    if [ "${NOTIFY_LEVEL:-always}" = "errors_only" ] && [ "$priority" != "high" ]; then
        return 0
    fi

    if [ -z "$body" ] && [ -n "${LOG_FILE:-}" ] && [ -f "$LOG_FILE" ]; then
        body="$(tail -n 25 "$LOG_FILE")"
    fi

    do_curl -X POST \
        -H "Title: ${title}" \
        -H "Priority: ${priority}" \
        -H "Tags: ${tags}" \
        -d "${body}" \
        "$NTFY_TOPIC" > /dev/null
}

write_event_log() {
    local json="$1"
    [ -z "${EVENT_LOG:-}" ] && return 0
    echo "$json" >> "$EVENT_LOG"
}

send_webhook() {
    local url="$1"
    local body="$2"

    if [ -z "${url:-}" ]; then
        return 0
    fi

    do_curl -X POST -H "Content-Type: application/json" -d "$body" "$url"

    if [ $CURL_EXIT -ne 0 ]; then
        log "WARNING: Webhook to ${url} failed (exit=${CURL_EXIT}): ${CURL_RESPONSE}"
    fi
}

error_exit() {
    local msg="$1"
    log "ERROR: $msg"

    local body
    if [ -n "${LOG_FILE:-}" ] && [ -f "${LOG_FILE}" ]; then
        body="$(tail -n 25 "$LOG_FILE")"
    else
        body="$msg"
    fi

    send_notification \
        "Patch Error – ${HOSTNAME:-unknown}" \
        "high" \
        "x,fire,alert" \
        "$body"

    local ts json
    ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

    if [ -n "${WEBHOOK_ON_FAIL:-}" ]; then
        json=$(jq -n \
            --arg ts "$ts" \
            --arg host "${HOSTNAME:-unknown}" \
            --arg msg "$msg" \
            '{"event":"failure","host":$host,"timestamp":$ts,"message":$msg}')
        send_webhook "$WEBHOOK_ON_FAIL" "$json"
    fi

    write_event_log "$(jq -n \
        --arg ts "$ts" \
        --arg host "${HOSTNAME:-unknown}" \
        --arg msg "$msg" \
        '{"timestamp":$ts,"host":$host,"event":"patch_failure","message":$msg}')"

    exit 1
}
