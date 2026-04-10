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

# Create a Proxmox snapshot and record its name in STATE_DIR/last_snapshot.
# Aborts with error_exit if snapshots are disabled, a leftover snapshot exists,
# or the API call fails.
create_proxmox_snapshot() {
    [ "${PROXMOX_SNAPSHOT_BEFORE_PATCH:-false}" = "true" ] || return 0

    if [ -f "$STATE_DIR/last_snapshot" ]; then
        local old_snapshot
        old_snapshot=$(cat "$STATE_DIR/last_snapshot")
        error_exit "Leftover snapshot reference '${old_snapshot}' found from a previous run. Verify and clean up the snapshot on Proxmox manually, then remove '${STATE_DIR}/last_snapshot' to continue."
    fi

    local snapshot_name="patchwave_$(date +%Y%m%d_%H%M%S)"
    log "Creating Proxmox snapshot before patching..."

    do_curl -X POST \
        "https://${PROXMOX_HOST}:8006/api2/json/nodes/${PROXMOX_NODE}/qemu/${PROXMOX_VMID}/snapshot" \
        -H "Authorization: ${PROXMOX_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "{\"snapname\": \"${snapshot_name}\"}"

    if [ $CURL_EXIT -ne 0 ] || echo "$CURL_RESPONSE" | jq -e '.errors' > /dev/null 2>&1; then
        error_exit "Failed to create Proxmox snapshot before patching. (exit=${CURL_EXIT}) ${CURL_RESPONSE}"
    fi

    echo "${snapshot_name}" > "$STATE_DIR/last_snapshot"
    log "Snapshot created successfully: ${snapshot_name}"
}

# Delete the Proxmox snapshot recorded in STATE_DIR/last_snapshot (if any).
# Exits with error_exit on API failure. Safe to call even when snapshots are
# disabled or no snapshot file exists.
delete_proxmox_snapshot() {
    [ "${PROXMOX_SNAPSHOT_BEFORE_PATCH:-false}" = "true" ] || return 0
    [ "${PROXMOX_SNAPSHOT_DELETE_AFTER_SUCCESS:-false}" = "true" ] || return 0
    [ -f "$STATE_DIR/last_snapshot" ] || return 0

    local snapshot_name
    snapshot_name=$(cat "$STATE_DIR/last_snapshot")
    log "Deleting Proxmox snapshot: ${snapshot_name}"

    do_curl -X DELETE \
        "https://${PROXMOX_HOST}:8006/api2/json/nodes/${PROXMOX_NODE}/qemu/${PROXMOX_VMID}/snapshot/${snapshot_name}" \
        -H "Authorization: ${PROXMOX_TOKEN}"

    if [ $CURL_EXIT -ne 0 ] || echo "$CURL_RESPONSE" | jq -e '.errors' > /dev/null 2>&1; then
        error_exit "Failed to delete snapshot ${snapshot_name} on VM ${PROXMOX_VMID}. (exit=${CURL_EXIT}) ${CURL_RESPONSE}"
    fi

    log "Successfully deleted snapshot: ${snapshot_name}"
    rm -f "$STATE_DIR/last_snapshot"
}

check_disk_space() {
    local required_gb="$1"
    local available_gb

    # Always check /var (package download cache for all distros)
    available_gb=$(df --output=avail -BG /var | tail -1 | tr -d ' G')
    if [ "$available_gb" -lt "$required_gb" ]; then
        error_exit "Precheck failed: insufficient disk space on /var — ${available_gb}GB available, ${required_gb}GB required."
    fi
    log "Precheck passed: ${available_gb}GB available on /var (required: ${required_gb}GB)."

    # If /var is on a separate filesystem, also check / for package installation
    local var_dev root_dev
    var_dev=$(df --output=source /var | tail -1 | tr -d ' ')
    root_dev=$(df --output=source / | tail -1 | tr -d ' ')
    if [ "$var_dev" != "$root_dev" ]; then
        available_gb=$(df --output=avail -BG / | tail -1 | tr -d ' G')
        if [ "$available_gb" -lt "$required_gb" ]; then
            error_exit "Precheck failed: insufficient disk space on / — ${available_gb}GB available, ${required_gb}GB required."
        fi
        log "Precheck passed: ${available_gb}GB available on / (required: ${required_gb}GB)."
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
