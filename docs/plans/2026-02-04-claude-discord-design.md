# Claude Discord - Design Document

**Date:** 2026-02-04
**Status:** Approved
**Project:** claude-discord (MVP)

## Overview

Orchestrate Claude Code sessions from Discord with approval notifications routed back to the originating channel.

### Goals
- Receive Claude Code approval alerts in Discord (multi-channel support)
- Respond via buttons or text (1/2/3, approve/always/deny)
- Proper security (token handling, cleanup)
- Works from both CLI and Lizi skill

### Non-Goals (Future)
- Web dashboard
- Codex/other agent support
- Reminder notifications
- WhatsApp/other channels

---

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                        DISCORD                               │
│  Channel A          Channel B          Channel C            │
│     │                  │                  │                 │
└─────┼──────────────────┼──────────────────┼─────────────────┘
      │                  │                  │
      ▼                  ▼                  ▼
┌─────────────────────────────────────────────────────────────┐
│                         LIZI                                 │
│  • Receives user requests ("fix the bug in api.py")         │
│  • Skill: pattern matches approve/deny commands             │
│  • Skill: spawns Claude Code sessions via CLI wrapper       │
│  • Webhook endpoint receives notifications from hooks       │
└─────────────────────────────────────────────────────────────┘
      │                                          ▲
      │ spawns                                   │ webhook POST
      ▼                                          │
┌─────────────────────────────────────────────────────────────┐
│                    CLI WRAPPER                               │
│  claude-discord.sh                                          │
│  • Writes .claude/settings.local.json (channel baked in)    │
│  • Spawns tmux session                                      │
│  • Launches Claude Code                                     │
│  • Cleanup on session end                                   │
└─────────────────────────────────────────────────────────────┘
      │
      ▼
┌─────────────────────────────────────────────────────────────┐
│                   CLAUDE CODE (in tmux)                      │
│  • Native hooks fire on permission_prompt                   │
│  • Hook calls notification script with channel + session    │
│  • Receives approval via tmux send-keys                     │
└─────────────────────────────────────────────────────────────┘
```

### Data Flow

1. User requests work in Discord channel A
2. Lizi skill calls CLI wrapper with `--channel A`
3. Wrapper writes hook config with channel A baked in, starts Claude Code
4. Claude needs approval → hook POSTs to Lizi webhook with `"to": "A"`
5. Notification appears in channel A with buttons
6. User clicks approve or types `1` → Lizi skill runs `handle-approval.sh`
7. tmux sends keystrokes → Claude continues

---

## Components

### 1. CLI Wrapper (claude-discord.sh)

**Interface:**
```bash
./claude-discord.sh \
  --session <name>        # Session name (required)
  --workdir <path>        # Project directory (required)
  --prompt <text>         # Initial prompt (required)
  --channel <id>          # Discord channel ID (optional)
  --token <token>         # Webhook auth token (optional)
  --cleanup               # Clean up session
```

**Behavior:**

1. Validate inputs (tmux/claude installed, workdir exists)
2. Write hook config if `--channel` provided:
   ```bash
   mkdir -p "$WORKDIR/.claude"
   # Write settings.local.json with channel baked in
   chmod 600 "$WORKDIR/.claude/settings.local.json"
   ```
3. Create tmux session using OpenClaw socket convention:
   ```bash
   SOCKET="$OPENCLAW_TMUX_SOCKET_DIR/openclaw.sock"
   tmux -S "$SOCKET" new-session -d -s "$SESSION" -c "$WORKDIR"
   ```
4. Launch Claude Code + send prompt
5. Output session info for Lizi to parse

### 2. Lizi Skill (claude-discord.skill.md)

**Approval pattern matching:**

| Pattern | Command |
|---------|---------|
| `1` or `approve` or `yes` | `handle-approval.sh approve <last-session>` |
| `2` or `always` | `handle-approval.sh always <last-session>` |
| `3` or `deny` or `no` | `handle-approval.sh deny <last-session>` |
| `approve <session>` | `handle-approval.sh approve <session>` |
| `always <session>` | `handle-approval.sh always <session>` |
| `deny <session>` | `handle-approval.sh deny <session>` |

**Session spawning:**
- Extract project directory and task from user request
- Get current Discord channel ID from Lizi session context
- Call CLI wrapper with `--channel`

**Status commands:**
- `sessions` / `status` - List active sessions
- `status <session>` - Show session output
- `kill <session>` - Kill + cleanup

### 3. Approval Handling (lib/handle-approval.sh)

```bash
#!/bin/bash
set -e

ACTION="$1"
SESSION="$2"
SOCKET="${OPENCLAW_TMUX_SOCKET_DIR:-/tmp/openclaw-tmux-sockets}/openclaw.sock"

