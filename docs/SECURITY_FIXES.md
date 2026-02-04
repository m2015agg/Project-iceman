# Security Fixes Applied

**Date:** 2026-02-04  
**Version:** Post-Audit Hardening

## Summary

This document details the security fixes applied to Project Iceman (Claude Code Wingman) following the comprehensive security audit documented in `SECURITY_AUDIT.md`.

---

## Critical Fixes (CRIT)

### CRIT-01: Command Injection in claude-wingman.sh

**Issue:** User-supplied `$PROMPT` was sent directly to tmux without sanitization, allowing arbitrary command execution.

**Fix:** Added `-l` (literal) flag to `tmux send-keys` to prevent shell interpretation.

**Before:**
```bash
tmux send-keys -t "$SESSION_NAME" "$PROMPT"
```

**After:**
```bash
tmux send-keys -t "$SESSION_NAME" -l -- "$PROMPT"
```

**File:** `claude-wingman.sh` line 168

**Impact:** Prevents shell command injection through prompt parameter.

---

## High-Priority Fixes (HIGH)

### HIGH-02: Insecure Temp File Usage

**Issue:** State directory `/tmp/claude-orchestrator` created without permission checks, vulnerable to symlink attacks.

**Fix:** Added secure directory creation with explicit permission setting.

**Before:**
```bash
STATE_DIR="/tmp/claude-orchestrator"
```

**After:**
```bash
STATE_DIR="${CLAUDE_MONITOR_STATE_DIR:-/tmp/claude-orchestrator}"
if [ ! -d "$STATE_DIR" ]; then
    mkdir -p "$STATE_DIR"
    chmod 700 "$STATE_DIR"
fi
```

**File:** `master-monitor.sh` lines 21-27

**Impact:** Prevents unauthorized access to monitor state files.

---

## New Features

### Multi-Channel Routing Support

**Problem:** Original wingman sent all notifications to a single hardcoded channel, making it unusable for sessions started from different Discord/Telegram/WhatsApp channels.

**Solution:** Implemented channel registry system that maps sessions to their origin channel.

#### Architecture

```
User (Discord #feature-dev) → Lizi → start-claude-session.sh
                                         ↓
                          Register: claude-123 → discord:channel:456
                                         ↓
                                 Start Claude Code in tmux
                                         ↓
                          Monitor daemon detects approval needed
                                         ↓
                          Look up channel: claude-123 → discord:channel:456
                                         ↓
                           POST webhook to discord:channel:456
```

#### Components

**1. Channel Registry** (`/tmp/claude-orchestrator/channel-registry.json`)

Stores session-to-channel mappings:
```json
{
  "claude-1234567": "discord:channel:1466888482793459813",
  "claude-7654321": "telegram:chat:987654321"
}
```

**2. Registration Helper** (`lib/register-session-channel.sh`)

Adds a session to the registry:
```bash
./lib/register-session-channel.sh claude-123 "discord:channel:456"
```

**3. Enhanced Notification** (`lib/send-notification.sh`)

Supports `OPENCLAW_REPLY_TO` environment variable to override channel:
```bash
OPENCLAW_REPLY_TO="discord:channel:456" ./lib/send-notification.sh "message"
```

**4. Integrated Starter** (`start-claude-session.sh`)

All-in-one script that:
- Registers channel
- Starts monitor daemon (if not running)
- Launches Claude Code in tmux
- Sends initial prompt

#### Usage

**From Lizi (Discord/Telegram/WhatsApp):**
```bash
~/Project-iceman/start-claude-session.sh \
  --workdir /home/matt/bibleai \
  --channel "discord:channel:1466888482793459813" \
  --prompt "/implement feature-x"
```

**Manual (from terminal):**
```bash
~/Project-iceman/start-claude-session.sh \
  --workdir ~/myproject \
  --channel "telegram:chat:987654" \
  --session my-task \
  --prompt "Fix the authentication bug"
```

**Channel Format:**
```
service:type:identifier

Examples:
  discord:channel:1466888482793459813
  telegram:chat:987654321
  whatsapp:user:+1234567890
```

---

## Migration Guide

### For Lizi (OpenClaw Integration)

Update `/implement` skill to use new starter script:

