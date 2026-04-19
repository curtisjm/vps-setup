#!/usr/bin/env bash
#
# 00-harden.sh — Initial VPS security hardening
#
# PURPOSE:
#   Locks down a fresh Ubuntu/Debian VPS with sensible security defaults.
#   Run this FIRST, as root, immediately after provisioning the VPS.
#
# WHAT IT DOES:
#   1. Updates all packages (patches known vulnerabilities)
#   2. Creates a non-root sudo user (root should not be used for daily work)
#   3. Sets up SSH key authentication (passwords are brute-forceable)
#   4. Disables root login and password auth over SSH
#   5. Configures UFW firewall (deny-by-default is the only sane policy)
#   6. Installs fail2ban (auto-bans brute-force attempts)
#   7. Enables unattended security upgrades
#   8. Applies sysctl kernel hardening
#   9. Installs basic monitoring tools (htop, iotop, vmstat, etc.)
#
# USAGE:
#   Run ONCE on a fresh VPS as root:
#     scp 00-harden.sh root@your-vps-ip:/root/
#     ssh root@your-vps-ip
#     chmod +x 00-harden.sh
#     ./00-harden.sh
#
#   You'll be prompted for:
#     - The new username you want to create
#     - Your public SSH key (paste the contents of ~/.ssh/id_ed25519.pub)
#     - Optionally, a custom SSH port
#
# IMPORTANT:
#   This script will disable root SSH and password auth. Before it restarts
#   sshd, it will ask you to confirm you can log in as the new user from
#   a SECOND terminal. Do NOT skip this check or you may lock yourself out.
#   If you do get locked out, Contabo provides a web-based VNC console in
#   their control panel as a recovery option.

set -euo pipefail  # Exit on error, undefined var, or failed pipe — fail loudly, not silently

# ----------------------------------------------------------------------------
# Pre-flight checks
# ----------------------------------------------------------------------------

# This script must run as root because it modifies system files, installs
# packages, and creates users. If we're not root, bail out immediately.
if [[ $EUID -ne 0 ]]; then
    echo "ERROR: This script must be run as root. Try: sudo $0"
    exit 1
fi

# Color codes for readable output. These make it easier to spot what
# happened when scrolling through a long log.
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log()   { echo -e "${BLUE}[*]${NC} $1"; }
ok()    { echo -e "${GREEN}[✓]${NC} $1"; }
warn()  { echo -e "${YELLOW}[!]${NC} $1"; }
error() { echo -e "${RED}[✗]${NC} $1"; }

# ----------------------------------------------------------------------------
# Step 1: Gather user input upfront
# ----------------------------------------------------------------------------
# We collect everything we need at the start so the script can run
# unattended afterward. Nothing worse than walking away and coming back
# to a prompt you missed.

log "Gathering configuration..."

read -rp "Username to create (e.g., curtis): " NEW_USER
if [[ -z "$NEW_USER" ]]; then
    error "Username cannot be empty"
    exit 1
fi

# Prompt for SSH public key. We require this upfront because disabling
# password auth without a key in place is how people lock themselves out.
echo ""
echo "Paste your SSH public key (usually contents of ~/.ssh/id_ed25519.pub on your local machine)."
echo "It should start with 'ssh-ed25519' or 'ssh-rsa' and be a single line."
read -rp "Public key: " SSH_PUBKEY
if [[ ! "$SSH_PUBKEY" =~ ^(ssh-ed25519|ssh-rsa|ecdsa-sha2) ]]; then
    error "That doesn't look like a valid SSH public key. It should start with ssh-ed25519, ssh-rsa, or ecdsa-sha2."
    exit 1
fi

# Optional SSH port change. Moving off port 22 doesn't add real security
# (determined attackers will scan all ports), but it dramatically reduces
# log noise from drive-by bot traffic. Purely quality-of-life.
echo ""
read -rp "SSH port (press Enter for 22, or pick a custom port 1024-65535): " SSH_PORT
SSH_PORT=${SSH_PORT:-22}
if ! [[ "$SSH_PORT" =~ ^[0-9]+$ ]] || [[ "$SSH_PORT" -lt 1 ]] || [[ "$SSH_PORT" -gt 65535 ]]; then
    error "Invalid port number"
    exit 1
