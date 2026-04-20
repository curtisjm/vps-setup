#!/usr/bin/env bash
#
# 03-install-dolt.sh — Install Dolt (version-controlled SQL database)
#
# PURPOSE:
#   Installs Dolt, which Gas Town uses for bead storage. Dolt is like
#   "Git for data" — a SQL database where every change is versioned.
#
# WHAT IT DOES:
#   1. Downloads and installs the Dolt binary
#   2. Configures Dolt with your git identity (it uses the same name/email
#      for its commits as git does)
#   3. Optionally sets up a tmpfs RAM disk for Dolt's working data
#      (Contabo noisy-neighbor workaround)
#
# USAGE:
#   Run as your normal user (NOT root):
#     chmod +x 03-install-dolt.sh
#     ./03-install-dolt.sh
#
# NOTES:
#   - Run 02-setup-git.sh FIRST so Dolt can pick up your git identity.
#   - The tmpfs setup is optional. It trades durability (data lost on
#     reboot unless you sync it out) for speed (especially on Contabo).
#     For Gas Town working data this is usually a good trade — canonical
#     bead history can live on disk, hot working state on tmpfs.

set -euo pipefail

if [[ $EUID -eq 0 ]]; then
    echo "ERROR: Do not run this script as root. Run as your regular user."
    exit 1
fi

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log()   { echo -e "${BLUE}[*]${NC} $1"; }
ok()    { echo -e "${GREEN}[✓]${NC} $1"; }
warn()  { echo -e "${YELLOW}[!]${NC} $1"; }
error() { echo -e "${RED}[✗]${NC} $1"; }

ensure_local_bin_dir() {
    mkdir -p "$HOME/.local/bin"
}
# end ensure_local_bin_dir

# ----------------------------------------------------------------------------
# Step 1: Install Dolt binary
# ----------------------------------------------------------------------------
# Dolt provides an official install script. It puts the binary in
# /usr/local/bin, which is on PATH by default.

# Gas Town requires Dolt >= 1.82.4 (per gastown INSTALLING.md). Anything older
# will hit schema-compatibility bugs (e.g. the 'column started_at could not be
# found in any table in scope' class of errors). We enforce this check.
MIN_DOLT_VERSION="1.82.4"

version_lt() {
    # Returns 0 (true) if $1 < $2 in dotted version comparison
    [ "$1" = "$2" ] && return 1
    [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n1)" = "$1" ]
}

log "Installing Dolt..."

if command -v dolt &> /dev/null; then
    CURRENT_VERSION=$(dolt version | head -1 | awk '{print $3}')
    if version_lt "$CURRENT_VERSION" "$MIN_DOLT_VERSION"; then
        warn "Dolt $CURRENT_VERSION is older than required $MIN_DOLT_VERSION — upgrading"
        sudo bash -c 'curl -L https://github.com/dolthub/dolt/releases/latest/download/install.sh | bash'
        ok "Dolt upgraded to $(dolt version | head -1 | awk '{print $3}')"
    else
        warn "Dolt already installed (version $CURRENT_VERSION, >= $MIN_DOLT_VERSION)"
        read -rp "Reinstall/upgrade to latest anyway? [y/N]: " REINSTALL
        if [[ "$REINSTALL" == "y" || "$REINSTALL" == "Y" ]]; then
            sudo bash -c 'curl -L https://github.com/dolthub/dolt/releases/latest/download/install.sh | bash'
            ok "Dolt upgraded to $(dolt version | head -1 | awk '{print $3}')"
        else
            log "Skipping upgrade"
        fi
    fi
else
    # Dolt's install script needs root to write to /usr/local/bin
    sudo bash -c 'curl -L https://github.com/dolthub/dolt/releases/latest/download/install.sh | bash'
    INSTALLED_VERSION=$(dolt version | head -1 | awk '{print $3}')
    if version_lt "$INSTALLED_VERSION" "$MIN_DOLT_VERSION"; then
        error "Installed Dolt $INSTALLED_VERSION but Gas Town needs >= $MIN_DOLT_VERSION"
        error "This shouldn't happen with 'latest' — check https://github.com/dolthub/dolt/releases"
        exit 1
    fi
    ok "Dolt installed: $(dolt version | head -1)"
fi

# ----------------------------------------------------------------------------
# Step 2: Configure Dolt identity
# ----------------------------------------------------------------------------
# Dolt uses its own config (not git's) for commit author info. We pull
# the values from git config for consistency.

log "Configuring Dolt identity..."

GIT_NAME=$(git config --global user.name || echo "")
GIT_EMAIL=$(git config --global user.email || echo "")

if [[ -z "$GIT_NAME" || -z "$GIT_EMAIL" ]]; then
    warn "Git identity not set. Run 02-setup-git.sh first, or enter manually:"
    read -rp "Name: " GIT_NAME
    read -rp "Email: " GIT_EMAIL
fi

# Dolt's --add appends; on rerun it silently creates duplicate entries. We
# --unset first (tolerating not-set) then --add to keep the config clean.
dolt config --global --unset user.name 2>/dev/null || true
dolt config --global --unset user.email 2>/dev/null || true
dolt config --global --add user.name "$GIT_NAME"
dolt config --global --add user.email "$GIT_EMAIL"
ok "Dolt identity set to $GIT_NAME <$GIT_EMAIL>"

