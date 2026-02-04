#!/bin/bash
# register-session-channel.sh - Register a Claude Code session with its source channel
# Usage: register-session-channel.sh <session-name> <channel-target>
#
# Example:
#   register-session-channel.sh claude-1234567 "discord:channel:1466888482793459813"

set -e

SESSION="${1:-}"
CHANNEL="${2:-}"

if [ -z "$SESSION" ] || [ -z "$CHANNEL" ]; then
    echo "Usage: $0 <session-name> <channel-target>" >&2
    echo "" >&2
    echo "Example:" >&2
    echo "  $0 claude-1234567 'discord:channel:1466888482793459813'" >&2
    exit 1
fi

# Validate channel format
if [[ ! "$CHANNEL" =~ ^(discord|telegram|whatsapp):(channel|chat|user):.+ ]]; then
    echo "Error: Invalid channel format: $CHANNEL" >&2
    echo "Expected format: service:type:id" >&2
    echo "Examples:" >&2
    echo "  discord:channel:1466888482793459813" >&2
    echo "  telegram:chat:987654321" >&2
    echo "  whatsapp:user:+1234567890" >&2
    exit 1
fi

# Find state directory
STATE_DIR="${CLAUDE_MONITOR_STATE_DIR:-/tmp/claude-orchestrator}"
CHANNEL_REGISTRY="$STATE_DIR/channel-registry.json"

# Create state dir if needed
mkdir -p "$STATE_DIR"
chmod 700 "$STATE_DIR"

# Update registry
TEMP_FILE=$(mktemp)
if [ -f "$CHANNEL_REGISTRY" ]; then
    jq --arg sess "$SESSION" --arg chan "$CHANNEL" '.[$sess] = $chan' "$CHANNEL_REGISTRY" > "$TEMP_FILE"
else
    echo "{\"$SESSION\": \"$CHANNEL\"}" | jq '.' > "$TEMP_FILE"
fi

mv "$TEMP_FILE" "$CHANNEL_REGISTRY"
chmod 600 "$CHANNEL_REGISTRY"

echo "✓ Registered session '$SESSION' → channel '$CHANNEL'"