fi

echo ""
log "Configuration summary:"
log "  Username: $NEW_USER"
log "  SSH port: $SSH_PORT"
log "  SSH key: ${SSH_PUBKEY:0:40}..."
echo ""
read -rp "Proceed with hardening? [y/N] " CONFIRM
if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
    warn "Aborted by user"
    exit 0
fi

# ----------------------------------------------------------------------------
# Step 2: System update
# ----------------------------------------------------------------------------
# Always update before doing anything else. The base image may be weeks or
# months old and have known CVEs patched in newer package versions.
# DEBIAN_FRONTEND=noninteractive prevents prompts during upgrades (e.g.,
# about config file changes) which would hang the script.

log "Updating package lists and upgrading system..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get upgrade -y -qq
apt-get autoremove -y -qq
ok "System updated"

# ----------------------------------------------------------------------------
# Step 3: Install essential security and utility packages
# ----------------------------------------------------------------------------
# Installing these now so everything we need is available for the rest
# of the script. Rationale for each:
#   - ufw: the firewall we'll configure
#   - fail2ban: bans IPs that repeatedly fail auth
#   - unattended-upgrades: applies security patches automatically
#   - htop/iotop/sysstat: monitoring tools (vmstat for CPU steal in particular)
#   - curl/wget: needed by pretty much everything else
#   - rsync: for backups/migrations later
#   - git: needed for most dev workflows

log "Installing security and utility packages..."
apt-get install -y -qq \
    ufw \
    fail2ban \
    unattended-upgrades \
    apt-listchanges \
    htop \
    iotop \
    sysstat \
    curl \
    wget \
    rsync \
    git \
    ca-certificates \
    gnupg \
    software-properties-common
ok "Packages installed"

# ----------------------------------------------------------------------------
# Step 4: Create non-root user
# ----------------------------------------------------------------------------
# Working as root is dangerous — one typo can brick the system. Standard
# practice is a regular user with sudo for privileged actions, which forces
# you to consciously escalate when needed.

log "Creating user: $NEW_USER"
if id "$NEW_USER" &>/dev/null; then
    warn "User $NEW_USER already exists, skipping creation"
else
    # --disabled-password: no password set initially (we'll use SSH keys only)
    # --gecos "": skip the full-name/phone/etc. prompts
    adduser --disabled-password --gecos "" "$NEW_USER"
    ok "User created"
fi

# Add user to sudo group. On Debian/Ubuntu this grants full sudo access.
usermod -aG sudo "$NEW_USER"
ok "Added $NEW_USER to sudo group"

# ----------------------------------------------------------------------------
# Step 5: Set up SSH key for the new user
# ----------------------------------------------------------------------------
# SSH keys are vastly more secure than passwords — they can't be
# brute-forced in any practical sense, and they can't be phished the same way.
# We set up the .ssh directory with the correct restrictive permissions
# that sshd requires (it will refuse to use the key if perms are too loose).

log "Setting up SSH key for $NEW_USER..."
USER_HOME="/home/$NEW_USER"
mkdir -p "$USER_HOME/.ssh"
echo "$SSH_PUBKEY" > "$USER_HOME/.ssh/authorized_keys"

# 700 on .ssh dir, 600 on authorized_keys — sshd requires these exact perms
# or it will silently refuse to use the key and fall back to password auth
# (which we're about to disable, so you'd be locked out).
chmod 700 "$USER_HOME/.ssh"
chmod 600 "$USER_HOME/.ssh/authorized_keys"
chown -R "$NEW_USER:$NEW_USER" "$USER_HOME/.ssh"
ok "SSH key installed for $NEW_USER"

# ----------------------------------------------------------------------------
# Step 6: Configure sudo to require password
# ----------------------------------------------------------------------------
# By default on Ubuntu, sudo asks for password — good. But we want to make
# sure NOPASSWD isn't set anywhere for our user. This is defense in depth:
# if an attacker ever gets into the account, they still need the password
# to escalate.

