#!/bin/bash
# master-monitor.sh - Master daemon that monitors all Claude Code sessions
# and sends WhatsApp notifications when approval is needed
#
# Usage: ./master-monitor.sh [--poll-interval SECONDS] [--reminder-interval SECONDS]
#
# Environment variables (optional - reads from ~/.clawdbot/clawdbot.json if not set):
#   CLAWDBOT_PHONE          - Phone number to notify (default: from clawdbot config)
#   CLAWDBOT_WEBHOOK_TOKEN  - Webhook auth token (default: from clawdbot config)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB_DIR="$SCRIPT_DIR/lib"

# Configuration
POLL_INTERVAL="${POLL_INTERVAL:-10}"
REMINDER_INTERVAL="${REMINDER_INTERVAL:-300}"

# File paths (use secure temp directory creation)
STATE_DIR="${CLAUDE_MONITOR_STATE_DIR:-/tmp/claude-orchestrator}"
# Create state dir with secure permissions if it doesn't exist
if [ ! -d "$STATE_DIR" ]; then
    mkdir -p "$STATE_DIR"
    chmod 700 "$STATE_DIR"
fi
LOG_FILE="$STATE_DIR/master-monitor.log"
PID_FILE="$STATE_DIR/master-monitor.pid"
NOTIFY_STATE_DIR="$STATE_DIR/notify-state"
CHANNEL_REGISTRY="$STATE_DIR/channel-registry.json"

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --poll-interval)
            POLL_INTERVAL="$2"
            shift 2
            ;;
        --reminder-interval)
            REMINDER_INTERVAL="$2"
            shift 2
            ;;
        --help|-h)
            echo "Usage: $0 [--poll-interval SECONDS] [--reminder-interval SECONDS]"
            echo ""
            echo "Options:"
            echo "  --poll-interval      How often to check sessions (default: 10)"
            echo "  --reminder-interval  How often to resend notifications (default: 300)"
            echo ""
            echo "Environment variables (optional - reads from ~/.clawdbot/clawdbot.json):"
            echo "  CLAWDBOT_PHONE          Override phone number"
            echo "  CLAWDBOT_WEBHOOK_TOKEN  Override webhook auth token"
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            exit 1
            ;;
    esac
done

# Ensure state directories exist
mkdir -p "$STATE_DIR" "$NOTIFY_STATE_DIR"

# Logging function
log() {
    local level="$1"
    shift
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $*"
    echo "$msg"
    echo "$msg" >> "$LOG_FILE"
}

# Clean up on exit
cleanup() {
    log "INFO" "Shutting down master monitor..."
    rm -f "$PID_FILE"
    exit 0
}

trap cleanup SIGINT SIGTERM EXIT

# Check for existing instance
if [ -f "$PID_FILE" ]; then
    OLD_PID=$(cat "$PID_FILE")
    if kill -0 "$OLD_PID" 2>/dev/null; then
        echo "Master monitor already running (PID $OLD_PID)" >&2
        echo "Stop it with: kill $OLD_PID" >&2
        exit 1
    fi
    rm -f "$PID_FILE"
fi

# Write PID file
echo $$ > "$PID_FILE"

# Hash function for deduplication
hash_prompt() {
    echo "$1" | md5 2>/dev/null || echo "$1" | md5sum 2>/dev/null | cut -d' ' -f1
}

# Channel registry functions
get_session_channel() {
    local session="$1"
    if [ -f "$CHANNEL_REGISTRY" ]; then
        jq -r --arg sess "$session" '.[$sess] // empty' "$CHANNEL_REGISTRY" 2>/dev/null || echo ""
    else
        echo ""
    fi
}

set_session_channel() {
    local session="$1"
    local channel="$2"
    local temp_file
    temp_file=$(mktemp)
    if [ -f "$CHANNEL_REGISTRY" ]; then
        jq --arg sess "$session" --arg chan "$channel" '.[$sess] = $chan' "$CHANNEL_REGISTRY" > "$temp_file"
    else
        echo "{\"$session\": \"$channel\"}" | jq '.' > "$temp_file"
    fi
    mv "$temp_file" "$CHANNEL_REGISTRY"
    chmod 600 "$CHANNEL_REGISTRY"
}

remove_session_channel() {
    local session="$1"
    if [ -f "$CHANNEL_REGISTRY" ]; then
        local temp_file
        temp_file=$(mktemp)
        jq --arg sess "$session" 'del(.[$sess])' "$CHANNEL_REGISTRY" > "$temp_file"
        mv "$temp_file" "$CHANNEL_REGISTRY"
    fi
}

# Get notification state for a session
get_notify_state() {
    local session="$1"
    local state_file="$NOTIFY_STATE_DIR/$session.state"
    if [ -f "$state_file" ]; then
        cat "$state_file"
    else
        echo "0|0||"
    fi
}

