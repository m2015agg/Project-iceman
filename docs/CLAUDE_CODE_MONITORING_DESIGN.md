# Claude Code Monitoring Design

**Date:** 2026-02-03  
**Author:** Lizi (OpenClaw Assistant)  
**Status:** Draft - Design Options Review

## Problem Statement

When running Claude Code sessions from OpenClaw (via Discord, Telegram, WhatsApp, etc.), we need automatic notifications when Claude Code asks for approval ("Do you want to make this edit?"). The challenge is routing those notifications back to the correct channel that initiated the session.

### Core Requirements

1. **Automatic monitoring** - No manual checking required
2. **Correct channel routing** - Notifications go to the channel that started the session
3. **Multi-session support** - Handle multiple Claude Code sessions from different channels simultaneously
4. **Approval handling** - Process approval commands from chat ("approve session-name")
5. **Reliability** - Don't miss approval prompts or exit early

### Key Constraint

**Multiple channels, different every time** - Sessions are started from various Discord channels, Telegram chats, WhatsApp numbers. Each session needs notifications routed to its origin channel.

---

## Architecture Context

### How OpenClaw Sessions Work

- Each conversation has a session key: `agent:main:discord:channel:1466888482793459813`
- OpenClaw tracks which channel each session belongs to
- Tools like `sessions_send` automatically route to the correct channel based on session context

### How Claude Code Sessions Work

- Terminal CLI application (no built-in channel awareness)
- Runs in tmux sessions for persistence
- Has native webhook hooks (`.claude/settings.json`) that fire on events
- Hooks are static configuration files loaded at startup

### The Routing Problem

**Scenario:**
1. User messages from Discord channel A: "Start implementing feature X"
2. Lizi starts tmux session `claude-feature-x` 
3. Claude Code runs, needs approval
4. **Where should the notification go?**

**Challenge:** Claude Code doesn't know about Discord/Telegram/WhatsApp channels. It only knows:
- Its working directory
- Environment variables at launch
- Static hook configuration from `.claude/settings.json`

---

## Option 1: Pre-Configure Hooks Per Session

**Approach:** Write session-specific webhook config before starting Claude Code

### Implementation

```javascript
// 1. Get current channel context
const currentChannel = "discord:channel:1466888482793459813";

// 2. Write .claude/settings.local.json in project directory
const hookConfig = {
  "hooks": {
    "Notification": [{
      "matcher": "permission_prompt",
      "hooks": [{
        "type": "command",
        "command": `curl -X POST http://127.0.0.1:18789/hooks/agent \\
          -H 'Authorization: Bearer ${webhookToken}' \\
          -H 'Content-Type: application/json' \\
          -d '{"message":"Claude Code needs approval","deliver":true,"channel":"discord","to":"${currentChannel}"}'`
      }]
    }]
  }
};

// 3. Write config file
fs.writeFileSync('/path/to/project/.claude/settings.local.json', 
                 JSON.stringify(hookConfig, null, 2));

// 4. Start Claude Code (loads config on startup)
tmux.sendKeys("claude");
```

### Flow

```
User (Discord #feature-dev) → Lizi → Write hook config with channel #feature-dev
                                  ↓
                            Start Claude Code
                                  ↓
                      Claude loads hook config at startup
                                  ↓
              Claude asks for approval (Notification event fires)
                                  ↓
                  Hook POSTs to OpenClaw webhook with channel info
                                  ↓
              OpenClaw delivers to Discord #feature-dev
```

### Pros

✅ Uses Claude Code's native webhook system (reliable, deterministic)  
✅ Channel routing is baked into config before startup  
✅ No external monitoring daemon needed  
✅ Works for multiple simultaneous sessions (each has own config)  
✅ Survives Claude Code restarts (config persists)

### Cons

