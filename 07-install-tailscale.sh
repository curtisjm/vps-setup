#!/usr/bin/env bash
#
# 07-install-tailscale.sh — Install and configure Tailscale on the VPS
#
# PURPOSE:
#   Joins the VPS to your Tailscale network so you can reach it by its
#   tailnet name/IP from any device you've authorized. This is the right
#   default for an agent VPS because it lets you:
#     - SSH without exposing port 22 to the public internet
#     - Reach internal services (Dolt, dashboards) over the tailnet
#       instead of punching holes in UFW
#     - Still log in even if the VPS's public IP changes
#
# WHAT IT DOES:
#   1. Installs Tailscale from its official apt repository (not the snap
#      version, not the curl-pipe-bash installer — we want signed packages
#      that get updated by apt alongside everything else).
#   2. Brings the daemon up in SERVER posture: inbound tailnet connections
#      are ACCEPTED (so you can ssh from your laptop), outbound routing
#      from other tailnet devices is not — this VPS is a destination, not
#      a client or exit node.
#   3. Optionally locks down UFW to allow SSH ONLY from the tailnet, closing
#      public port 22 entirely.
#
# USAGE:
#   ./07-install-tailscale.sh
#
# PREREQUISITES:
#   - Run 00-harden.sh first (fail2ban + UFW already configured).
#   - You'll need a Tailscale account + auth URL (prompted interactively).
#
# DESIGN NOTES:
#   - Curtis's laptop runs Tailscale with '--shields-up' because the laptop
#     is a CLIENT — it reaches out to other tailnet nodes but doesn't host
#     anything. This VPS is the opposite: other devices reach IN to it.
#     So '--shields-up' is deliberately OFF here.
#   - We DON'T enable Tailscale SSH by default — it's convenient but changes
#     the auth model (tailnet identity instead of SSH keys). Opt in via the
#     prompt if you want it.
#   - We DON'T enable exit-node/subnet-router modes here. That's a separate
#     use case (using the VPS as a jump box) that deserves its own decision.
#   - We DON'T '--advertise-routes': nothing on the VPS's local network is
#     worth exposing to the tailnet.

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

# ----------------------------------------------------------------------------
# Step 1: Install Tailscale from the official apt repo
# ----------------------------------------------------------------------------
# Why apt and not 'curl | sh': we want security updates to flow through the
# same unattended-upgrades channel as everything else (set up in 00-harden).
# The Tailscale team maintains a signed Debian repo for exactly this reason.

log "Installing Tailscale..."

if command -v tailscale &> /dev/null; then
    warn "Tailscale already installed ($(tailscale version | head -1)), skipping install"
else
    # Detect distro codename (jammy, noble, bookworm, etc.) so we hit the
    # right apt repo. Tailscale publishes packages for both Ubuntu and Debian.
    . /etc/os-release
    DISTRO_NAME="${ID}"           # ubuntu | debian
    DISTRO_CODENAME="${VERSION_CODENAME}"

    # Pull the signing key and repo definition from pkgs.tailscale.com.
    # Using the 'noarmor' variants makes the stored files smaller and matches
    # Tailscale's documented install path exactly.
    curl -fsSL "https://pkgs.tailscale.com/stable/${DISTRO_NAME}/${DISTRO_CODENAME}.noarmor.gpg" | \
        sudo tee /usr/share/keyrings/tailscale-archive-keyring.gpg > /dev/null

    curl -fsSL "https://pkgs.tailscale.com/stable/${DISTRO_NAME}/${DISTRO_CODENAME}.tailscale-keyring.list" | \
        sudo tee /etc/apt/sources.list.d/tailscale.list > /dev/null

    sudo apt-get update -qq
    sudo apt-get install -y -qq tailscale
    ok "Tailscale installed: $(tailscale version | head -1)"
fi

# Make sure the daemon is enabled and running. systemd unit is installed
# automatically by the package; we just confirm.
sudo systemctl enable --now tailscaled
ok "tailscaled enabled and running"

# ----------------------------------------------------------------------------
# Step 2: Ask about Tailscale SSH
# ----------------------------------------------------------------------------
# Tailscale SSH lets you ssh to this machine using your tailnet identity
# (i.e. you're logged into Tailscale, so you don't need to present an SSH
# key). Nice UX, but changes auth model — if you lose Tailscale access, you
# lose SSH. Opt-in only.

echo ""
log "Tailscale SSH (optional):"
log "  If enabled, you can 'ssh <user>@<tailnet-name>' without setting up an SSH key"
log "  on new devices — Tailscale handles the auth. Your existing SSH key setup keeps"
log "  working as a fallback."
read -rp "Enable Tailscale SSH? [y/N] " ENABLE_TS_SSH

TS_SSH_FLAG=""
if [[ "$ENABLE_TS_SSH" == "y" || "$ENABLE_TS_SSH" == "Y" ]]; then
    TS_SSH_FLAG="--ssh"
    ok "Will enable Tailscale SSH"
fi

# ----------------------------------------------------------------------------
# Step 3: Bring Tailscale up (interactive login)
# ----------------------------------------------------------------------------
# 'tailscale up' prints an auth URL you open in a browser on any logged-in
# device. This VPS is a SERVER — it accepts inbound SSH from tailnet clients
# (your laptop, phone, etc.). Shields are deliberately OFF so those inbound
# connections succeed. --accept-routes=false means we don't let other tailnet
# devices route traffic through this VPS.

log "Bringing Tailscale up in server posture..."
log "  Flags: --accept-routes=false (don't route for others) ${TS_SSH_FLAG:+--ssh }"
log ""
log "  You'll see an auth URL — open it in a browser on a device that's"
log "  already logged into your Tailscale account."
echo ""