# Set notification state for a session
set_notify_state() {
    local session="$1"
    local timestamp="$2"
    local reminder_count="$3"
    local hash="$4"
    local state_file="$NOTIFY_STATE_DIR/$session.state"
    echo "$timestamp|$reminder_count|$hash" > "$state_file"
}

# Clear notification state for a session
clear_notify_state() {
    local session="$1"
    local state_file="$NOTIFY_STATE_DIR/$session.state"
    rm -f "$state_file"
}

# Send WhatsApp notification
send_notification() {
    local session="$1"
    local details="$2"
    local reminder_count="${3:-0}"

    local reminder_text=""
    if [ "$reminder_count" -gt 0 ]; then
        reminder_text=" (reminder #$reminder_count)"
    fi

    local message="🔒 Session '$session' needs approval$reminder_text

$details

Reply with:
• approve $session - Allow once
• always $session - Allow all similar
• deny $session - Reject"

    log "INFO" "Sending notification for session: $session"

    # Get channel from registry
    local channel
    channel=$(get_session_channel "$session")
    
    # Call send-notification with channel override if found
    if [ -n "$channel" ]; then
        log "INFO" "Using channel from registry: $channel"
        if OPENCLAW_REPLY_TO="$channel" "$LIB_DIR/send-notification.sh" "$message" >/dev/null 2>&1; then
            log "INFO" "Notification sent for session: $session to $channel"
            return 0
        fi
    else
        log "WARN" "No channel found in registry for $session, using default"
        if "$LIB_DIR/send-notification.sh" "$message" >/dev/null 2>&1; then
            log "INFO" "Notification sent for session: $session (default channel)"
            return 0
        fi
    fi
    
    log "ERROR" "Failed to send notification for session: $session"
    return 1
}

