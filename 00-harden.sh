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
#   3. Sets up SSH key authentication
#   4. Enrolls the new user in TOTP (2FA) so password+TOTP is also accepted —
#      lets you SSH from devices without your key (phone, friend's laptop)
#   5. Disables root login; configures sshd to accept EITHER pubkey OR
#      password+TOTP (via AuthenticationMethods)
#   6. Configures UFW firewall (deny-by-default is the only sane policy)
#   7. Installs fail2ban (auto-bans brute-force attempts)
#   8. Enables unattended security upgrades
#   9. Applies sysctl kernel hardening
#  10. Installs basic monitoring tools (htop, iotop, vmstat, etc.)
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
#   This script will disable root SSH and enable a two-track auth model
#   (pubkey OR password+TOTP). Before it restarts sshd, it will ask you to
#   confirm you can log in as the new user with your key from a SECOND
#   terminal. Do NOT skip this check or you may lock yourself out. If you
#   do get locked out, Contabo provides a web-based VNC console in their
#   control panel as a recovery option.
#
#   For TOTP you'll need an authenticator app (Authy, 1Password, Bitwarden,
#   Microsoft Authenticator, Google Authenticator — any RFC 6238 client).
#   The script prints a QR code at enrollment time; scan it with your app.

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

get_ssh_service_name() {
    # Debian/Ubuntu commonly expose OpenSSH as ssh.service, while other
    # distros often use sshd.service. Detect what's actually present instead
    # of hard-coding one unit name and aborting mid-hardening.
    if command -v systemctl &>/dev/null; then
        if systemctl list-unit-files --type=service --no-legend 2>/dev/null | awk '{print $1}' | grep -qx 'ssh.service'; then
            echo "ssh"
            return 0
        fi
        if systemctl list-unit-files --type=service --no-legend 2>/dev/null | awk '{print $1}' | grep -qx 'sshd.service'; then
            echo "sshd"
            return 0
        fi
    fi

    if command -v service &>/dev/null; then
        if service ssh status >/dev/null 2>&1; then
            echo "ssh"
            return 0
        fi
        if service sshd status >/dev/null 2>&1; then
            echo "sshd"
            return 0
        fi
    fi

    error "Could not determine the SSH service name (tried ssh and sshd)."
    return 1
}
# end get_ssh_service_name

restart_ssh_service() {
    local ssh_service_name=""

    ssh_service_name="$(get_ssh_service_name)" || return 1

    if command -v systemctl &>/dev/null; then
        systemctl restart "$ssh_service_name"
        return 0
    fi

    if command -v service &>/dev/null; then
        service "$ssh_service_name" restart
        return 0
    fi

    error "Could not restart the SSH service."
    return 1
}
# end restart_ssh_service

get_ssh_socket_port() {
    local listen_stream=""

    if ! ssh_socket_is_active || ! command -v systemctl &>/dev/null; then
        return 1
    fi

    listen_stream="$(systemctl cat ssh.socket 2>/dev/null | awk -F= '/^ListenStream=/ { print $2; exit }')"
    if [[ -z "$listen_stream" ]]; then
        return 1
    fi

    if [[ "$listen_stream" == *']:'* ]]; then
        listen_stream="${listen_stream##*]:}"
    elif [[ "$listen_stream" == *:* ]]; then
        listen_stream="${listen_stream##*:}"
    fi

    if [[ "$listen_stream" =~ ^[0-9]+$ ]]; then
        echo "$listen_stream"
        return 0
    fi

    return 1
}
# end get_ssh_socket_port

get_current_ssh_port() {
    local managed_dropin="/etc/ssh/sshd_config.d/00-vps-setup-hardening.conf"
    local port=""

    if port="$(get_ssh_socket_port)"; then
        echo "$port"
        return 0
    fi

    if [[ -f "$managed_dropin" ]]; then
        port="$(awk '$1 == "Port" { print $2; exit }' "$managed_dropin")"
        if [[ -n "$port" ]]; then
            echo "$port"
            return 0
        fi
    fi

    if command -v sshd &>/dev/null; then
        port="$(sshd -T 2>/dev/null | awk '$1 == "port" { print $2; exit }')"
        if [[ -n "$port" ]]; then
            echo "$port"
            return 0
        fi
    fi

    echo "22"
}
# end get_current_ssh_port