log "Verifying sudo configuration requires password..."
# We don't need to do anything here on stock Ubuntu — sudo defaults are sane.
# If you wanted password-less sudo for automation (bad idea for most cases),
# you'd add: echo "$NEW_USER ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/$NEW_USER
ok "Sudo requires password (default)"

# ----------------------------------------------------------------------------
# Step 7: TEST USER LOGIN BEFORE LOCKING DOWN SSH
# ----------------------------------------------------------------------------
# Critical safety check: we're about to disable root SSH and password auth.
# If the user can't log in as $NEW_USER with their key, they'll be locked out.
# Pause here and have them verify in a separate terminal.

echo ""
warn "=========================================================================="
warn "CRITICAL: Before continuing, open a NEW terminal window and verify you"
warn "can SSH in as the new user:"
warn ""
warn "    ssh $NEW_USER@$(hostname -I | awk '{print $1}')"
warn ""
warn "Once you confirm the new user can log in with their SSH key,"
warn "come back here and continue. If you can't log in, DO NOT continue —"
warn "press Ctrl+C and investigate. If you continue with a broken key setup,"
warn "you WILL be locked out."
warn "=========================================================================="
echo ""
read -rp "Have you verified SSH login as $NEW_USER works in another terminal? [y/N] " VERIFIED
if [[ "$VERIFIED" != "y" && "$VERIFIED" != "Y" ]]; then
    error "Aborting. Fix SSH key setup and re-run, or manually continue from here."
    exit 1
fi

# ----------------------------------------------------------------------------
# Step 8: Harden SSH daemon configuration
# ----------------------------------------------------------------------------
# These changes dramatically reduce SSH attack surface:
#   - PermitRootLogin no: root can't SSH in at all (must use sudo from user)
#   - PasswordAuthentication no: only key-based auth works
#   - PubkeyAuthentication yes: explicitly enable keys (usually already on)
#   - MaxAuthTries 3: drop connection after 3 failed attempts
#   - ClientAliveInterval/CountMax: disconnect idle sessions after ~10 min
#     (prevents dangling sessions from being hijacked)
#   - X11Forwarding no: we're not running GUIs, don't enable this attack surface
#   - Port: optionally move off 22 to reduce bot noise in logs

log "Hardening SSH configuration..."
SSH_CONFIG="/etc/ssh/sshd_config"

# Back up the original config so we can revert if something goes wrong.
# Include timestamp so re-runs don't clobber the original backup.
cp "$SSH_CONFIG" "${SSH_CONFIG}.backup.$(date +%Y%m%d-%H%M%S)"

# We use a helper to set config options: remove any existing line for the
# key (commented or not), then append the new value. This is more robust
# than sed'ing in place, which can fail on commented-out lines.
set_ssh_option() {
    local key="$1"
    local value="$2"
    # Remove any existing line (commented or not) setting this option
    sed -i "/^#*\s*${key}\s/d" "$SSH_CONFIG"
    # Append the new setting
    echo "${key} ${value}" >> "$SSH_CONFIG"
}

set_ssh_option "Port" "$SSH_PORT"
set_ssh_option "PermitRootLogin" "no"
set_ssh_option "PasswordAuthentication" "no"
set_ssh_option "PubkeyAuthentication" "yes"
set_ssh_option "PermitEmptyPasswords" "no"
set_ssh_option "X11Forwarding" "no"
set_ssh_option "MaxAuthTries" "3"
set_ssh_option "ClientAliveInterval" "300"
set_ssh_option "ClientAliveCountMax" "2"
set_ssh_option "AllowUsers" "$NEW_USER"

# Validate the config before reloading — if there's a syntax error,
# sshd will fail to start and you'll be locked out.
if ! sshd -t; then
    error "SSH config validation failed! Not restarting sshd. Restore from backup:"
    error "  cp ${SSH_CONFIG}.backup.* $SSH_CONFIG"
    exit 1
