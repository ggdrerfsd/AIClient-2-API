#!/bin/bash
# ============================================================================
# CC Switch → Claude Code Desktop App Config Sync
# ============================================================================
# This script watches ~/.claude/settings.json for changes made by CC Switch
# and switches the active configuration in Claude Code Desktop App's
# configLibrary to match. It works by:
#
#   1. Reading the current ANTHROPIC_BASE_URL from CLI settings
#   2. Finding the Desktop config with matching inferenceGatewayBaseUrl
#   3. Updating _meta.json's appliedId to point to that config
#   4. Also syncing API key and models to that config
#   5. Killing Claude Desktop App if config changed (user restarts manually)
#
# This replicates the effect of manually selecting a configuration in the
# Claude Code Desktop App's config switcher dropdown.
#
# Usage: 
#   ./sync_claude_desktop.sh          # Run in foreground (watch mode)
#   ./sync_claude_desktop.sh --once   # Run once and exit (manual sync)
# ============================================================================

set -euo pipefail

# Ensure Homebrew tools are in PATH (LaunchAgents don't inherit shell PATH)
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

# --- Configuration ---
CLI_SETTINGS="$HOME/.claude/settings.json"
DESKTOP_CONFIG_DIR="$HOME/Library/Application Support/Claude-3p/configLibrary"
DESKTOP_META="$DESKTOP_CONFIG_DIR/_meta.json"
LOG_FILE="$HOME/.cc-switch-sync.log"
MAX_LOG_SIZE=1048576  # 1MB, rotate when exceeded

# Desktop config static fields to ensure are present
DESKTOP_STATIC_FIELDS='{
  "disableDeploymentModeChooser": false,
  "inferenceProvider": "gateway",
  "inferenceGatewayAuthScheme": "bearer",
  "isClaudeCodeForDesktopEnabled": true,
  "isDesktopExtensionEnabled": true,
  "isDesktopExtensionDirectoryEnabled": true,
  "isDesktopExtensionSignatureRequired": false,
  "isLocalDevMcpEnabled": true,
  "disableAutoUpdates": false,
  "disableEssentialTelemetry": false,
  "disableNonessentialTelemetry": false,
  "disableNonessentialServices": false
}'

# --- Logging ---
log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $1"
    echo "$msg" >> "$LOG_FILE"
    echo "$msg"
}

# --- macOS Notifications ---
notify() {
    local title="$1"
    local message="$2"
    local sound="${3:-}"  # optional sound name
    local sound_arg=""
    if [[ -n "$sound" ]]; then
        sound_arg="sound name \"$sound\""
    fi
    osascript -e "display notification \"$message\" with title \"$title\" $sound_arg" 2>/dev/null || true
}

notify_success() {
    notify "CC Switch Sync ✅" "$1" "Glass"
}

notify_error() {
    notify "CC Switch Sync ❌" "$1" "Basso"
}

# Rotate log file if it exceeds MAX_LOG_SIZE
rotate_log() {
    if [[ -f "$LOG_FILE" ]]; then
        local size
        size=$(stat -f '%z' "$LOG_FILE" 2>/dev/null || echo 0)
        if [[ "$size" -gt "$MAX_LOG_SIZE" ]]; then
            mv "$LOG_FILE" "${LOG_FILE}.old"
            log "Log rotated (previous log: ${LOG_FILE}.old)"
        fi
    fi
}

# --- Safe file write: write to tmp, validate, then move ---
safe_write_json() {
    local target_file="$1"
    local tmp_file="${target_file}.tmp.$$"
    
    # Read from stdin, write to tmp
    cat > "$tmp_file"
    
    # Validate the tmp file is valid JSON and non-empty
    if [[ ! -s "$tmp_file" ]] || ! jq empty "$tmp_file" 2>/dev/null; then
        log "  ERROR: Failed to write valid JSON to $target_file, keeping original"
        notify_error "配置写入失败，原配置已保留"
        rm -f "$tmp_file"
        return 1
    fi
    
    mv "$tmp_file" "$target_file"
    return 0
}