build_ssh_login_command() {
    local user="$1"
    local host="$2"
    local port="$3"

    if [[ "$port" == "22" ]]; then
        echo "ssh ${user}@${host}"
    else
        echo "ssh -p ${port} ${user}@${host}"
    fi
}
# end build_ssh_login_command

ufw_is_active() {
    command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q '^Status: active$'
}
# end ufw_is_active

prepare_ufw_for_ssh_port_change() {
    local current_port="$1"
    local desired_port="$2"

    if [[ "$current_port" == "$desired_port" ]] || ! ufw_is_active; then
        return 0
    fi

    log "UFW is already active. Allowing new SSH port ${desired_port}/tcp before reloading SSH."
    log "Keeping ${current_port}/tcp open until you confirm the new port works."
    ufw allow "${desired_port}/tcp" comment 'SSH'
}
# end prepare_ufw_for_ssh_port_change

remove_old_ufw_rule_for_ssh_port_change() {
    local old_port="$1"
    local current_port="$2"

    if [[ "$old_port" == "$current_port" ]] || ! ufw_is_active; then
        return 0
    fi

    if ufw --force delete allow "${old_port}/tcp" >/dev/null 2>&1; then
        ok "Removed old UFW rule for ${old_port}/tcp"
    else
        warn "Could not remove old UFW rule for ${old_port}/tcp automatically"
        warn "Delete it manually later with: ufw delete allow ${old_port}/tcp"
    fi
}
# end remove_old_ufw_rule_for_ssh_port_change

ssh_socket_is_active() {
    command -v systemctl &>/dev/null && systemctl is-active --quiet ssh.socket
}
# end ssh_socket_is_active

prepare_ssh_activation_for_port_change() {
    local current_port="$1"
    local desired_port="$2"
    local ssh_service_name=""

    if [[ "$current_port" == "$desired_port" ]] || ! ssh_socket_is_active; then
        return 0
    fi

    ssh_service_name="$(get_ssh_service_name)" || return 1

    log "ssh.socket is active. Switching to ${ssh_service_name}.service before moving SSH to port ${desired_port}."

    if ! systemctl disable --now ssh.socket; then
        error "Failed to disable ssh.socket before changing the SSH port."
        return 1
    fi

    if ! systemctl enable --now "$ssh_service_name"; then
        error "Failed to enable ${ssh_service_name}.service after disabling ssh.socket."
        error "Re-enabling ssh.socket to preserve the existing listener."
        systemctl enable --now ssh.socket >/dev/null 2>&1 || true
        return 1
    fi

    if ! systemctl is-active --quiet "$ssh_service_name"; then
        error "${ssh_service_name}.service is not active after switching away from ssh.socket."
        error "Re-enabling ssh.socket to preserve the existing listener."
        systemctl enable --now ssh.socket >/dev/null 2>&1 || true
        return 1
    fi

    ok "Switched SSH from socket activation to ${ssh_service_name}.service"
}
# end prepare_ssh_activation_for_port_change

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
#   - libpam-google-authenticator: PAM module implementing TOTP (RFC 6238).
#     Works with any standard authenticator app (Authy, 1Password, Bitwarden,
#     Microsoft Authenticator, etc.) — the "google" in the name is historical.
#   - qrencode: lets google-authenticator print a scannable QR code in-terminal

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
    software-properties-common \
    libpam-google-authenticator \
    qrencode
ok "Packages installed"

CURRENT_SSH_PORT="$(get_current_ssh_port)"
SSH_HOST_IP="$(hostname -I | awk '{print $1}')"
PORT_CHANGE_REQUESTED=0
KEEP_OLD_SSH_UFW_RULE=0

if [[ "$CURRENT_SSH_PORT" != "$SSH_PORT" ]]; then
    PORT_CHANGE_REQUESTED=1
fi

if ufw_is_active; then
    UFW_WAS_ACTIVE=1
else
    UFW_WAS_ACTIVE=0
fi

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
    # --disabled-password: no password set initially — we'll set one below.
    # --gecos "": skip the full-name/phone/etc. prompts
    adduser --disabled-password --gecos "" "$NEW_USER"
    ok "User created"
