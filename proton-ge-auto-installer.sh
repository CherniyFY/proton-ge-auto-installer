#!/bin/bash

# Proton-GE Auto-Installer
# Automatically installs latest Proton-GE for Steam (snap installation) on Ubuntu (checked only 24.10)

# Strict error handling
set -euo pipefail

# Ensure HOME variable exists
if [ -z "${HOME:-}" ]; then
    if [ -n "${SUDO_USER:-}" ]; then
        HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
        if [ -z "$HOME" ] || [ ! -d "$HOME" ]; then
            echo "ERROR: Cannot determine HOME for SUDO_USER. Please set HOME." >&2
            exit 1
        fi
    else
        HOME=$(getent passwd "$(id -u)" | cut -d: -f6)
        if [ -z "$HOME" ] || [ ! -d "$HOME" ]; then
            echo "ERROR: Cannot determine HOME directory. Please set HOME." >&2
            exit 1
        fi
    fi
    export HOME
fi

# Configuration
MAX_LOG_SIZE=1000000 # 1MB
LOG_FILE="$HOME/.proton_ge_auto_installer.log"
INSTALL_DIR="$HOME/snap/steam/common/.steam/steam/compatibilitytools.d/"
GITHUB_RESPONSE_TMP="/tmp/proton_ge_github_response.json"
TEMP_CHECKSUM="" # temp archive file checksum set later
TEMP_ARCHIVE=""  # temp archive file name set later
LOCK_FILE="/tmp/proton_ge_auto_installer.lock"

# Remove lock file if older than 1 hour
if [ -f "$LOCK_FILE" ] && [ $(($(date +%s) - $(stat -c %Y "$LOCK_FILE"))) -gt 3600 ]; then
    rm -f "$LOCK_FILE"
fi

log_message() {
    local timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    echo "[$timestamp] $1" | tee -a "$LOG_FILE" >&2
}

# Send desktop notification if available
notify() {
    if command -v notify-send &>/dev/null && [ -n "${DISPLAY:-}" ]; then
        notify-send -a "Proton-GE Auto-Installer" "$1" --icon=steam
    fi
}

# Check all required tools
REQUIRED_CMDS=(curl tar grep basename mktemp sort head xargs stat sha512sum df flock)
for cmd in "${REQUIRED_CMDS[@]}"; do
    if ! command -v $cmd &>/dev/null; then
        log_message "ERROR: Required command '$cmd' not found"
        notify "ERROR: Required command '$cmd' not found"
        exit 1
    fi
done

# Ensure only one instance runs at a time
exec 9>"$LOCK_FILE" || {
    log_message "ERROR: Failed to create lock file"
    exit 1
}
if ! flock -n 9; then
    log_message "ERROR: Another instance is already running"
    exit 0
fi

# Cleanup
cleanup() {
    # Release lock
    flock -u 9 2>/dev/null || true

    # Remove temporary files
    rm -f "$LOCK_FILE" 2>/dev/null || true
    [ -f "$GITHUB_RESPONSE_TMP" ] && rm -f "$GITHUB_RESPONSE_TMP" 2>/dev/null || true
    [ -n "$TEMP_ARCHIVE" ] && [ -f "$TEMP_ARCHIVE" ] && rm -f "$TEMP_ARCHIVE" 2>/dev/null || true
    [ -n "$TEMP_CHECKSUM" ] && [ -f "$TEMP_CHECKSUM" ] && rm -f "$TEMP_CHECKSUM" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

# Rotate log if too large
if [ -f "$LOG_FILE" ] && [ "$(stat -c%s "$LOG_FILE")" -ge "$MAX_LOG_SIZE" ]; then
    mv "$LOG_FILE" "$LOG_FILE.old"
    log_message "Log file rotated: $LOG_FILE.old created"
fi

# Create installation directory if missing
if [ ! -d "$INSTALL_DIR" ]; then
    mkdir -p "$INSTALL_DIR" || {
        log_message "ERROR: Failed to create installation directory: $INSTALL_DIR"
        notify "ERROR: Failed to create installation directory: $INSTALL_DIR"
        exit 1
    }
fi

# Check available disk space
AVAIL_SPACE=$(df -k "$INSTALL_DIR" | tail -1 | awk '{print $4}')
MIN_SPACE=$((50 * 1024 * 1024)) # ~50 GB
if ((AVAIL_SPACE < MIN_SPACE)); then
    log_message "WARNING: Low disk space (${AVAIL_SPACE}KB). At least ${MIN_SPACE}KB recommended."
fi

# Verify installation directory write permissions
if [ ! -w "$INSTALL_DIR" ]; then
    log_message "ERROR: No write permission for: $INSTALL_DIR"
    notify "ERROR: No write permission for: $INSTALL_DIR"
    exit 1
fi

# Fetch latest version
HTTP_CODE=$(curl -fsSL -w "%{http_code}" --connect-timeout 15 --max-time 45 \
    -o "$GITHUB_RESPONSE_TMP" \
    "https://api.github.com/repos/GloriousEggroll/proton-ge-custom/releases/latest")

case "$HTTP_CODE" in
200) ;;
403)
    log_message "ERROR: GitHub API rate limit exceeded"
    notify "ERROR: GitHub API rate limit exceeded"
    exit 1
    ;;