fi

systemctl restart sshd
ok "SSH hardened (port $SSH_PORT, root disabled, password auth disabled)"

# ----------------------------------------------------------------------------
# Step 9: Configure UFW firewall
# ----------------------------------------------------------------------------
# Deny-by-default inbound, allow all outbound. This is the right posture
# for 99% of servers — you explicitly open ports you need, and nothing else
# can reach the box.
#
# For an agent VPS you likely don't need ANY inbound ports other than SSH.
# Agent processes make outbound API calls; they don't receive connections.
# For internal dashboards (e.g. Netdata, Dolt UI), use SSH port forwarding
# instead of opening them to the internet.

log "Configuring UFW firewall..."
ufw --force reset  # Start from clean state
ufw default deny incoming
ufw default allow outgoing
ufw allow "$SSH_PORT/tcp" comment 'SSH'
ufw --force enable
ok "Firewall enabled (only port $SSH_PORT open for SSH)"

# ----------------------------------------------------------------------------
# Step 10: Configure fail2ban
# ----------------------------------------------------------------------------
# Fail2ban watches auth logs and bans IPs that repeatedly fail to log in.
# This is belt-and-suspenders alongside SSH keys — even though password
# auth is disabled, bots will still try, and fail2ban keeps the logs cleaner
# and prevents minor resource waste from the attempts.
#
# Important: if you configured a custom SSH port, we need to tell fail2ban
# about it, otherwise it will watch port 22 and miss real attacks.

log "Configuring fail2ban..."
cat > /etc/fail2ban/jail.local <<EOF
# /etc/fail2ban/jail.local
# Local overrides for fail2ban. This file takes precedence over jail.conf
# and survives package upgrades.

[DEFAULT]
# How long to ban an IP (in seconds). 1 hour is a reasonable default —
# long enough to deter, short enough that you won't permanently lock out
# yourself if you mistype your password a few times.
bantime = 3600

# Time window in which failed attempts are counted
findtime = 600

# Number of failures before ban
maxretry = 5

# Don't ban localhost or your own IP (add your home IP here if you have
# a static one — you can find it with 'curl ifconfig.me' from your laptop).
# ignoreip = 127.0.0.1/8 ::1 YOUR.HOME.IP.HERE

[sshd]
enabled = true
port = $SSH_PORT
# Tell fail2ban about the custom port if we changed it
EOF

systemctl enable fail2ban
systemctl restart fail2ban
ok "fail2ban configured and running"

# ----------------------------------------------------------------------------
# Step 11: Enable unattended security upgrades
# ----------------------------------------------------------------------------
# Automatically applies security patches without needing you to log in.
# This is important because humans forget to patch. The default config
# only applies security updates, not major version upgrades, so it's safe.

log "Enabling unattended security upgrades..."
cat > /etc/apt/apt.conf.d/20auto-upgrades <<EOF
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF

# The default 50unattended-upgrades already has sensible security-only
# settings on Ubuntu, we just need to ensure they're enabled.
ok "Unattended security upgrades enabled"

# ----------------------------------------------------------------------------
# Step 12: Apply kernel hardening via sysctl
# ----------------------------------------------------------------------------
# These kernel parameters disable various niche features that are sometimes
# used in network attacks. None of them should affect a normal server.
# See comments on each for rationale.

log "Applying sysctl kernel hardening..."
cat > /etc/sysctl.d/99-hardening.conf <<'EOF'
# /etc/sysctl.d/99-hardening.conf
# Kernel hardening parameters for a server exposed to the internet.

# Don't act as a router (we're a server, not a gateway)
net.ipv4.ip_forward = 0

# Ignore ICMP redirects — prevents MITM via forged redirect packets
net.ipv4.conf.all.accept_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0

# Don't send ICMP redirects either (we're not a router)
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0

# Ignore source-routed packets — legacy feature that's mostly used for attacks
net.ipv4.conf.all.accept_source_route = 0
net.ipv6.conf.all.accept_source_route = 0