fi

# Add user to sudo group. On Debian/Ubuntu this grants full sudo access.
usermod -aG sudo "$NEW_USER"
ok "Added $NEW_USER to sudo group"

# ----------------------------------------------------------------------------
# Step 4b: Set a UNIX password for the new user
# ----------------------------------------------------------------------------
# We MUST set a password here even though SSH will only use keys. Reason:
# sudo on Ubuntu/Debian requires a password by default (defense-in-depth —
# if someone gets into the account, they still need the password to escalate).
# Later scripts (01-install-dev-tools.sh) run `sudo -v` which would fail with
# 'account locked' on a --disabled-password user.
#
# If the account already has a usable password set (e.g. on script re-run),
# we skip the prompt. Detected via `passwd -S`: status field 'P' means a
# valid password is set; 'L' is locked, 'NP' is no password.

PASSWD_STATUS=$(passwd -S "$NEW_USER" 2>/dev/null | awk '{print $2}' || echo "NP")

if [[ "$PASSWD_STATUS" == "P" ]]; then
    ok "User $NEW_USER already has a password set — skipping"
else
    echo ""
    log "Set a UNIX password for $NEW_USER (used by sudo; SSH still uses keys only)"

    # Loop until we get two matching non-empty entries. Use -s to suppress
    # echo. We pipe to chpasswd (faster/quieter than passwd's interactive
    # prompt, and doesn't require TTY tricks).
    while true; do
        read -rsp "Password: " USER_PASSWORD; echo ""
        read -rsp "Confirm:  " USER_PASSWORD_CONFIRM; echo ""
        if [[ -z "$USER_PASSWORD" ]]; then
            error "Password cannot be empty — try again"
            continue
        fi
        if [[ "$USER_PASSWORD" != "$USER_PASSWORD_CONFIRM" ]]; then
            error "Passwords don't match — try again"
            continue
        fi
        break
    done

    echo "$NEW_USER:$USER_PASSWORD" | chpasswd
    # Wipe the plaintext from env as soon as it's set — defense in depth.
    unset USER_PASSWORD USER_PASSWORD_CONFIRM
    ok "Password set for $NEW_USER"
fi

# ----------------------------------------------------------------------------
# Step 5: Set up SSH key for the new user
# ----------------------------------------------------------------------------
# SSH keys are vastly more secure than passwords — they can't be
# brute-forced in any practical sense, and they can't be phished the same way.
# We set up the .ssh directory with the correct restrictive permissions
# that sshd requires (it will refuse to use the key if perms are too loose).

log "Setting up SSH key for $NEW_USER..."
USER_HOME="/home/$NEW_USER"
AUTH_KEYS="$USER_HOME/.ssh/authorized_keys"
mkdir -p "$USER_HOME/.ssh"
touch "$AUTH_KEYS"

# Append-if-missing rather than overwrite. Overwriting would silently wipe
# any other keys the user (or a previous run of this script with a different
# public key) had added. grep -qxF matches the full line literally, so
# trailing comments or whitespace don't accidentally mask a real match.
if grep -qxF "$SSH_PUBKEY" "$AUTH_KEYS"; then
    warn "SSH key already present in authorized_keys — skipping"
else
    echo "$SSH_PUBKEY" >> "$AUTH_KEYS"
    ok "SSH key appended to authorized_keys"
fi

# 700 on .ssh dir, 600 on authorized_keys — sshd requires these exact perms
# or it will silently refuse to use the key and fall back to password auth
# (which we're about to disable, so you'd be locked out).
chmod 700 "$USER_HOME/.ssh"
chmod 600 "$AUTH_KEYS"
chown -R "$NEW_USER:$NEW_USER" "$USER_HOME/.ssh"
ok "SSH key installed for $NEW_USER"