if tailscale status &> /dev/null && ! tailscale status | grep -qi "logged out"; then
    warn "Tailscale is already up — applying current settings"
    # If a prior run left shields-up enabled, inbound SSH over tailnet would
    # silently fail. Flip it off explicitly. Idempotent if already off.
    sudo tailscale set --shields-up=false 2>/dev/null || true
    # Apply the user's current SSH preference from the prompt above, even on
    # rerun. Without this, a user who toggles the prompt answer between runs
    # would see no change because the 'up' branch was skipped.
    if [[ -n "$TS_SSH_FLAG" ]]; then
        sudo tailscale set --ssh=true 2>/dev/null || warn "Could not enable Tailscale SSH"
    else
        sudo tailscale set --ssh=false 2>/dev/null || true
    fi
    warn "  (to change settings later: sudo tailscale set --ssh=true|false / --shields-up=false)"
else
    # --shields-up=false: accept inbound (we're the destination, not a client)
    # --accept-dns=true:  use MagicDNS so you can ssh by name instead of IP
    # --accept-routes=false: don't accept subnet routes advertised by others
    # --advertise-routes: not used — nothing on this VPS's local net to share
    sudo tailscale up \
        --shields-up=false \
        --accept-dns=true \
        --accept-routes=false \
        ${TS_SSH_FLAG}
    ok "Tailscale is up"
fi

# Show the current tailnet IP for the user's reference (and for updating
# ~/.ssh/config on the laptop side later).
TS_IP=$(tailscale ip -4 2>/dev/null | head -1 || echo "unknown")
TS_HOST=$(tailscale status --json 2>/dev/null | \
    python3 -c 'import json,sys;print(json.load(sys.stdin)["Self"]["DNSName"].rstrip("."))' 2>/dev/null || \
    echo "unknown")

echo ""
log "Tailnet details for this VPS:"
log "  IPv4:      $TS_IP"
log "  MagicDNS:  $TS_HOST"

# ----------------------------------------------------------------------------
# Step 4: (Optional) lock down public SSH
# ----------------------------------------------------------------------------
# Once Tailscale is working, the cleanest posture is to close public SSH
# entirely and only accept SSH over the tailnet. This makes the VPS
# effectively invisible to internet scanners.
#
# We don't force this because:
#   a) If Tailscale ever breaks, you need a way in.
#   b) Some users want public SSH as a fallback.
#
# If the user opts in, we modify UFW to allow SSH only from the Tailscale
# CGNAT range (100.64.0.0/10) and deny the rest.

echo ""
log "Lock down public SSH? (Only allow SSH over Tailscale going forward)"
log "  Recommended: test Tailscale SSH first from another device before enabling"
log "  this, so you don't lock yourself out if Tailscale isn't working."
log ""
log "  Reversible: to restore public SSH, run:"
log "    sudo ufw allow <port>/tcp"
log "    sudo ufw delete allow from 100.64.0.0/10 to any port <port>"
read -rp "Lock SSH to Tailscale only? [y/N] " LOCK_SSH

if [[ "$LOCK_SSH" == "y" || "$LOCK_SSH" == "Y" ]]; then
    # Read current SSH port from sshd config (set by 00-harden.sh).
    # Default to 22 if not explicitly configured.
    SSH_PORT=$(sudo grep -E '^Port\s+' /etc/ssh/sshd_config | awk '{print $2}' | head -1)
    SSH_PORT=${SSH_PORT:-22}

    log "Current SSH port: $SSH_PORT"

    # Allow SSH from the entire Tailscale CGNAT range (100.64.0.0/10) — this
    # is the IP space Tailscale assigns to all nodes. Any device on your
    # tailnet will have an IP in this range.
    sudo ufw allow from 100.64.0.0/10 to any port "$SSH_PORT" proto tcp comment 'SSH via Tailscale'

    # Remove the public SSH allow rule. We use 'delete allow' to match the
    # rule added by 00-harden.sh. UFW is forgiving — if the rule isn't
    # exactly as we expect, it just no-ops.
    sudo ufw delete allow "$SSH_PORT/tcp" 2>/dev/null || warn "Couldn't remove public SSH rule — check with 'sudo ufw status'"

    sudo ufw reload
    ok "SSH locked to Tailscale CGNAT range only"
    echo ""
    warn "IMPORTANT: verify you can still reach this VPS over Tailscale before logging out:"
    warn "    ssh $USER@$TS_HOST     # from a tailnet-connected device"
else
    log "Keeping public SSH open (you can run this script again to change later)"
fi

# ----------------------------------------------------------------------------
# Final summary
# ----------------------------------------------------------------------------

echo ""
echo -e "${GREEN}==========================================================================${NC}"
echo -e "${GREEN}  Tailscale setup complete!${NC}"
echo -e "${GREEN}==========================================================================${NC}"
echo ""
echo "This VPS is now on your tailnet:"
echo "  Tailnet IPv4:  $TS_IP"
echo "  MagicDNS:      $TS_HOST"
echo ""
echo "From any tailnet-connected device:"
echo "  ssh $USER@$TS_HOST"
echo "  ping $TS_HOST"
echo ""
echo "Useful commands on this VPS:"
echo "  tailscale status           # see who's on your tailnet"
echo "  tailscale ip -4            # show this node's tailnet IP"
echo "  sudo tailscale down        # disconnect (keeps config)"
echo "  sudo tailscale up          # reconnect"
echo "  sudo tailscale set --ssh   # toggle tailscale-ssh later"
echo ""
echo "Update your laptop's ~/.ssh/config to use the MagicDNS name instead of"
echo "the public IP — that way it keeps working if the VPS's public IP changes:"
echo ""
echo "  Host my-vps"
echo "      HostName $TS_HOST"
echo "      User $USER"
echo "      IdentityFile ~/.ssh/id_ed25519"
echo ""