# Extract approval details from session output
extract_approval_details() {
    local session="$1"
    local output
    output=$(tmux capture-pane -t "$session" -p -S -50 2>/dev/null) || return 1

    local details=""

    # Look for the approval prompt line to find where the prompt starts
    local approval_line_num
    approval_line_num=$(echo "$output" | grep -n -E "Do you want" | tail -1 | cut -d: -f1)

    if [ -n "$approval_line_num" ]; then
        # Get a few lines BEFORE the "Do you want" line - that's where the command is
        # The format is usually:
        #   Bash command
        #   <the actual command>
        #   <description>
        #   Do you want to proceed?
        local start_line=$((approval_line_num - 5))
        [ "$start_line" -lt 1 ] && start_line=1

        # Extract lines around the prompt
        local context
        context=$(echo "$output" | sed -n "${start_line},${approval_line_num}p" | grep -v "^$" | grep -v "^─" | grep -v "^╌")

        # Look for the actual command in the context
        # Try to find Bash/Write/Edit/Read/Fetch command
        if echo "$context" | grep -qE "^\s*(Bash|Write|Edit|Read|Fetch)"; then
            details=$(echo "$context" | grep -E "^\s*(Bash|Write|Edit|Read|Fetch)" | head -1 | sed 's/^[[:space:]]*//')
        elif echo "$context" | grep -qE "echo|rm |cat |mkdir|chmod|curl|wget|git "; then
            # Raw command line
            details=$(echo "$context" | grep -E "echo|rm |cat |mkdir|chmod|curl|wget|git " | head -1 | sed 's/^[[:space:]]*//')
        else
            # Just use the first non-empty content line
            details=$(echo "$context" | head -3 | tr '\n' ' ' | sed 's/^[[:space:]]*//')
        fi
    fi

    # Fallback: find the last tool call that appears AFTER any "Done." line
    if [ -z "$details" ]; then
        # Fallback: find the last tool call that appears AFTER any "Done." line
        # This ensures we get the pending one, not a completed one
        local last_done_line
        last_done_line=$(echo "$output" | grep -n "^⏺ Done" | tail -1 | cut -d: -f1)

        if [ -n "$last_done_line" ]; then
            # Get output after the last "Done." line
            local pending_output
            pending_output=$(echo "$output" | tail -n +$((last_done_line + 1)))
        else
            pending_output="$output"
        fi

        # Now look for tool calls in the pending section
        if echo "$pending_output" | grep -q "Bash("; then
            details=$(echo "$pending_output" | grep -o "Bash([^)]*)" | head -1)
        elif echo "$pending_output" | grep -q "Write("; then
            details=$(echo "$pending_output" | grep -o "Write([^)]*)" | head -1)
        elif echo "$pending_output" | grep -q "Edit("; then
            details=$(echo "$pending_output" | grep -o "Edit([^)]*)" | head -1)
        elif echo "$pending_output" | grep -q "Read("; then
            details=$(echo "$pending_output" | grep -o "Read([^)]*)" | head -1)
        elif echo "$pending_output" | grep -q "Fetch("; then
            details=$(echo "$pending_output" | grep -o "Fetch([^)]*)" | head -1)
        elif echo "$pending_output" | grep -q "WebFetch("; then
            details=$(echo "$pending_output" | grep -o "WebFetch([^)]*)" | head -1)
        fi

        # For Fetch, also try to extract the URL from nearby lines
        if [ -z "$details" ] || echo "$details" | grep -q "^Fetch()$"; then
            local url_line
            url_line=$(echo "$pending_output" | grep -E "https?://" | head -1)
            if [ -n "$url_line" ]; then
                details="Fetch: $url_line"
            fi
        fi
    fi

    if [ -z "$details" ]; then
        details="Tool execution approval needed"
    fi

    if [ ${#details} -gt 300 ]; then
        details="${details:0:300}..."
    fi

    echo "$details"
}

# Check if session needs approval
check_session_approval() {
    local session="$1"

    if [ -x "$LIB_DIR/session-status.sh" ]; then
        local status
        status=$("$LIB_DIR/session-status.sh" "$session" --json 2>/dev/null) || return 1
        local session_status
        session_status=$(echo "$status" | jq -r '.status' 2>/dev/null)
        if [ "$session_status" = "waiting_approval" ]; then
            return 0
        fi
        return 1
    fi

    local output
    output=$(tmux capture-pane -t "$session" -p 2>/dev/null) || return 1
    if echo "$output" | grep -qE "Do you want|Allow this|y/n/always"; then
        return 0
    fi
    return 1
}

# Get list of tmux sessions
get_sessions() {
    tmux list-sessions -F "#{session_name}" 2>/dev/null || echo ""
}

# Main monitoring loop
log "INFO" "Starting master monitor daemon"
log "INFO" "Poll interval: ${POLL_INTERVAL}s"
log "INFO" "Reminder interval: ${REMINDER_INTERVAL}s"
log "INFO" "PID: $$"
log "INFO" "Log file: $LOG_FILE"

WAITING_SESSIONS_FILE="$STATE_DIR/waiting-sessions.tmp"

while true; do
    CURRENT_TIME=$(date +%s)
    SESSIONS=$(get_sessions)

    if [ -z "$SESSIONS" ]; then
        sleep "$POLL_INTERVAL"
        continue
    fi

    : > "$WAITING_SESSIONS_FILE"

    while IFS= read -r session; do
        [ -z "$session" ] && continue

        if check_session_approval "$session"; then
            echo "$session" >> "$WAITING_SESSIONS_FILE"

            DETAILS=$(extract_approval_details "$session")
            PROMPT_HASH=$(hash_prompt "$DETAILS")

            STATE=$(get_notify_state "$session")
            LAST_NOTIFIED=$(echo "$STATE" | cut -d'|' -f1)
            REMINDER_COUNT=$(echo "$STATE" | cut -d'|' -f2)
            LAST_HASH=$(echo "$STATE" | cut -d'|' -f3)

            TIME_SINCE_NOTIFY=$((CURRENT_TIME - LAST_NOTIFIED))

            SHOULD_NOTIFY=false
            NEW_REMINDER_COUNT=0

            if [ "$PROMPT_HASH" != "$LAST_HASH" ]; then
                SHOULD_NOTIFY=true
                NEW_REMINDER_COUNT=0
            elif [ "$TIME_SINCE_NOTIFY" -ge "$REMINDER_INTERVAL" ]; then
                SHOULD_NOTIFY=true
                NEW_REMINDER_COUNT=$((REMINDER_COUNT + 1))
            fi

            if [ "$SHOULD_NOTIFY" = true ]; then
                if send_notification "$session" "$DETAILS" "$NEW_REMINDER_COUNT"; then
                    set_notify_state "$session" "$CURRENT_TIME" "$NEW_REMINDER_COUNT" "$PROMPT_HASH"
                fi
            fi
        fi
    done <<< "$SESSIONS"

    # Clean up state for sessions no longer waiting
    if ls "$NOTIFY_STATE_DIR"/*.state >/dev/null 2>&1; then
        for state_file in "$NOTIFY_STATE_DIR"/*.state; do
            [ -f "$state_file" ] || continue
            session=$(basename "$state_file" .state)
            if ! grep -q "^${session}$" "$WAITING_SESSIONS_FILE" 2>/dev/null; then
                log "INFO" "Session '$session' no longer waiting for approval"
                clear_notify_state "$session"
            fi
        done
    fi

    sleep "$POLL_INTERVAL"
done