# ----------------------------------------------------------------------------
# Step 5b: Enroll TOTP (2FA) for password-based SSH
# ----------------------------------------------------------------------------
# We configure sshd below to accept EITHER a valid key OR password+TOTP.
# Keys are the primary auth path (fast, non-interactive, used by automation).
# Password+TOTP is the backup path — handy when you need to SSH from a device
# that doesn't have your key (phone, friend's laptop, etc.).
#
# Enrollment runs `google-authenticator` as the new user. The tool writes a
# secret to ~/.google_authenticator and prints a QR code; scan it with any
# RFC 6238 authenticator (Authy, 1Password, Bitwarden, MS Authenticator,
# Google Authenticator). Flags used:
#   --time-based        TOTP (not HOTP counter-based)
#   --disallow-reuse    each 6-digit code usable only once
#   --force             overwrite existing secret file non-interactively
#   --rate-limit=3      --rate-time=30: throttle brute-force (3 tries / 30s)
#   --window-size=3     accept codes from ±1 step (±30s) to tolerate clock skew
#   --qr-mode=ANSI      print QR directly in the terminal
#
# Idempotency: if ~/.google_authenticator already exists, we skip re-enrollment
# so reruns don't invalidate the user's current enrollment (which would break
# any logged-in sessions relying on it).

TOTP_FILE="$USER_HOME/.google_authenticator"
if [[ -s "$TOTP_FILE" ]]; then
    ok "TOTP already enrolled for $NEW_USER — skipping (delete $TOTP_FILE to re-enroll)"
else
    echo ""
    warn "=========================================================================="
    warn "TOTP enrollment for $NEW_USER"
    warn ""
    warn "A QR code will print below. Scan it with an authenticator app:"
    warn "  - Authy, 1Password, Bitwarden, Microsoft Authenticator, or Google Authenticator"
    warn ""
    warn "The app will start generating 6-digit codes that rotate every 30 seconds."
    warn "You'll enter one on SSH login (in addition to your password) when you"
    warn "don't have your SSH key handy. Also: save the printed emergency scratch"
    warn "codes somewhere safe (password manager). They're your recovery path if"
    warn "you lose the authenticator app."
    warn "=========================================================================="
    echo ""

    sudo -u "$NEW_USER" google-authenticator \
        --time-based \
        --disallow-reuse \
        --force \
        --rate-limit=3 \
        --rate-time=30 \
        --window-size=3 \
        --qr-mode=ANSI

    chmod 600 "$TOTP_FILE"
    chown "$NEW_USER:$NEW_USER" "$TOTP_FILE"
    ok "TOTP enrolled for $NEW_USER"
fi

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
warn "    $(build_ssh_login_command "$NEW_USER" "$SSH_HOST_IP" "$CURRENT_SSH_PORT")"
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
# These changes dramatically reduce SSH attack surface while supporting a
# dual-track auth model (pubkey OR password+TOTP):
#
#   - PermitRootLogin no: root can't SSH in at all (must use sudo from user)
#   - PasswordAuthentication no: the legacy password-only code path is off —
#     passwords are accepted only through keyboard-interactive/PAM, which is
#     where we layer TOTP on top.
#   - KbdInteractiveAuthentication yes: enables the PAM-backed interactive
#     auth path (password + TOTP prompt).
#   - UsePAM yes: required for keyboard-interactive to go through PAM, which
#     is where pam_google_authenticator.so runs.
#   - PubkeyAuthentication yes: explicitly enable keys.
#   - AuthenticationMethods "publickey keyboard-interactive:pam":
#     SPACE-separated means "any of these methods works" (OR). Key users
#     skip TOTP entirely; password-only users go through PAM, which requires
#     password (via @include common-auth) AND TOTP (via pam_google_authenticator).
#     That's 2FA by construction for the password path.
#   - MaxAuthTries 3: drop connection after 3 failed attempts
#   - ClientAliveInterval/CountMax: disconnect idle sessions after ~10 min
#     (prevents dangling sessions from being hijacked)
#   - X11Forwarding no: we're not running GUIs, don't enable this attack surface
#   - Port: optionally move off 22 to reduce bot noise in logs

log "Hardening SSH configuration..."
SSH_CONFIG="/etc/ssh/sshd_config"
SSH_DROPIN_DIR="/etc/ssh/sshd_config.d"
SSH_DROPIN="$SSH_DROPIN_DIR/00-vps-setup-hardening.conf"