404)
    log_message "ERROR: Proton-GE repository/release not found"
    notify "ERROR: Proton-GE repository/release not found"
    exit 1
    ;;
*)
    log_message "ERROR: GitHub API request failed (HTTP $HTTP_CODE)"
    notify "ERROR: GitHub API request failed (HTTP $HTTP_CODE)"
    exit 1
    ;;
esac

# Parse latest version
LATEST=$(grep -Po '"tag_name": "\K.*?(?=")' "$GITHUB_RESPONSE_TMP")
if [ -z "$LATEST" ]; then
    log_message "ERROR: Failed to parse version from GitHub response"
    notify "ERROR: Failed to parse version from GitHub response"
    exit 1
fi

# Get current version
CURRENT=$(ls -d "$INSTALL_DIR"/GE-Proton* 2>/dev/null | sort -Vr | head -1 | xargs -r basename)
CURRENT=${CURRENT:-"none"}

if [ "$LATEST" != "$CURRENT" ]; then

    # Create temp archive checksum and file
    TEMP_CHECKSUM=$(mktemp "/tmp/proton_ge_$(date +%s)_XXXXXX.sha512sum")
    TEMP_ARCHIVE=$(mktemp "/tmp/proton_ge_$(date +%s)_XXXXXX.tar.gz")

    # Download checksum
    curl -fsSL --max-time 60 --retry 3 --retry-delay 10 \
        "https://github.com/GloriousEggroll/proton-ge-custom/releases/download/$LATEST/$LATEST.sha512sum" \
        -o "$TEMP_CHECKSUM" || {
        log_message "WARNING: Failed to fetch checksum, proceeding without verification"
        notify "WARNING: Failed to fetch checksum, proceeding without verification"
    }

    # Download archive
    if ! curl -fsSL --max-time 300 --retry 3 --retry-delay 10 \
        "https://github.com/GloriousEggroll/proton-ge-custom/releases/download/$LATEST/$LATEST.tar.gz" \
        -o "$TEMP_ARCHIVE"; then
        log_message "ERROR: Download failed"
        notify "ERROR: Download failed"
        exit 1
    fi

    # Verify checksum if available
    if [ -f "$TEMP_CHECKSUM" ]; then
        # Extract the expected checksum from the downloaded file
        EXPECTED_SUM=$(awk '{print $1}' "$TEMP_CHECKSUM")
        # Compute the actual checksum of the downloaded archive
        ACTUAL_SUM=$(sha512sum "$TEMP_ARCHIVE" | awk '{print $1}')

        # Compare
        if [ "$EXPECTED_SUM" != "$ACTUAL_SUM" ]; then
            log_message "ERROR: Checksum verification failed - file may be corrupted or tampered"
            notify "ERROR: Checksum verification failed - file may be corrupted or tampered"
            exit 1
        fi
    fi

    # Validate archive integrity
    if ! tar -tf "$TEMP_ARCHIVE" &>/dev/null; then
        log_message "ERROR: Downloaded archive is corrupted"
        notify "ERROR: Downloaded archive is corrupted"
        exit 1
    fi

    # Extract the archive
    if ! tar -xf "$TEMP_ARCHIVE" -C "$INSTALL_DIR"; then
        log_message "ERROR: Extraction failed"
        notify "ERROR: Extraction failed"
        exit 1
    fi

    # Verify installation
    if [ ! -d "$INSTALL_DIR/$LATEST" ]; then
        log_message "ERROR: Expected directory $LATEST missing after extraction"
        notify "ERROR: Expected directory $LATEST missing after extraction"
        exit 1
    fi

    log_message "Installed $LATEST"
    notify "Installed $LATEST"
else
    log_message "Already latest ($CURRENT)"
    notify "Already latest ($CURRENT)"
fi