# ----------------------------------------------------------------------------
# Step 3: Optional tmpfs setup for hot Dolt data
# ----------------------------------------------------------------------------
# This is the Contabo workaround we discussed: Dolt's working data on a
# tmpfs (RAM-backed filesystem) gives you NVMe-class speed without being
# subject to Contabo's shared disk. The trade-off is that tmpfs contents
# are lost on reboot unless you sync them elsewhere.
#
# Approach: we create a tmpfs mount at ~/dolt-tmpfs. You put working dolt
# databases there for speed. For anything you want to persist across
# reboots, either:
#   a) Push it to a Dolt remote (DoltHub, or another server), or
#   b) Periodically rsync it to ~/dolt-persistent (disk-backed)
#
# We don't force this setup — it's opt-in because it's a sharper tool.

echo ""
read -rp "Set up a 4GB tmpfs for hot Dolt data? (Contabo speed workaround) [y/N]: " SETUP_TMPFS

if [[ "$SETUP_TMPFS" == "y" || "$SETUP_TMPFS" == "Y" ]]; then
    log "Setting up tmpfs for Dolt working data..."

    TMPFS_DIR="$HOME/dolt-tmpfs"
    PERSIST_DIR="$HOME/dolt-persistent"

    mkdir -p "$TMPFS_DIR" "$PERSIST_DIR"
    ensure_local_bin_dir

    # Check if tmpfs is already mounted there
    if mountpoint -q "$TMPFS_DIR"; then
        warn "tmpfs already mounted at $TMPFS_DIR, skipping fstab setup"
    else
        # Add to /etc/fstab so it persists across reboots.
        # size=4G: cap at 4GB (generous for Dolt working data; adjust if needed)
        # noatime: don't update access times (write amplification — pointless for tmpfs)
        # nodev,nosuid: can't have device files or setuid binaries (security hardening)
        # uid/gid: owned by current user so we don't need sudo to write there
        FSTAB_ENTRY="tmpfs $TMPFS_DIR tmpfs size=4G,noatime,nodev,nosuid,uid=$(id -u),gid=$(id -g) 0 0"

        if ! grep -qF "$TMPFS_DIR" /etc/fstab; then
            echo "$FSTAB_ENTRY" | sudo tee -a /etc/fstab > /dev/null
            ok "Added tmpfs entry to /etc/fstab"
        fi

        sudo mount "$TMPFS_DIR"
        ok "tmpfs mounted at $TMPFS_DIR"
    fi

    # Create a helper script to sync from tmpfs to disk (so you can cron
    # this or run it manually before rebooting).
    cat > "$HOME/.local/bin/dolt-sync-to-disk" <<EOF
#!/usr/bin/env bash
# Sync hot Dolt data from tmpfs to persistent disk.
# Run manually or via cron: */30 * * * * ~/.local/bin/dolt-sync-to-disk
set -e
rsync -a --delete "$TMPFS_DIR/" "$PERSIST_DIR/"
echo "Synced $TMPFS_DIR -> $PERSIST_DIR at \$(date)"
EOF
    chmod +x "$HOME/.local/bin/dolt-sync-to-disk"
    ok "Created ~/.local/bin/dolt-sync-to-disk for syncing tmpfs -> disk"

    # And the reverse: restore from disk to tmpfs after a reboot.
    cat > "$HOME/.local/bin/dolt-restore-from-disk" <<EOF
#!/usr/bin/env bash
# Restore Dolt data from persistent disk to tmpfs after a reboot.
# Run this after the VPS boots if you had data in tmpfs.
set -e
rsync -a "$PERSIST_DIR/" "$TMPFS_DIR/"
echo "Restored $PERSIST_DIR -> $TMPFS_DIR at \$(date)"
EOF
    chmod +x "$HOME/.local/bin/dolt-restore-from-disk"
    ok "Created ~/.local/bin/dolt-restore-from-disk for post-reboot restore"

    echo ""
    warn "Important reminders about tmpfs:"
    warn "  - Data in $TMPFS_DIR is LOST on reboot"
    warn "  - Run 'dolt-sync-to-disk' regularly (or cron it every 30 min)"
    warn "  - Run 'dolt-restore-from-disk' after reboots"
    warn "  - Push to a Dolt remote for real backups"
else
    log "Skipping tmpfs setup (you can run this again later if you change your mind)"
fi

# ----------------------------------------------------------------------------
# Final summary
# ----------------------------------------------------------------------------

echo ""
echo -e "${GREEN}==========================================================================${NC}"
echo -e "${GREEN}  Dolt installation complete!${NC}"
echo -e "${GREEN}==========================================================================${NC}"
echo ""
echo "Dolt version: $(dolt version | head -1)"
echo ""
echo "Quick reference:"
echo "  dolt init                    # Initialize a new dolt repo in current dir"
echo "  dolt sql                     # Interactive SQL shell"
echo "  dolt sql-server              # Start MySQL-compatible server"
echo "  dolt status                  # Like git status"
echo "  dolt diff                    # Like git diff (shows data changes)"
echo "  dolt commit -am 'message'    # Commit changes"
echo "  dolt log                     # See commit history"
echo ""
echo "Docs: https://docs.dolthub.com/"
echo ""