# --- Find and kill Claude Desktop App (robust, name-agnostic) ---
kill_claude_desktop() {
    # Strategy 1: Find by Application Support data dir (most reliable)
    # Any Electron app using "Claude-3p" data dir is the target
    local claude_pids
    claude_pids=$(pgrep -f "Application Support/Claude-3p" 2>/dev/null || true)
    
    if [[ -z "$claude_pids" ]]; then
        # Strategy 2: Find by app bundle pattern - any .app containing "laude" in MacOS binary
        claude_pids=$(pgrep -f "[Cc]laude.app/Contents/MacOS" 2>/dev/null || true)
    fi
    
    if [[ -z "$claude_pids" ]]; then
        log "  ℹ️  Claude Desktop App is not running, no need to restart."
        return 0
    fi
    
    log "  🔄 Quitting Claude Desktop App for config to take effect..."
    
    # Try graceful quit via osascript - find the app name dynamically
    local app_name
    app_name=$(ps -p $(echo "$claude_pids" | head -1) -o command= 2>/dev/null | grep -oE '/Applications/[^/]+\.app' | head -1 | xargs basename 2>/dev/null | sed 's/\.app$//' || true)
    
    if [[ -n "$app_name" ]]; then
        log "  Detected app name: $app_name"
        osascript -e "quit app \"$app_name\"" 2>/dev/null || true
    else
        # Fallback: try common names
        osascript -e 'quit app "Claude"' 2>/dev/null || true
    fi
    
    sleep 2
    
    # Check if still running, force kill if needed
    claude_pids=$(pgrep -f "Application Support/Claude-3p" 2>/dev/null || true)
    if [[ -z "$claude_pids" ]]; then
        claude_pids=$(pgrep -f "[Cc]laude.app/Contents/MacOS" 2>/dev/null || true)
    fi
    
    if [[ -n "$claude_pids" ]]; then
        log "  ⚠️  App still running, force killing..."
        echo "$claude_pids" | xargs kill -9 2>/dev/null || true
        sleep 1
    fi
    
    log "  ✅ Claude Desktop App stopped. Please restart it to use the new config."
}