# On modern Ubuntu/Debian images, sshd_config often includes
# /etc/ssh/sshd_config.d/* near the top and OpenSSH keeps the FIRST value it
# sees for single-value options. That means appending settings to the end of
# sshd_config can silently lose to an earlier cloud-init drop-in.
#
# Fix: manage our policy in an early-numbered drop-in so our values are read
# during the Include pass and win over later defaults in sshd_config itself.
mkdir -p "$SSH_DROPIN_DIR"

# Back up the files we own or depend on before replacing them.
cp "$SSH_CONFIG" "${SSH_CONFIG}.backup.$(date +%Y%m%d-%H%M%S)"
[[ -f "$SSH_DROPIN" ]] && cp "$SSH_DROPIN" "${SSH_DROPIN}.backup.$(date +%Y%m%d-%H%M%S)"

cat > "$SSH_DROPIN" <<EOF
# Managed by 00-harden.sh
# See /etc/ssh/sshd_config for the base config and distro defaults.

Port $SSH_PORT
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication yes
UsePAM yes
PubkeyAuthentication yes
PermitEmptyPasswords no
X11Forwarding no
MaxAuthTries 3
ClientAliveInterval 300
ClientAliveCountMax 2
AllowUsers $NEW_USER
AuthenticationMethods publickey keyboard-interactive:pam
EOF

# ----------------------------------------------------------------------------
# Step 8b: Configure PAM to require TOTP on the keyboard-interactive path
# ----------------------------------------------------------------------------
# /etc/pam.d/sshd is Ubuntu's PAM stack for sshd logins. It ships with
# '@include common-auth' near the top (handles UNIX password). We append
# pam_google_authenticator.so AFTER common-auth so the user must:
#   1. Enter their UNIX password (common-auth succeeds)
#   2. Then enter their current TOTP code (pam_google_authenticator succeeds)
# Both must pass for keyboard-interactive auth to succeed.
#
# We add a marker comment so reruns can detect and skip the edit idempotently.

log "Configuring PAM for TOTP on sshd..."
PAM_SSHD="/etc/pam.d/sshd"
PAM_MARKER="# Added by 00-harden.sh: TOTP required on keyboard-interactive path"

if grep -qF "$PAM_MARKER" "$PAM_SSHD"; then
    ok "TOTP already configured in $PAM_SSHD — skipping"
else
    cp "$PAM_SSHD" "${PAM_SSHD}.backup.$(date +%Y%m%d-%H%M%S)"
    # Insert after the '@include common-auth' line. 'nullok' would let users
    # without ~/.google_authenticator pass — we want the opposite: if you
    # didn't enroll, you can't use the password path. So: no nullok.
    sed -i "/^@include common-auth/a ${PAM_MARKER}\nauth required pam_google_authenticator.so" "$PAM_SSHD"
    ok "TOTP required on keyboard-interactive SSH (PAM configured)"
fi

# Validate the sshd config before reloading — if there's a syntax error,
# sshd will fail to start and you'll be locked out.
if ! sshd -t; then
    error "SSH config validation failed! Not restarting sshd. Restore from backup:"
    error "  cp ${SSH_CONFIG}.backup.* $SSH_CONFIG"
    exit 1
fi

if [[ "$PORT_CHANGE_REQUESTED" -eq 1 && "$UFW_WAS_ACTIVE" -eq 1 ]]; then
    prepare_ufw_for_ssh_port_change "$CURRENT_SSH_PORT" "$SSH_PORT"
    KEEP_OLD_SSH_UFW_RULE=1
fi

if [[ "$PORT_CHANGE_REQUESTED" -eq 1 ]]; then
    prepare_ssh_activation_for_port_change "$CURRENT_SSH_PORT" "$SSH_PORT" || exit 1
fi

restart_ssh_service || exit 1
ok "SSH hardened (port $SSH_PORT, root disabled, pubkey-or-password+TOTP)"

