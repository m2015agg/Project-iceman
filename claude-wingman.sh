#!/bin/bash
# Claude Code Wingman - Complete wrapper for automated Claude Code sessions

set -e

# Check dependencies
if ! command -v tmux &> /dev/null; then
    echo "Error: tmux is not installed."
    echo ""
    echo "Install tmux:"
    echo "  macOS:   brew install tmux"
    echo "  Ubuntu:  sudo apt-get install tmux"
    echo "  Fedora:  sudo dnf install tmux"
    echo ""
    exit 1
fi

if ! command -v claude &> /dev/null; then
    echo "Error: Claude Code CLI is not installed."
    echo ""
    echo "Get Claude Code from: https://claude.ai/code"
    echo ""
    exit 1
fi

# Configuration
SESSION_PREFIX="claude-auto"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MASTER_MONITOR="$SCRIPT_DIR/master-monitor.sh"
MONITOR_PID_FILE="/tmp/claude-orchestrator/master-monitor.pid"

# Ensure master-monitor is running (auto-start on first use)
ensure_monitor_running() {
    if [ -f "$MONITOR_PID_FILE" ]; then
        local pid
        pid=$(cat "$MONITOR_PID_FILE")
        if kill -0 "$pid" 2>/dev/null; then
            return 0  # Already running
        fi
    fi

    # Start master-monitor in background
    echo "[Wingman] Starting master monitor daemon..."
    "$MASTER_MONITOR" > /dev/null 2>&1 &
    sleep 1

    if [ -f "$MONITOR_PID_FILE" ]; then
        echo "[Wingman] Master monitor started (PID: $(cat "$MONITOR_PID_FILE"))"
    fi
}

# Usage
usage() {
    echo "Usage: $0 [options]"
    echo ""
    echo "Options:"
    echo "  --session <name>      Session name (default: auto-generated)"
    echo "  --workdir <path>      Working directory (default: current dir)"
    echo "  --prompt <text>       Prompt to send to Claude Code"
    echo "  --monitor             Monitor session in real-time (blocks)"
    echo "  --wait                Wait for completion"
    echo ""
    echo "Examples:"
    echo "  $0 --workdir ~/code/myproject --prompt 'Add error handling to api.py'"
    echo "  $0 --session vsr-123 --prompt 'Fix the bug in line 42' --wait"
    exit 1
}

# Parse arguments
SESSION_NAME=""
WORKDIR="$(pwd)"
PROMPT=""
MONITOR=false
WAIT=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --session)
            SESSION_NAME="$2"
            shift 2
            ;;
        --workdir)
            WORKDIR="$2"
            shift 2
            ;;
        --prompt)
            PROMPT="$2"
            shift 2
            ;;
        --monitor)
            MONITOR=true
            shift
            ;;
        --wait)
            WAIT=true
            shift
            ;;
        -h|--help)
            usage
            ;;
        *)
            echo "Unknown option: $1"
            usage
            ;;
    esac
done

# Validate
if [ -z "$PROMPT" ]; then
    echo "Error: --prompt is required"
    usage
fi

if [ ! -d "$WORKDIR" ]; then
    echo "Error: Working directory does not exist: $WORKDIR"
    exit 1
fi

# Generate session name if not provided
if [ -z "$SESSION_NAME" ]; then
    SESSION_NAME="${SESSION_PREFIX}-$(date +%s)"
fi

# Validate session name (alphanumeric, underscore, hyphen only)
if [[ ! "$SESSION_NAME" =~ ^[a-zA-Z0-9_-]+$ ]]; then
    echo "Error: Invalid session name. Use only alphanumeric characters, underscores, and hyphens."
    exit 1
fi

echo "[Wingman] Starting Claude Code session: $SESSION_NAME"
echo "[Wingman] Working directory: $WORKDIR"
echo "[Wingman] Prompt: $PROMPT"
echo ""

# Clean up any existing session
tmux kill-session -t "$SESSION_NAME" 2>/dev/null || true

# Step 1: Create tmux session
echo "[Wingman] Creating tmux session..."
tmux new-session -d -s "$SESSION_NAME" -c "$WORKDIR"

# Step 2: Ensure master monitor is running for WhatsApp notifications
ensure_monitor_running

# Step 3: Start Claude Code
echo "[Wingman] Launching Claude Code..."
tmux send-keys -t "$SESSION_NAME" "claude" C-m

# Wait for Claude Code to initialize
echo "[Wingman] Waiting for Claude Code to initialize..."
sleep 5

# Check for trust prompt and handle it
echo "[Wingman] Checking for trust prompt..."
for i in {1..5}; do
    OUTPUT=$(tmux capture-pane -t "$SESSION_NAME" -p)
    if echo "$OUTPUT" | grep -q "Do you trust"; then
        echo "[Wingman] Trust prompt detected, approving..."
        tmux send-keys -t "$SESSION_NAME" Enter
        sleep 2
        break
    fi
    sleep 1
done

# Step 4: Send prompt (use -l for literal to prevent command injection)
echo "[Wingman] Sending prompt..."
tmux send-keys -t "$SESSION_NAME" -l -- "$PROMPT"
sleep 1
# Send Enter explicitly (C-m might not always work reliably in tmux)
tmux send-keys -t "$SESSION_NAME" C-m
sleep 1
# Double-tap Enter to ensure it goes through
tmux send-keys -t "$SESSION_NAME" C-m
sleep 2

echo ""
echo "[Wingman] Session started successfully!"
echo ""
echo "Commands:"
echo "  Attach:    tmux attach -t $SESSION_NAME"
echo "  Monitor:   tmux capture-pane -t $SESSION_NAME -p"
echo "  Kill:      tmux kill-session -t $SESSION_NAME"
echo ""
echo "You'll receive WhatsApp notifications when approval is needed."
echo ""

# Monitor mode
if [ "$MONITOR" = true ]; then
    echo "[Wingman] Monitoring session (Ctrl+C to stop monitoring, session continues)..."
    echo ""
    while tmux has-session -t "$SESSION_NAME" 2>/dev/null; do
        clear
        echo "=== Session: $SESSION_NAME ==="
        tmux capture-pane -t "$SESSION_NAME" -p
        sleep 2
    done
    echo "[Wingman] Session ended."
fi

# Wait mode
if [ "$WAIT" = true ] && [ "$MONITOR" = false ]; then
    echo "[Wingman] Waiting for session to complete..."
    while tmux has-session -t "$SESSION_NAME" 2>/dev/null; do
        sleep 5
    done
    echo "[Wingman] Session completed."
fi