❌ Requires webhook token (`hooks.token` in OpenClaw config)  
❌ Config must be written BEFORE starting Claude Code (can't change mid-session)  
❌ Needs cleanup (delete `.claude/settings.local.json` after session ends)  
❌ curl command in hook config is verbose/complex

### Risk Assessment

**Low risk** - Claude Code's hook system is stable and documented. Config files are project-local (`.gitignore`d).

---

## Option 2: Environment Variable + Static Hook

**Approach:** Pass channel context via environment variable, reference in static hook config

### Implementation

```bash
# 1. Global hook config in ~/.claude/settings.json (one-time setup)
{
  "hooks": {
    "Notification": [{
      "matcher": "permission_prompt",
      "hooks": [{
        "type": "command",
        "command": "curl -X POST http://127.0.0.1:18789/hooks/agent -H 'Authorization: Bearer $OPENCLAW_WEBHOOK_TOKEN' -d '{\"to\":\"'$OPENCLAW_REPLY_CHANNEL'\"}'"
      }]
    }]
  }
}

# 2. When starting Claude Code, set env vars
OPENCLAW_REPLY_CHANNEL="discord:channel:1466888482793459813" \
OPENCLAW_WEBHOOK_TOKEN="abc123..." \
tmux new-session -d -s session-name "claude"
```

### Flow

```
User (Telegram chat 5678) → Lizi → Export OPENCLAW_REPLY_CHANNEL=telegram:chat:5678
                                ↓
                          Start Claude Code (inherits env vars)
                                ↓
                  Claude loads global hook config
                                ↓
        Hook fires → reads $OPENCLAW_REPLY_CHANNEL from environment
                                ↓
              POSTs to OpenClaw with correct channel
```

### Pros

✅ Global hook config (one-time setup)  
✅ Dynamic channel routing via env vars  
✅ Cleaner than per-session config files  
✅ No cleanup needed (env vars die with tmux session)

### Cons

❌ Env var must be exported in tmux session (extra step)  
❌ Claude Code must inherit environment correctly  
❌ Still needs webhook token setup  
❌ Less explicit than per-session config (harder to debug)

### Risk Assessment

**Medium risk** - Env var inheritance in tmux can be tricky. Harder to verify what channel is configured.

---

## Option 3: Session Registry File

**Approach:** Maintain a registry mapping session names to channels

### Implementation

```bash
# Registry file: /tmp/claude-sessions.registry
# Format: session-name:channel-target

# When starting session:
echo "claude-feature-x:discord:channel:1466888482793459813" >> /tmp/claude-sessions.registry

# Hook script reads registry:
#!/bin/bash
SESSION_NAME=$(tmux display-message -p '#{session_name}')
CHANNEL=$(grep "^${SESSION_NAME}:" /tmp/claude-sessions.registry | cut -d: -f2-)
curl ... -d "{\"to\":\"$CHANNEL\"}"

# Cleanup when session ends:
sed -i "/^${SESSION_NAME}:/d" /tmp/claude-sessions.registry
```

### Flow

```
User (WhatsApp) → Lizi → Add "session-abc:whatsapp:+1234567890" to registry
                      ↓
                Start Claude Code
                      ↓
        Hook fires → reads tmux session name → looks up channel in registry
                      ↓
              POSTs to OpenClaw with correct channel
```

### Pros

✅ Decoupled from Claude Code config (hook script is generic)  
✅ Easy to debug (cat /tmp/claude-sessions.registry)  
✅ Can update channel mid-session (edit registry file)  
✅ Works across all Claude Code sessions automatically

### Cons

❌ Registry file management (create, update, cleanup)  
❌ Race conditions if multiple sessions start simultaneously  
❌ Hook script more complex (bash parsing logic)  
❌ Registry survives crashes (needs periodic cleanup)

### Risk Assessment

**Medium-high risk** - File-based registry is fragile. Race conditions, cleanup issues, parsing errors.

---

## Option 4: Subagent Pre-Configuration

**Approach:** Spawn subagent to write config, then start Claude Code

### Implementation

```javascript
sessions_spawn({
  task: `Configure Claude Code webhook for this channel.
  
  1. Get parent session channel context
  2. Write .claude/settings.local.json with webhook config pointing to this channel
  3. Report completion
  
  Parent session: ${currentSessionKey}
  Channel: discord:channel:1466888482793459813`,
  
  label: "configure-claude-webhook"
});

// Wait for subagent completion
// Then start Claude Code
```

### Flow

```
User → Lizi → Spawn subagent to write config
           ↓
    Subagent writes .claude/settings.local.json with correct channel
           ↓
    Subagent exits (announces completion)
           ↓
    Lizi starts Claude Code
           ↓
    Claude loads config → hooks notify correct channel
```

### Pros

✅ Leverages OpenClaw's subagent session routing  
✅ Config writing is automated  
✅ Subagent inherits channel context automatically  
✅ Clean separation of concerns

### Cons

❌ Extra step before starting Claude Code (adds latency)  
❌ Subagent overhead for simple config write  
❌ Still needs webhook token setup  
❌ Overkill for a simple file write

### Risk Assessment

**Low-medium risk** - Reliable but over-engineered. Subagent is unnecessary complexity.

---

## Option 5: External Monitor Daemon (Wingman Approach)

**Approach:** Run external bash daemon that polls all tmux sessions

### Implementation

```bash
# Master monitor daemon (runs continuously)
while true; do
  for session in $(tmux list-sessions -F '#{session_name}'); do
    # Capture tmux output
    OUTPUT=$(tmux capture-pane -p -t "$session")
    
    # Check for approval prompt
    if echo "$OUTPUT" | grep -q "Do you want"; then
      # Look up channel for this session
      CHANNEL=$(get_channel_for_session "$session")
      
      # POST to OpenClaw webhook
      curl -X POST http://127.0.0.1:18789/hooks/agent \
        -H "Authorization: Bearer $TOKEN" \
        -d "{\"to\":\"$CHANNEL\",\"message\":\"Session $session needs approval\"}"
    fi
  done
  
  sleep 10
done
```

### Flow

```
User → Lizi → Start Claude Code in tmux
           ↓
    Monitor daemon (running separately) → polls tmux sessions every 10s
           ↓
    Detects "Do you want" prompt → looks up session channel
           ↓
    POSTs to OpenClaw webhook
```

### Pros

✅ Independent of Claude Code (works with any version)  
✅ Monitors ALL tmux sessions automatically  
✅ Can handle approval commands (send tmux keystrokes)  
✅ Battle-tested (wingman repo exists)

### Cons

❌ External process to manage (start/stop/restart)  
❌ Polling overhead (CPU, tmux command spam)  
❌ Still needs session→channel registry/mapping  
❌ Race conditions (approval prompt appears/disappears between polls)  
❌ Not using Claude Code's native capabilities

### Risk Assessment

**Medium risk** - Polling is inherently racy. Daemon management adds operational complexity.

---

## Option 6: Single Control Channel (Accept the Limitation)

**Approach:** ALL Claude Code notifications go to one designated "control center" channel

### Implementation

```json
// Global hook config in ~/.claude/settings.json
{
  "hooks": {
    "Notification": [{
      "matcher": "permission_prompt",
      "hooks": [{
        "type": "command",
        "command": "curl ... -d '{\"to\":\"discord:channel:1466888482793459813\"}'"
      }]
    }]
  }
}
```

### Flow

```
User A (Discord #feature-1) → Lizi → Start Claude Code session-A
User B (Telegram chat 5678) → Lizi → Start Claude Code session-B
                                  ↓
        Both sessions → notify Discord #control-center
                                  ↓
          User A/B checks control center for notifications
```

### Pros

✅ Dead simple (static config, no dynamic routing)  
✅ Single place to monitor all Claude Code activity  
✅ No channel context needed  
✅ Works with existing wingman code

### Cons

❌ Notifications go to wrong channel (not where session started)  
❌ User must watch control center, not their active channel  
❌ Doesn't scale (control center gets spammed with multiple sessions)  
❌ Poor UX (context switching between channels)

### Risk Assessment

**Low risk technically, high UX friction** - Works but annoying to use.

---

## Recommended Approach

### **Primary Recommendation: Option 1 (Pre-Configure Hooks Per Session)**

**Rationale:**
- Uses Claude Code's native, reliable webhook system
- Deterministic (config is explicit, written before startup)
- No external daemons or polling
- Clean per-session isolation
- Easy to debug (read `.claude/settings.local.json` to see config)

**Implementation Steps:**

1. **One-time setup:** Configure `hooks.token` in OpenClaw config
2. **Per session:** Before starting Claude Code:
   - Get current channel context from session
   - Write `.claude/settings.local.json` with webhook config
   - Start Claude Code (loads config on startup)
3. **On session end:** Delete `.claude/settings.local.json` (cleanup)

**Example Code:**

```javascript
// Helper function
function writeClaudeWebhookConfig(projectDir, channelTarget, webhookToken) {
  const configPath = path.join(projectDir, '.claude', 'settings.local.json');
  
  const config = {
    hooks: {
      Notification: [{
        matcher: "permission_prompt",
        hooks: [{
          type: "command",
          command: `curl -s -X POST http://127.0.0.1:18789/hooks/agent \\
            -H 'Authorization: Bearer ${webhookToken}' \\
            -H 'Content-Type: application/json' \\
            -d '{"message":"🔒 Claude Code needs approval","deliver":true,"to":"${channelTarget}"}'`
        }]
      }]
    }
  };
  
  fs.mkdirSync(path.dirname(configPath), { recursive: true });
  fs.writeFileSync(configPath, JSON.stringify(config, null, 2));
}

// Usage in /implement skill
const currentChannel = getCurrentChannelFromSession(); // e.g., "discord:channel:123"
const webhookToken = getWebhookTokenFromConfig(); // from ~/.openclaw/openclaw.json

writeClaudeWebhookConfig('/home/matt/bibleai', currentChannel, webhookToken);

// Now start Claude Code
exec({ command: "claude", workdir: "/home/matt/bibleai", pty: true, background: true });
```

### **Fallback: Option 2 (Environment Variable)**

If per-session config files are problematic (e.g., Claude Code doesn't reload properly), use env vars:

```bash
OPENCLAW_REPLY_TO="discord:channel:123" \
OPENCLAW_WEBHOOK_TOKEN="abc..." \
tmux new-session -d -s session "claude"
```

Static global hook config references these env vars.

---

## Security Considerations

### Webhook Token Exposure

**Risk:** Webhook token appears in:
- `.claude/settings.local.json` (file on disk)
- Hook command string (visible in process list)
- curl POST body (network traffic)

**Mitigations:**
1. ✅ Use `settings.local.json` (git-ignored by default)
2. ✅ File permissions: `chmod 600 .claude/settings.local.json`
3. ✅ Cleanup on session end (delete config file)
4. ✅ Localhost-only webhook endpoint (127.0.0.1, not exposed)
5. ⚠️ Process list leak: unavoidable (curl command visible in `ps aux`)

**Recommendation:** Acceptable risk for local development. For production, use option 2 (env vars) to avoid token in config files.

### Command Injection

**Risk:** Channel target comes from user input → could inject shell commands

**Example attack:**
```javascript
channelTarget = "discord:channel:123; rm -rf ~"
// Results in: -d '{"to":"discord:channel:123; rm -rf ~"}'
```

**Mitigations:**
1. ✅ Validate channel format: `discord:channel:\d+|telegram:chat:\d+|whatsapp:\+\d+`
2. ✅ Use JSON encoding in curl command (prevents injection)
3. ✅ Whitelist allowed channel prefixes

**Recommendation:** Input validation is critical. Don't trust channel context without validation.

---

## Open Questions

1. **Webhook token management:** Where is `hooks.token` stored? Is it set up?
2. **Config cleanup:** Should we delete `.claude/settings.local.json` on session end or let it persist?
3. **Multi-project setup:** If multiple projects share `~/.claude/settings.json`, does per-project `.claude/settings.local.json` override correctly?
4. **Hook reload:** Does Claude Code auto-reload config changes, or only on startup?
5. **Approval handling:** Should we also configure hooks to handle approval commands from chat, or just notify?

---

## Next Steps

1. **Validate webhook token exists:** Check if `hooks.token` is configured in OpenClaw
2. **Test hook config:** Manually write `.claude/settings.local.json` and verify Claude Code loads it
3. **Implement helper function:** Create `writeClaudeWebhookConfig()` utility
4. **Update /implement skill:** Integrate webhook config writing before starting Claude Code
5. **Test multi-channel:** Start sessions from different Discord channels, verify routing
6. **Document cleanup:** Add session-end cleanup to delete `.claude/settings.local.json`

---

## References

- [Claude Code Hooks Documentation](https://code.claude.com/docs/en/hooks-guide)
- [OpenClaw Webhook System](https://docs.openclaw.ai/automation/webhook)
- [Wingman Monitor Daemon](https://github.com/yossiovadia/claude-code-orchestrator)
- [OpenClaw Session Management](https://docs.openclaw.ai/reference/session-management-compaction)

---

**Status:** Awaiting decision on recommended approach (Option 1) and answers to open questions.
