const express = require('express');
const http = require('http');
const { Server } = require('socket.io');
const { execSync } = require('child_process');
const path = require('path');

const app = express();
const server = http.createServer(app);
const io = new Server(server, {
  cors: { origin: '*' }
});

const PORT = process.env.PORT || 3333;
const POLL_INTERVAL = 500; // Poll every 500ms for smooth updates
const DASHBOARD_TOKEN = process.env.DASHBOARD_TOKEN || readDashboardToken();

// Read dashboard token from OpenClaw config or generate one
function readDashboardToken() {
  try {
    const fs = require('fs');
    const os = require('os');
    const configPath = path.join(os.homedir(), '.openclaw', 'openclaw.json');
    if (fs.existsSync(configPath)) {
      const config = JSON.parse(fs.readFileSync(configPath, 'utf-8'));
      if (config.hooks && config.hooks.token) {
        return config.hooks.token;
      }
    }
  } catch (err) {
    console.error('[Dashboard] Could not read token from config:', err.message);
  }
  // Fallback: generate a warning token
  console.warn('[Dashboard] WARNING: No DASHBOARD_TOKEN set and config not found. Using insecure default.');
  console.warn('[Dashboard] Set DASHBOARD_TOKEN environment variable or configure hooks.token in OpenClaw config.');
  return 'INSECURE_DEFAULT_TOKEN';
}

// Authentication middleware
function requireAuth(req, res, next) {
  const token = req.headers['x-dashboard-token'] || req.query.token;
  
  if (!token) {
    return res.status(401).json({ error: 'Authentication required. Provide x-dashboard-token header or ?token= query param.' });
  }
  
  if (token !== DASHBOARD_TOKEN) {
    return res.status(403).json({ error: 'Invalid token' });
  }
  
  next();
}

// Log startup info
console.log('[Dashboard] Starting on port', PORT);
if (DASHBOARD_TOKEN === 'INSECURE_DEFAULT_TOKEN') {
  console.error('[Dashboard] ⚠️  SECURITY WARNING: Using default token. Set DASHBOARD_TOKEN env var!');
} else {
  console.log('[Dashboard] ✓ Authentication enabled (token loaded from config)');
}

// Serve static files (auth required)
app.use(requireAuth);
app.use(express.static(path.join(__dirname, 'public')));

// Track active sessions
let sessions = new Map();

// Get list of wingman sessions (sessions created by wingman have specific patterns)
function getWingmanSessions() {
  try {
    const output = execSync('tmux list-sessions -F "#{session_name}|#{session_created}|#{window_width}|#{window_height}" 2>/dev/null', {
      encoding: 'utf-8',
      timeout: 5000
    });

    return output.trim().split('\n').filter(Boolean).map(line => {
      const [name, created, width, height] = line.split('|');
      return { name, created: parseInt(created), width: parseInt(width), height: parseInt(height) };
    });
  } catch (err) {
    return [];
  }
}

// Capture pane content with ANSI colors
function capturePane(sessionName) {
  try {
    // Capture only visible pane (no history scrollback) to avoid blank space issues
    const output = execSync(`tmux capture-pane -t "${sessionName}" -p -e 2>/dev/null`, {
      encoding: 'utf-8',
      timeout: 5000
    });
    // Trim trailing blank lines
    return output.replace(/[\s\n]+$/, '');
  } catch (err) {
    return '';
  }
}

// Get session status
function getSessionStatus(sessionName) {
  try {
    const output = execSync(`${path.join(__dirname, '../lib/session-status.sh')} "${sessionName}" --json 2>/dev/null`, {
      encoding: 'utf-8',
      timeout: 5000
    });
    return JSON.parse(output);
  } catch (err) {
    return { status: 'unknown', details: '' };
  }
}

// Main polling loop
function pollSessions() {
  const currentSessions = getWingmanSessions();
  const currentNames = new Set(currentSessions.map(s => s.name));
  const previousNames = new Set(sessions.keys());

  // Detect new sessions
  for (const session of currentSessions) {
    if (!sessions.has(session.name)) {
      console.log(`[+] New session: ${session.name}`);
      io.emit('session:add', session);
    }
    sessions.set(session.name, session);
  }

  // Detect removed sessions
  for (const name of previousNames) {
    if (!currentNames.has(name)) {
      console.log(`[-] Session removed: ${name}`);
      sessions.delete(name);
      io.emit('session:remove', { name });
    }
  }

  // Send content updates
  for (const [name, session] of sessions) {
    const content = capturePane(name);
    const status = getSessionStatus(name);
    io.emit('session:update', {
      name,
      content,
      status: status.status,
      details: status.details,
      width: session.width,
      height: session.height
    });
  }
}

// Socket.IO authentication middleware
io.use((socket, next) => {
  const token = socket.handshake.auth.token || socket.handshake.query.token;
  
  if (!token) {
    return next(new Error('Authentication required. Provide token in auth or query.'));
  }
  
  if (token !== DASHBOARD_TOKEN) {
    return next(new Error('Invalid token'));
  }
  
  next();
});

// Socket connection handling
io.on('connection', (socket) => {
  console.log(`[*] Client connected (authenticated): ${socket.id}`);

  // Send current session list
  const currentSessions = getWingmanSessions();
  for (const session of currentSessions) {
    sessions.set(session.name, session);
    const content = capturePane(session.name);
    const status = getSessionStatus(session.name);
    socket.emit('session:add', session);
    socket.emit('session:update', {
      name: session.name,
      content,
      status: status.status,
      details: status.details,
      width: session.width,
      height: session.height
    });
  }

  socket.on('disconnect', () => {
    console.log(`[*] Client disconnected: ${socket.id}`);
  });

  // Handle quick approval actions
  socket.on('session:approve', (data) => {
    const { name, action } = data;
    console.log(`[✓] Approval action for ${name}: ${action}`);
    try {
      const scriptPath = path.join(__dirname, '../lib/handle-approval.sh');
      execSync(`"${scriptPath}" ${action} "${name}"`, { timeout: 5000 });
      socket.emit('approval:result', { name, success: true, action });
    } catch (err) {
      console.error(`[!] Approval failed for ${name}:`, err.message);
      socket.emit('approval:result', { name, success: false, error: err.message });
    }
  });
});

// Start polling
setInterval(pollSessions, POLL_INTERVAL);

// Start server
server.listen(PORT, () => {
  console.log(`
╔══════════════════════════════════════════════════════════════╗
║                                                              ║
║   🚀 WINGMAN COMMAND CENTER                                  ║
║                                                              ║
║   Dashboard: http://localhost:${PORT}                          ║
║   WebSocket: ws://localhost:${PORT}                            ║
║                                                              ║
║   Monitoring tmux sessions in real-time...                   ║
║                                                              ║
╚══════════════════════════════════════════════════════════════╝
`);
});