```javascript
// Get current channel from session context
const currentChannel = getCurrentChannelFromSession();
// e.g., "discord:channel:1466888482793459813"

// Start Claude Code with channel registration
exec({
  command: `~/Project-iceman/start-claude-session.sh \\
    --workdir ${projectDir} \\
    --channel "${currentChannel}" \\
    --prompt "${task}"`
});
```

### For Manual CLI Usage

Replace old `claude-wingman.sh` calls with `start-claude-session.sh`:

**Before:**
```bash
./claude-wingman.sh \
  --session my-task \
  --workdir ~/project \
  --prompt "Fix bug"
```

**After:**
```bash
./start-claude-session.sh \
  --session my-task \
  --workdir ~/project \
  --channel "discord:channel:YOUR_CHANNEL_ID" \
  --prompt "Fix bug"
```

---

## Configuration

### Webhook Token

Set in OpenClaw config (`~/.openclaw/openclaw.json`):
```json
{
  "hooks": {
    "token": "your-webhook-token-here"
  }
}
```

**Security:** Ensure file permissions are restrictive:
```bash
chmod 600 ~/.openclaw/openclaw.json
```

### Environment Variables

- `CLAUDE_MONITOR_STATE_DIR` - Override state directory (default: `/tmp/claude-orchestrator`)
- `OPENCLAW_REPLY_TO` - Override notification channel (format: `service:type:id`)
- `CLAWDBOT_WEBHOOK_URL` - Override webhook endpoint (default: `http://127.0.0.1:18789/hooks/agent`)

---

## Security Recommendations

### Immediate (Applied)

✅ **Command injection prevention** - Use `-l` flag for literal tmux input  
✅ **Secure temp directories** - Set `chmod 700` on state directories  
✅ **Input validation** - Validate session names and channel formats

### Short-Term (TODO)

🔲 **Redact secrets from notifications** - Filter API keys, tokens before sending  
🔲 **Rate limiting** - Prevent spam/abuse of approval endpoints  
🔲 **Audit logging** - Log all approval actions with timestamps

### Long-Term (TODO)

🔲 **Encrypted credentials** - Move from plaintext to OS keychain  
🔲 **TLS everywhere** - Use HTTPS even for localhost  
🔲 **Sandboxing** - Run monitor daemon with limited privileges

---

## Testing

### Test Channel Registration

```bash
# Register a session
./lib/register-session-channel.sh test-session "discord:channel:123"

# Verify registry
cat /tmp/claude-orchestrator/channel-registry.json
# Should show: {"test-session": "discord:channel:123"}
```

### Test Notification with Channel Override

```bash
# Send test notification
OPENCLAW_REPLY_TO="discord:channel:123" \
  ./lib/send-notification.sh "Test message"
```

### Test Full Flow

```bash
# Start a test session
./start-claude-session.sh \
  --workdir /tmp/test-project \
  --channel "discord:channel:YOUR_CHANNEL_ID" \
  --session test-123

# Monitor should auto-start
cat /tmp/claude-orchestrator/master-monitor.pid

# Registry should have entry
jq '.["test-123"]' /tmp/claude-orchestrator/channel-registry.json

# Cleanup
tmux kill-session -t test-123
```

---

## Rollback

If issues occur, revert to pre-fix version:

```bash
cd /home/matt/Project-iceman
git log --oneline  # Find commit before fixes
git checkout <commit-hash>
```

---

## Files Modified

- `claude-wingman.sh` - Added `-l` flag for tmux send-keys
- `master-monitor.sh` - Added secure temp dir creation, channel registry functions
- `lib/send-notification.sh` - Added `OPENCLAW_REPLY_TO` support

## Files Added

- `lib/register-session-channel.sh` - Register session→channel mapping
- `start-claude-session.sh` - Integrated session starter with monitoring
- `docs/SECURITY_FIXES.md` - This document

---

## Support

For issues or questions:
- Review: `SECURITY_AUDIT.md` for full vulnerability details
- Review: `docs/CLAUDE_CODE_MONITORING_DESIGN.md` for architecture decisions
- GitHub Issues: https://github.com/m2015agg/Project-iceman/issues

---

**Status:** Security fixes applied and tested. Ready for integration with Lizi.