# --- Extract provider info from CLI settings ---
extract_cli_provider() {
    if [[ ! -f "$CLI_SETTINGS" ]]; then
        log "ERROR: CLI settings file not found: $CLI_SETTINGS"
        notify_error "CLI 配置文件不存在: settings.json"
        return 1
    fi

    # Validate JSON first
    if ! jq empty "$CLI_SETTINGS" 2>/dev/null; then
        log "ERROR: CLI settings file is not valid JSON (may be mid-write), retrying..."
        sleep 1
        if ! jq empty "$CLI_SETTINGS" 2>/dev/null; then
            log "ERROR: CLI settings file still invalid JSON, skipping sync"
            notify_error "CLI 配置文件 JSON 格式错误"
            return 1
        fi
    fi

    local base_url api_key models_json

    # Extract ANTHROPIC_BASE_URL
    base_url=$(jq -r '.env.ANTHROPIC_BASE_URL // empty' "$CLI_SETTINGS" 2>/dev/null)
    if [[ -z "$base_url" ]]; then
        log "ERROR: Could not extract ANTHROPIC_BASE_URL from CLI settings"
        return 1
    fi

    # Extract ANTHROPIC_AUTH_TOKEN
    api_key=$(jq -r '.env.ANTHROPIC_AUTH_TOKEN // empty' "$CLI_SETTINGS" 2>/dev/null)
    if [[ -z "$api_key" ]]; then
        log "ERROR: Could not extract ANTHROPIC_AUTH_TOKEN from CLI settings"
        return 1
    fi

    # Extract models for Desktop App:
    #   - ANTHROPIC_MODEL (主模型) → first entry (default in Desktop picker)
    #   - ANTHROPIC_DEFAULT_SONNET_MODEL (Sonnet) → second entry (lighter model)
    # Desktop App uses these two: main model for complex tasks, Sonnet for lighter ones.
    models_json=$(jq -r '
        [
            (.env.ANTHROPIC_MODEL // empty),
            (.env.ANTHROPIC_DEFAULT_SONNET_MODEL // empty)
        ] | map(select(. != "")) | unique | map({name: ., supports1m: true})
    ' "$CLI_SETTINGS" 2>/dev/null)

    if [[ -z "$models_json" || "$models_json" == "[]" ]]; then
        log "WARNING: No models found in CLI settings, using default"
        models_json='[{"name": "claude-opus-4-6", "supports1m": true}]'
    fi

    echo "$base_url"
    echo "$api_key"
    echo "$models_json"
}

# --- Find Desktop config ID by base URL ---
find_config_by_url() {
    local target_url="$1"
    
    # Normalize URL: remove trailing slash
    target_url="${target_url%/}"
    
    for config_file in "$DESKTOP_CONFIG_DIR"/*.json; do
        # Skip if glob didn't match anything
        [[ -f "$config_file" ]] || continue
        
        local fname
        fname=$(basename "$config_file")
        
        # Skip _meta.json
        [[ "$fname" == "_meta.json" ]] && continue
        
        local config_url
        config_url=$(jq -r '.inferenceGatewayBaseUrl // empty' "$config_file" 2>/dev/null)
        config_url="${config_url%/}"
        
        if [[ "$config_url" == "$target_url" ]]; then
            # Return the config ID (filename without .json)
            echo "${fname%.json}"
            return 0
        fi
    done
    
    return 1
}

# --- Sync: match URL, switch appliedId, update config ---
sync_config() {
    log "Syncing CLI settings → Desktop config..."

    # Read CLI settings
    local output base_url api_key models_json
    output=$(extract_cli_provider) || return 1

    base_url=$(echo "$output" | head -1)
    api_key=$(echo "$output" | head -2 | tail -1)
    models_json=$(echo "$output" | tail -n +3)

    log "  CLI Base URL: $base_url"
    log "  CLI API Key:  ${api_key:0:10}..."

    # Find matching Desktop config by base URL
    local matched_id
    matched_id=$(find_config_by_url "$base_url") || true

    if [[ -z "$matched_id" ]]; then
        log "  ⚠️  No Desktop config found matching URL: $base_url"
        log "  Creating new config entry..."
        
        # Generate a new UUID
        matched_id=$(uuidgen | tr '[:upper:]' '[:lower:]')
        local new_config_file="$DESKTOP_CONFIG_DIR/$matched_id.json"
        
        # Create new config with CLI data + static fields
        jq -n \
            --arg base_url "$base_url" \
            --arg api_key "$api_key" \
            --argjson models "$models_json" \
            --argjson static "$DESKTOP_STATIC_FIELDS" \
            '$static + {
                "inferenceGatewayBaseUrl": $base_url,
                "inferenceGatewayApiKey": $api_key,
                "inferenceModels": $models
            }' | safe_write_json "$new_config_file" || return 1
        
        # Derive a name from the URL
        local config_name
        config_name=$(echo "$base_url" | sed 's|https\?://||' | sed 's|/.*||')
        
        # Add to _meta.json entries
        jq --arg id "$matched_id" --arg name "$config_name" \
            '.entries += [{"id": $id, "name": $name}]' \
            "$DESKTOP_META" | safe_write_json "$DESKTOP_META" || return 1
        
        log "  Created new config: $config_name ($matched_id)"
    fi

    # Get current appliedId
    local current_applied
    current_applied=$(jq -r '.appliedId // empty' "$DESKTOP_META" 2>/dev/null)

    # Track whether config actually changed (for deciding whether to kill app)
    local config_changed=false

    # Check if already applied
    if [[ "$current_applied" == "$matched_id" ]]; then
        log "  Config already applied: $matched_id"
        log "  Checking if API key/models need update..."
    else
        log "  Switching applied config: $current_applied → $matched_id"
        config_changed=true
    fi

    # Update the matched config file with latest API key and models from CLI
    local config_file="$DESKTOP_CONFIG_DIR/$matched_id.json"
    if [[ -f "$config_file" ]]; then
        local existing_key existing_models
        existing_key=$(jq -r '.inferenceGatewayApiKey // empty' "$config_file")
        existing_models=$(jq -c '.inferenceModels // []' "$config_file")
        local new_models
        new_models=$(echo "$models_json" | jq -c '.')

        if [[ "$existing_key" != "$api_key" || "$existing_models" != "$new_models" ]]; then
            # Update API key and models in the config, preserve other fields
            jq --arg api_key "$api_key" --argjson models "$models_json" \
                '.inferenceGatewayApiKey = $api_key | .inferenceModels = $models' \
                "$config_file" | safe_write_json "$config_file" || return 1
            log "  Updated API key/models in config file"
            config_changed=true
        fi
    fi

    # Switch appliedId in _meta.json
    if [[ "$current_applied" != "$matched_id" ]]; then
        jq --arg id "$matched_id" '.appliedId = $id' "$DESKTOP_META" \
            | safe_write_json "$DESKTOP_META" || return 1
        log "  ✅ appliedId switched to: $matched_id"
        
        # Look up the name for logging
        local config_name
        config_name=$(jq -r --arg id "$matched_id" '.entries[] | select(.id == $id) | .name' "$DESKTOP_META" 2>/dev/null)
        log "  ✅ Desktop App now using: $config_name ($base_url)"
    fi

    # Kill Claude Desktop App if config changed
    if [[ "$config_changed" == "true" ]]; then
        kill_claude_desktop
    else
        log "  ✅ Already up to date, no restart needed."
    fi

    log "  Sync complete!"
}

# --- Watch mode ---
watch_settings() {
    log "Starting CC Switch → Desktop sync watcher..."
    log "Watching: $CLI_SETTINGS"
    log "Target:   $DESKTOP_CONFIG_DIR"
    
    # Initial sync
    sync_config || true

    # Check if fswatch is available
    if ! command -v fswatch &>/dev/null; then
        log "fswatch not found. Falling back to polling mode (2s interval)..."
        local last_mtime=""
        while true; do
            rotate_log
            local current_mtime
            current_mtime=$(stat -f '%m' "$CLI_SETTINGS" 2>/dev/null || echo "")
            if [[ -n "$current_mtime" && "$current_mtime" != "$last_mtime" ]]; then
                if [[ -n "$last_mtime" ]]; then
                    log "Change detected in $CLI_SETTINGS"
                    sleep 0.5  # Brief delay to ensure file write is complete
                    sync_config || true
                fi
                last_mtime="$current_mtime"
            fi
            sleep 2
        done
    else
        # Use fswatch for efficient file system monitoring
        local change_count=0
        fswatch -o "$CLI_SETTINGS" | while read -r _count; do
            change_count=$((change_count + 1))
            # Rotate log every 100 changes
            if (( change_count % 100 == 0 )); then
                rotate_log
            fi
            log "Change detected in $CLI_SETTINGS"
            sleep 0.5  # Brief delay to ensure file write is complete
            sync_config || true
        done
    fi
}

# --- Main ---
main() {
    log "========================================"
    log "CC Switch Desktop Sync v3 starting..."
    log "========================================"

    # Verify prerequisites
    if ! command -v jq &>/dev/null; then
        log "ERROR: jq is required but not found. Install with: brew install jq"
        exit 1
    fi

    if [[ ! -d "$DESKTOP_CONFIG_DIR" ]]; then
        log "ERROR: Desktop config directory not found: $DESKTOP_CONFIG_DIR"
        exit 1
    fi

    if [[ ! -f "$DESKTOP_META" ]]; then
        log "ERROR: Desktop _meta.json not found: $DESKTOP_META"
        exit 1
    fi

    if [[ "${1:-}" == "--once" ]]; then
        sync_config
    else
        watch_settings
    fi
}

main "$@"
