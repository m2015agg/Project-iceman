# Wingman Dashboard (Secured)

Real-time web dashboard for monitoring Claude Code sessions with authentication.

## Security

**Authentication is REQUIRED** - The dashboard now requires a token to access.

### Token Configuration

**Option 1: Use OpenClaw hooks token (recommended)**

The dashboard automatically reads `hooks.token` from `~/.openclaw/openclaw.json`:

```json
{
  "hooks": {
    "token": "your-secure-token-here"
  }
}
```

**Option 2: Environment variable**

```bash
export DASHBOARD_TOKEN="your-secure-token-here"
node tmux-dashboard.js
```

**Security Note:** If no token is found, dashboard will start with an INSECURE_DEFAULT_TOKEN and log a warning. This is NOT SECURE for production use.

## Running the Dashboard

### Install Dependencies

```bash
cd /home/matt/Project-iceman/dashboard
npm install
```

### Start the Server

```bash
node tmux-dashboard.js
```

Server starts on port 3333 (configurable via `PORT` environment variable).

### Access the Dashboard

**Local access:**
```
http://localhost:3333/?token=YOUR_TOKEN_HERE
```

**Via Cloudflare Tunnel (recommended):**
```
https://your-nebo-url.example.com/?token=YOUR_TOKEN_HERE
```

**Example:**
```bash
# Get your token
TOKEN=$(jq -r '.hooks.token' ~/.openclaw/openclaw.json)

# Open in browser
open "http://localhost:3333/?token=$TOKEN"
```

## Cloudflare Tunnel Setup

Cloudflare Tunnel provides an additional layer of authentication and encryption.

### 1. Create Tunnel

```bash
cloudflared tunnel create wingman-dashboard
```

### 2. Configure Tunnel

Add to your Cloudflare Tunnel config:

```yaml
tunnel: <tunnel-id>
credentials-file: /path/to/credentials.json

ingress:
  - hostname: wingman.your-domain.com
    service: http://localhost:3333
    originRequest:
      noTLSVerify: false
  - service: http_status:404
```

### 3. Start Tunnel

```bash
cloudflared tunnel run wingman-dashboard
```

### 4. Add Cloudflare Access (Optional but Recommended)

Configure Cloudflare Access rules:
- Application type: Self-hosted
- Session duration: 24 hours
- Authentication: Email OTP, Google Workspace, etc.

This adds another authentication layer BEFORE the dashboard's token auth.

## Features

- **Real-time session monitoring** - See all Claude Code sessions
- **Live terminal output** - ANSI-colored terminal display
- **Quick approval actions** - Approve/Always/Deny buttons
- **Session status** - Working, Waiting, Idle indicators
- **Auto-refresh** - Updates every 500ms

## API Endpoints

### GET /

Serves the dashboard HTML (requires authentication).

**Headers:**
- `x-dashboard-token: YOUR_TOKEN`

**Query:**
- `?token=YOUR_TOKEN`

### WebSocket (Socket.IO)

**Authentication:**
```javascript
const socket = io({
  auth: { token: 'YOUR_TOKEN' },
  query: { token: 'YOUR_TOKEN' }
});
```

**Events:**
- `session:add` - New session detected
- `session:update` - Session content updated
- `session:remove` - Session ended
- `session:approve` - Quick approval action
- `approval:result` - Approval result feedback

## Security Best Practices

1. **Use strong tokens** - Generate with `openssl rand -hex 32`
2. **Keep tokens secret** - Don't commit to git, use environment variables
3. **Use Cloudflare Tunnel** - Never expose port 3333 directly to internet
4. **Enable Cloudflare Access** - Add email/SSO authentication
5. **Restrict access** - Use firewall rules to limit local network access
6. **Rotate tokens** - Change tokens periodically
7. **Monitor logs** - Check for unauthorized access attempts

## Troubleshooting

### "Authentication Required" error

- Check token is included in URL: `?token=YOUR_TOKEN`
- Verify token matches the configured token
- Check browser console for errors

### "Invalid token" error

- Token mismatch - verify you're using the correct token
- Check `~/.openclaw/openclaw.json` for `hooks.token` value
- Or check `DASHBOARD_TOKEN` environment variable

### Dashboard not loading

- Verify server is running: `curl http://localhost:3333`
- Check firewall rules
- Verify port 3333 is not in use: `lsof -i :3333`

### Authentication bypassed

**This should NOT happen** - if you can access without a token:
1. Check server logs for security warnings
2. Verify authentication middleware is active
3. Report as a security issue

## Development

### Test Authentication

```bash
# Should fail (no token)
curl http://localhost:3333/

# Should succeed (with token)
TOKEN=$(jq -r '.hooks.token' ~/.openclaw/openclaw.json)
curl -H "x-dashboard-token: $TOKEN" http://localhost:3333/
```

### Debug Mode

```bash
DEBUG=* node tmux-dashboard.js
```

## Migration from Insecure Version

If you previously ran the dashboard without authentication:

1. **Update code** - Pull latest changes with auth middleware
2. **Configure token** - Set `hooks.token` in OpenClaw config
3. **Restart dashboard** - Kill old process, start new one
4. **Update bookmarks** - Add `?token=...` to URLs
5. **Update automation** - Add authentication headers to API calls

## Related

- **Monitor daemon:** `../master-monitor.sh` - Polls sessions, sends Discord notifications
- **Session handlers:** `../lib/` - Approval handlers, status checkers
- **Documentation:** `../docs/SECURITY_FIXES.md` - Security audit and fixes

---

**Status:** Secured ✅ (CRIT-02 vulnerability fixed)