echo ""
warn "=========================================================================="
warn "CRITICAL: Before continuing, verify key-based SSH works on the configured port:"
warn ""
warn "    $(build_ssh_login_command "$NEW_USER" "$SSH_HOST_IP" "$SSH_PORT")"
warn ""
warn "Do this from a NEW terminal window and keep this current session open."
warn "If it does NOT work, answer 'n' below and recover before touching firewall cleanup."
warn "=========================================================================="
echo ""
read -rp "Have you verified SSH key login as $NEW_USER works on port $SSH_PORT? [y/N] " POST_RESTART_VERIFIED
if [[ "$POST_RESTART_VERIFIED" != "y" && "$POST_RESTART_VERIFIED" != "Y" ]]; then
    error "Aborting before continuing. Keep this session open and recover SSH access first."
    error "If UFW was already active, the old SSH firewall rule has been left in place."
    exit 1
fi

# ----------------------------------------------------------------------------
# Step 8c: Second verification gate — password+TOTP path
# ----------------------------------------------------------------------------
# The earlier gate (Step 7) only verified the pubkey path. If password+TOTP
# is misconfigured (wrong PAM stack, wrong ~/.google_authenticator perms,
# authenticator-app clock skew, etc.), the user won't find out until they
# try to log in from a device without their key — usually at the worst
# possible moment. Verify now while we still have a root terminal open.
#
# This gate is NOT fatal: if the user skips it, the pubkey path still works
# and they can debug TOTP later. But strongly encouraged.

echo ""
warn "=========================================================================="
warn "OPTIONAL: Verify password+TOTP login works"
warn ""
warn "From a NEW terminal window, try:"
warn ""
warn "    ssh -o PreferredAuthentications=keyboard-interactive \\"
warn "        -o PubkeyAuthentication=no \\"
warn "        -p $SSH_PORT $NEW_USER@$(hostname -I | awk '{print $1}')"
warn ""
warn "You should be prompted for: (1) your UNIX password, (2) a 6-digit TOTP code."
warn ""
warn "Important: this test forces the password+TOTP path only."
warn "Three bad attempts within 30 seconds will temporarily rate-limit that path."
warn "That does NOT disable normal SSH key login on the standard path."
warn ""
warn "If this fails, your pubkey path still works — but you'll want to fix TOTP"
warn "before you need it from a keyless device. Common causes:"
warn "  - Clock skew on the authenticator app (enable time-sync in app settings)"
warn "  - Wrong password (reset with: sudo passwd $NEW_USER)"
warn "  - QR not scanned correctly (re-enroll: rm $TOTP_FILE and rerun this script)"
warn "=========================================================================="
echo ""
read -rp "Verified password+TOTP (or skipping)? [y/N] " TOTP_VERIFIED
if [[ "$TOTP_VERIFIED" != "y" && "$TOTP_VERIFIED" != "Y" ]]; then
    warn "Skipped password+TOTP verification. Pubkey path still works."
fi

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
# Additive, not destructive. 'ufw --force reset' wipes ALL rules — including
# any you've added manually later. Re-running 00 would silently undo that.
#
# Instead: set defaults (idempotent), allow our SSH port (idempotent — ufw
# deduplicates), and enable. Existing rules are preserved.
ufw default deny incoming
ufw default allow outgoing
ufw allow "$SSH_PORT/tcp" comment 'SSH'
# --force enable skips the interactive "are you sure" prompt. ufw is fine
# with this being called on an already-enabled firewall.
ufw --force enable
ok "Firewall enabled (port $SSH_PORT open for SSH; existing rules preserved)"

if [[ "$KEEP_OLD_SSH_UFW_RULE" -eq 1 ]]; then
    echo ""
    read -rp "SSH on port $SSH_PORT works. Remove the old UFW rule for port $CURRENT_SSH_PORT now? [y/N] " REMOVE_OLD_UFW_RULE
    if [[ "$REMOVE_OLD_UFW_RULE" == "y" || "$REMOVE_OLD_UFW_RULE" == "Y" ]]; then
        remove_old_ufw_rule_for_ssh_port_change "$CURRENT_SSH_PORT" "$SSH_PORT"
    else
        warn "Keeping old SSH firewall rule for $CURRENT_SSH_PORT/tcp in place for now."
        warn "Delete it later with: ufw --force delete allow ${CURRENT_SSH_PORT}/tcp"
    fi
fi

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
echo "  ✓ TOTP (2FA) enrolled for $NEW_USER — secret at ~/.google_authenticator"
echo "  ✓ SSH hardened: port $SSH_PORT, no root, pubkey-or-password+TOTP"
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