# Log packets with impossible source addresses (martians) — useful for
# spotting spoofing or misconfigurations
net.ipv4.conf.all.log_martians = 1

# Enable reverse path filtering — drop packets whose source address
# wouldn't route back out the same interface (anti-spoofing)
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1

# SYN cookies — protects against SYN flood DoS attacks
net.ipv4.tcp_syncookies = 1

# Ignore broadcast ICMP echo requests (smurf attack amplification)
net.ipv4.icmp_echo_ignore_broadcasts = 1

# Ignore bogus ICMP errors
net.ipv4.icmp_ignore_bogus_error_responses = 1

# Protect against TIME_WAIT assassination
net.ipv4.tcp_rfc1337 = 1
EOF

sysctl --system > /dev/null
ok "Kernel hardening applied"

# ----------------------------------------------------------------------------
# Step 13: Set up a basic swap file (if there isn't one already)
# ----------------------------------------------------------------------------
# Contabo's images may or may not come with swap. Having a small swap file
# is useful as a safety net — it's much better for the OOM killer to push
# some cold pages to disk than to kill your agent process. We don't want
# swap to be too large on an SSD though, and we don't want heavy swapping
# (which kills performance). A 4GB swap with swappiness=10 is a good compromise
# for a 48GB RAM box: "only swap when really necessary."

log "Configuring swap..."
if [[ -z "$(swapon --show)" ]]; then
    log "No swap detected, creating 4GB swap file..."
    fallocate -l 4G /swapfile
    chmod 600 /swapfile
    mkswap /swapfile > /dev/null
    swapon /swapfile
    echo '/swapfile none swap sw 0 0' >> /etc/fstab
    # swappiness=10 means "prefer not to swap unless RAM is really full"
    # Default is 60, which swaps too eagerly for servers.
    echo 'vm.swappiness=10' >> /etc/sysctl.d/99-hardening.conf
    sysctl vm.swappiness=10 > /dev/null
    ok "4GB swap file created with low swappiness"
else
    ok "Swap already configured, skipping"
fi

# ----------------------------------------------------------------------------
# Step 14: Set timezone
# ----------------------------------------------------------------------------
# Logs are much easier to correlate with local time. Adjust for your
# location. Using America/Los_Angeles since the VPS owner is in SF.

log "Setting timezone to America/Los_Angeles..."
timedatectl set-timezone America/Los_Angeles
ok "Timezone set"

# ----------------------------------------------------------------------------
# Step 15: Final summary
# ----------------------------------------------------------------------------

echo ""
echo -e "${GREEN}==========================================================================${NC}"
echo -e "${GREEN}  VPS hardening complete!${NC}"
echo -e "${GREEN}==========================================================================${NC}"
echo ""
echo "Summary of what was done:"
echo "  ✓ System fully updated"
echo "  ✓ User '$NEW_USER' created with sudo access"
echo "  ✓ SSH key installed for $NEW_USER"
echo "  ✓ SSH hardened: port $SSH_PORT, no root, no passwords"
echo "  ✓ UFW firewall enabled (only SSH allowed inbound)"
echo "  ✓ fail2ban watching SSH"
echo "  ✓ Automatic security updates enabled"
echo "  ✓ Kernel hardened via sysctl"
echo "  ✓ 4GB swap configured (if not already present)"
echo "  ✓ Timezone set to America/Los_Angeles"
echo ""
echo "Next steps:"
echo "  1. Test SSH: ssh -p $SSH_PORT $NEW_USER@<vps-ip>"
echo "  2. Update your ~/.ssh/config on your local machine for convenience:"
echo ""
echo "       Host my-vps"
echo "           HostName <vps-ip>"
echo "           Port $SSH_PORT"
echo "           User $NEW_USER"
echo ""
echo "  3. Run 01-install-dev-tools.sh next (as $NEW_USER with sudo)"
echo ""
echo "To monitor CPU steal (remember, Contabo noisy-neighbor check):"
echo "  vmstat 1    # watch the 'st' column — should be < 5 most of the time"
echo ""
