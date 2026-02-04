#!/bin/bash
# send-notification.sh - Send notification via Clawdbot webhook (WhatsApp or Telegram)
# Usage: send-notification.sh "Your message here"
#
# Environment variables:
#   CLAWDBOT_CHANNEL        - "telegram" or "whatsapp" (default: auto-detect)
#   CLAWDBOT_PHONE          - WhatsApp phone number
#   CLAWDBOT_TELEGRAM_ID    - Telegram chat ID

set -e

MESSAGE="${1:-}"
CLAWDBOT_CONFIG="${CLAWDBOT_CONFIG:-$HOME/.openclaw/openclaw.json}"
WEBHOOK_URL="${CLAWDBOT_WEBHOOK_URL:-http://127.0.0.1:18789/hooks/agent}"

# Check for direct channel override (from registry)
if [ -n "$OPENCLAW_REPLY_TO" ]; then
    # Format: "discord:channel:123456789" or "telegram:chat:987654"
    # Extract channel type and target
    if [[ "$OPENCLAW_REPLY_TO" =~ ^([^:]+):([^:]+):(.+)$ ]]; then
        CHANNEL="${BASH_REMATCH[1]}"
        TO="${BASH_REMATCH[2]}:${BASH_REMATCH[3]}"
    else
        echo "Error: Invalid OPENCLAW_REPLY_TO format: $OPENCLAW_REPLY_TO" >&2
        echo "Expected format: channel:type:id (e.g., discord:channel:123)" >&2
        exit 1
    fi
else
    # Determine channel (telegram or whatsapp) from config
    CHANNEL="${CLAWDBOT_CHANNEL:-}"
fi

# Only do auto-detection if OPENCLAW_REPLY_TO wasn't set
if [ -z "$OPENCLAW_REPLY_TO" ]; then

# Auto-detect channel from config if not set
if [ -z "$CHANNEL" ] && [ -f "$CLAWDBOT_CONFIG" ]; then
    # Check if telegram is configured
    if jq -e '.channels.telegram' "$CLAWDBOT_CONFIG" >/dev/null 2>&1; then
        CHANNEL="telegram"
    elif jq -e '.channels.whatsapp' "$CLAWDBOT_CONFIG" >/dev/null 2>&1; then
        CHANNEL="whatsapp"
    fi
fi

# Default to telegram if still not set
CHANNEL="${CHANNEL:-telegram}"

# Get recipient based on channel
if [ "$CHANNEL" = "telegram" ]; then
    if [ -n "$CLAWDBOT_TELEGRAM_ID" ]; then
        TO="$CLAWDBOT_TELEGRAM_ID"
    elif [ -f "$CLAWDBOT_CONFIG" ]; then
        # Try to get from telegram allowFrom
        TO=$(jq -r '.channels.telegram.allowFrom[0] // empty' "$CLAWDBOT_CONFIG" 2>/dev/null)
        # If that's empty, try allowedUserIds
        if [ -z "$TO" ]; then
            TO=$(jq -r '.channels.telegram.allowedUserIds[0] // empty' "$CLAWDBOT_CONFIG" 2>/dev/null)
        fi
    fi

    if [ -z "$TO" ]; then
        echo "Error: No Telegram ID found. Set CLAWDBOT_TELEGRAM_ID or configure telegram in clawdbot.json" >&2
        exit 1
    fi
else
    # WhatsApp
    if [ -n "$CLAWDBOT_PHONE" ]; then
        TO="$CLAWDBOT_PHONE"
    elif [ -f "$CLAWDBOT_CONFIG" ]; then
        TO=$(jq -r '.channels.whatsapp.allowFrom[0] // empty' "$CLAWDBOT_CONFIG" 2>/dev/null)
    fi

    if [ -z "$TO" ]; then
        echo "Error: No phone number found. Set CLAWDBOT_PHONE or configure whatsapp in clawdbot.json" >&2
        exit 1
    fi
fi
fi  # End of OPENCLAW_REPLY_TO check

# Get webhook token from env or clawdbot config
if [ -n "$CLAWDBOT_WEBHOOK_TOKEN" ]; then
    WEBHOOK_TOKEN="$CLAWDBOT_WEBHOOK_TOKEN"
elif [ -f "$CLAWDBOT_CONFIG" ]; then
    WEBHOOK_TOKEN=$(jq -r '.hooks.token // empty' "$CLAWDBOT_CONFIG" 2>/dev/null)
fi

if [ -z "$WEBHOOK_TOKEN" ]; then
    echo "Error: No webhook token found. Set CLAWDBOT_WEBHOOK_TOKEN or configure hooks.token in clawdbot.json" >&2
    exit 1
fi

if [ -z "$MESSAGE" ]; then
    echo "Usage: $0 <message>" >&2
    exit 1
fi

# Escape message for JSON
ESCAPED_MESSAGE=$(echo "$MESSAGE" | jq -Rs .)

echo "Sending notification via $CHANNEL to $TO..." >&2

curl -s -X POST "$WEBHOOK_URL" \
  -H "Authorization: Bearer $WEBHOOK_TOKEN" \
  -H "Content-Type: application/json" \
  -d "{
    \"message\": $ESCAPED_MESSAGE,
    \"name\": \"OrchestratorMonitor\",
    \"deliver\": true,
    \"channel\": \"$CHANNEL\",
    \"to\": \"$TO\"
  }"
