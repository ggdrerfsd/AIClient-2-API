#!/bin/bash
# ============================================================================
# CC Switch Desktop Sync - Installer
# ============================================================================
# Installs the sync script and LaunchAgent for auto-start
# ============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INSTALL_DIR="$HOME/.local/bin"
INSTALL_PATH="$INSTALL_DIR/cc-switch-sync"
PLIST_SRC="$SCRIPT_DIR/com.ccswitch.desktop-sync.plist"
PLIST_DST="$HOME/Library/LaunchAgents/com.ccswitch.desktop-sync.plist"
SCRIPT_SRC="$SCRIPT_DIR/sync_claude_desktop.sh"

echo "🔧 CC Switch Desktop Sync - Installer"
echo "======================================="
echo ""

# Check prerequisites
if ! command -v jq &>/dev/null; then
    echo "⚠️  jq not found. Installing via Homebrew..."
    if command -v brew &>/dev/null; then
        brew install jq
    else
        echo "❌ Homebrew not found. Please install jq manually."
        exit 1
    fi
fi

# Unload existing agent if running
if launchctl list | grep -q "com.ccswitch.desktop-sync" 2>/dev/null; then
    echo "⏹  Stopping existing sync agent..."
    launchctl unload "$PLIST_DST" 2>/dev/null || true
fi

# Install the script to ~/.local/bin (no sudo needed)
echo "📦 Installing sync script to $INSTALL_PATH..."
mkdir -p "$INSTALL_DIR"
cp "$SCRIPT_SRC" "$INSTALL_PATH"
chmod +x "$INSTALL_PATH"

# Update plist to point to the correct path
echo "📦 Installing LaunchAgent..."
mkdir -p "$HOME/Library/LaunchAgents"
sed "s|/usr/local/bin/cc-switch-sync|$INSTALL_PATH|g" "$PLIST_SRC" > "$PLIST_DST"

# Load the agent
echo "▶️  Starting sync agent..."
launchctl load "$PLIST_DST"

echo ""
echo "✅ Installation complete!"
echo ""
echo "The sync agent is now running and will:"
echo "  • Watch ~/.claude/settings.json for changes"
echo "  • Auto-sync to Claude Code Desktop App config"
echo "  • Auto-start on login"
echo ""
echo "Logs: ~/.cc-switch-sync.log"
echo ""
echo "Commands:"
echo "  Stop:    launchctl unload $PLIST_DST"
echo "  Start:   launchctl load $PLIST_DST"
echo "  Status:  launchctl list | grep ccswitch"
echo "  Logs:    tail -f ~/.cc-switch-sync.log"
echo "  Manual:  $INSTALL_PATH --once"