# Validate session exists
if ! tmux -S "$SOCKET" has-session -t "$SESSION" 2>/dev/null; then
    echo "❌ Session '$SESSION' not found" >&2
    exit 1
fi

# Send keystrokes based on action
case "$ACTION" in
    approve|yes|y|1)
        tmux -S "$SOCKET" send-keys -t "$SESSION" Enter
        echo "✅ Session '$SESSION' approved (once)"
        ;;
    always|all|2)
        tmux -S "$SOCKET" send-keys -t "$SESSION" Down Enter
        echo "🔄 Session '$SESSION' approved (always)"
        ;;
    deny|no|n|3)
        tmux -S "$SOCKET" send-keys -t "$SESSION" Down Down Enter
        echo "❌ Session '$SESSION' denied"
        ;;
esac
```

### 4. Notification Script (lib/send-discord-notification.sh)

Called by Claude Code hook when approval needed.

```bash
#!/bin/bash
SESSION="$1"
CHANNEL="$2"
TOKEN="${OPENCLAW_WEBHOOK_TOKEN}"
SOCKET="${OPENCLAW_TMUX_SOCKET_DIR:-/tmp/openclaw-tmux-sockets}/openclaw.sock"

# Extract approval details from tmux
OUTPUT=$(tmux -S "$SOCKET" capture-pane -t "$SESSION" -p -S -20 2>/dev/null)
DETAILS=$(echo "$OUTPUT" | grep -E "^\s*(Bash|Write|Edit|Read|WebFetch)" | tail -1)
[ -z "$DETAILS" ] && DETAILS="Tool execution"
[ ${#DETAILS} -gt 200 ] && DETAILS="${DETAILS:0:200}..."

# Format message
MESSAGE="🔒 **$SESSION** needs approval

\`$DETAILS\`

Reply: \`1\` approve · \`2\` always · \`3\` deny"

# POST to webhook
curl -s -X POST "http://127.0.0.1:18789/hooks/agent" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d "$(jq -n \
    --arg msg "$MESSAGE" \
    --arg channel "discord" \
    --arg to "$CHANNEL" \
    '{message: $msg, channel: $channel, to: $to, deliver: true}'
  )"
```

### 5. Hook Configuration

Written by CLI wrapper to `.claude/settings.local.json`:

```json
{
  "hooks": {
    "Notification": [{
      "matcher": "permission_prompt",
      "hooks": [{
        "type": "command",
        "command": "~/claude-discord/lib/send-discord-notification.sh SESSION_NAME CHANNEL_ID"
      }]
    }]
  }
}
```

---

## Project Structure

```
~/claude-discord/
├── claude-discord.sh              # Main CLI wrapper
├── lib/
│   ├── handle-approval.sh         # Process approve/deny commands
│   ├── send-discord-notification.sh  # Format & send notifications
│   ├── session-cleanup.sh         # Kill session + remove config
│   └── session-status.sh          # Get session state
├── skill/
│   └── claude-discord.skill.md    # Lizi skill definition
├── docs/
│   └── plans/
│       └── 2026-02-04-claude-discord-design.md
├── README.md
└── .gitignore
```

---

## Security

| Risk | Mitigation |
|------|------------|
| Token in config file | `chmod 600`, cleanup on session end |
| Token in process list | Acceptable for localhost |
| Command injection via channel ID | Validate: `^[0-9]+$` only |
| Stale configs with tokens | Cleanup script, periodic sweep |
| Unauthorized webhook calls | Bearer token auth required |

**Channel ID validation:**
```bash
if [[ ! "$CHANNEL" =~ ^[0-9]+$ ]]; then
    echo "Error: Invalid channel ID" >&2
    exit 1
fi
```

**Cleanup on session end:**
```bash
rm -f "$WORKDIR/.claude/settings.local.json"
```

---

## Future Enhancements

1. **Dashboard** - Real-time web UI with terminal view
2. **Codex support** - External polling fallback for non-Claude agents
3. **Reminder notifications** - Re-notify if pending > 5 minutes
4. **Session registry** - Central tracking for multi-session status queries
5. **Discord buttons** - Native interactive components instead of text

---

## Implementation Checklist

- [ ] Create project directory structure
- [ ] Implement `claude-discord.sh` CLI wrapper
- [ ] Implement `lib/handle-approval.sh`
- [ ] Implement `lib/send-discord-notification.sh`
- [ ] Implement `lib/session-cleanup.sh`
- [ ] Implement `lib/session-status.sh`
- [ ] Write Lizi skill definition
- [ ] Test single-channel flow
- [ ] Test multi-channel flow
- [ ] Document setup in README.md
