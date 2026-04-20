# `00-harden.sh` — Initial VPS hardening

**Run as:** `root`, once, on a fresh VPS.
**Goal:** turn a default Contabo/Ubuntu image into a non-embarrassing SSH box before it sits on the public internet for longer than necessary. Sets up a dual-track auth model: SSH keys (primary) OR password+TOTP (backup, for devices without your key).

## Auth model at a glance

`sshd_config` carries `AuthenticationMethods publickey keyboard-interactive:pam`. Space-separated means OR — any single entry is sufficient:

- **Pubkey path:** present a valid key → in. Fast, non-interactive, used by scp/rsync/automation. No password, no TOTP.
- **Password+TOTP path:** key not available → keyboard-interactive kicks in → PAM runs `@include common-auth` (UNIX password) then `pam_google_authenticator.so` (6-digit TOTP). Both must succeed. That's 2FA on the password path by construction.

`PasswordAuthentication no` disables the legacy password-only code path so a plain password (without TOTP) is never accepted. TOTP uses RFC 6238 — any standard authenticator works (Authy, 1Password, Bitwarden, Microsoft Authenticator, Google Authenticator).

## What it does in detail

The script is a top-to-bottom walk through "bare minimum hardening for a personal server exposed to the internet." It runs these steps in order:

1. **Pre-flight.** Refuses to run unless `$EUID == 0` (needs to write system files, create users, manage services). Sets `set -euo pipefail` so any unexpected error aborts — hardening half-applied is worse than not applied.
2. **Gathers input upfront.** Prompts for the new username, the user's SSH public key (validated to start with `ssh-ed25519`, `ssh-rsa`, or `ecdsa-sha2`), and an optional custom SSH port. Also asks for a password (step 4b below). Collecting all input at the top means the rest of the script runs unattended — you can go make coffee.
3. **System update.** `apt-get update && apt-get upgrade` with `DEBIAN_FRONTEND=noninteractive` to suppress the "keep current config or use maintainer's?" prompts that will otherwise hang the script.
4. **Installs baseline packages:** `ufw`, `fail2ban`, `unattended-upgrades`, `apt-listchanges`, `libpam-google-authenticator`, `qrencode`, plus utilities (`htop`, `iotop`, `sysstat`, `curl`, `wget`, `rsync`, `git`, `ca-certificates`, `gnupg`, `software-properties-common`). `libpam-google-authenticator` is the PAM module that implements TOTP; "google" in the name is historical — it speaks standard RFC 6238 and works with any authenticator app.
5. **Creates the non-root user** (`adduser --disabled-password --gecos ""`) and adds them to the `sudo` group. Working as root is dangerous; `sudo` forces conscious escalation.
6. **Step 4b: sets a UNIX password for that user.** Required for both `sudo` and the password+TOTP SSH path. Uses `passwd -S` to detect an already-set password on reruns and skips the prompt if so. Loops until the user provides two matching non-empty entries, then pipes through `chpasswd`.
7. **Installs the SSH public key** into `/home/<user>/.ssh/authorized_keys`. Key behaviour: append-if-missing (using `grep -qxF`) rather than overwrite — overwriting silently wipes any other keys the user previously added. Sets perms to the exact values `sshd` insists on (`.ssh` = 700, `authorized_keys` = 600), or it will silently ignore the file.
8. **Step 5b: enrolls TOTP for the new user.** Runs `sudo -u <user> google-authenticator --time-based --disallow-reuse --force --rate-limit=3 --rate-time=30 --window-size=3 --qr-mode=ANSI`. This writes `~/.google_authenticator` and prints a QR code + emergency scratch codes. User scans the QR with their authenticator app, saves the scratch codes in a password manager. Idempotent: if `~/.google_authenticator` already exists, the step is skipped (re-enrollment would invalidate an already-configured app).
9. **Stop-and-verify gate (pubkey path).** Prints a big warning and asks the user to confirm (in a second terminal) that they can SSH in as the new user with their key, *before* the script disables root login and changes sshd. On reruns, this uses the SSH port currently configured on the host rather than blindly assuming port 22. Skipping this is how people lock themselves out.
10. **Hardens sshd.** Backs up `/etc/ssh/sshd_config` with a timestamp, then writes its policy into `/etc/ssh/sshd_config.d/00-vps-setup-hardening.conf`. Settings applied: custom `Port`, `PermitRootLogin no`, `PasswordAuthentication no`, `KbdInteractiveAuthentication yes`, `UsePAM yes`, `PubkeyAuthentication yes`, `PermitEmptyPasswords no`, `X11Forwarding no`, `MaxAuthTries 3`, `ClientAliveInterval 300` / `ClientAliveCountMax 2`, `AllowUsers <new-user>`, `AuthenticationMethods "publickey keyboard-interactive:pam"`.
11. **Step 8b: configures PAM for TOTP.** Edits `/etc/pam.d/sshd` to append `auth required pam_google_authenticator.so` immediately after the existing `@include common-auth` line. Order matters: common-auth runs first (password check) then the TOTP module (code check). A marker comment makes the edit idempotent — reruns detect it and skip. The original `/etc/pam.d/sshd` is backed up with a timestamp before modification. No `nullok` flag, on purpose: if the user never enrolled TOTP, their keyboard-interactive path refuses login rather than quietly falling back to password-only.
12. **Validates sshd, pre-opens the new firewall port if needed, then restarts.** `sshd -t` before touching the live service. If UFW is already active and the SSH port is changing on a rerun, the script first allows the *new* port and deliberately leaves the *old* port open until the new one is verified. It also detects whether this host exposes OpenSSH as `ssh.service` or `sshd.service` and restarts the one that actually exists. If validation fails we abort without restarting, so the existing session keeps working while you fix it.
13. **Post-restart key-login verify gate.** After sshd restarts, the script pauses again and requires you to verify a fresh key-based login on the configured port from a second terminal before it continues. If that check fails, the script stops and leaves any previously-open SSH firewall rule in place.
14. **Step 8c: second verify gate (password+TOTP path).** Optional but strongly encouraged. Prints an `ssh` command with `PreferredAuthentications=keyboard-interactive` and `PubkeyAuthentication=no` that forces the password+TOTP path. The prompt now explicitly warns that three bad attempts within 30 seconds will temporarily rate-limit that path, but that this does **not** disable normal key-based SSH. If the user confirms it worked, great; if they skip, the pubkey path still works and they can debug TOTP later. Non-fatal.
15. **Configures UFW.** Sets `default deny incoming` / `default allow outgoing`, opens the chosen SSH port with a comment, then `ufw --force enable`. Deliberately additive — no `ufw --force reset` — so any rules you add later survive a rerun of 00. If the script had to keep an old SSH port open during a port migration, it prompts you after the firewall step to remove that old rule only after you've confirmed the new port works.
16. **Configures fail2ban.** Writes `/etc/fail2ban/jail.local` with a `[DEFAULT]` section (`bantime=3600`, `findtime=600`, `maxretry=5`) and an `[sshd]` section that points at the custom port. Uses `jail.local` (not `jail.conf`) because `jail.conf` is owned by the package and gets overwritten on upgrade.
17. **Enables unattended security upgrades.** Writes `/etc/apt/apt.conf.d/20auto-upgrades` — that plus the default `50unattended-upgrades` shipped by Ubuntu is enough to get security-only auto-patching.
18. **Applies kernel hardening.** Writes `/etc/sysctl.d/99-hardening.conf` with the sysctl knobs most often wrong on a stock image: disables IP forwarding, ICMP redirects (accept and send), source routing, enables reverse path filtering, SYN cookies, martian logging, ignores broadcast echoes, TIME_WAIT assassination protection. `sysctl --system` reloads.
19. **Swap file.** If `swapon --show` is empty, creates a 4 GB `/swapfile` (chmod 600, `mkswap`, `swapon`, add to `/etc/fstab`) and sets `vm.swappiness=10` so it's only used under real memory pressure rather than at the whim of the default `60`.
20. **Sets timezone** to `America/Los_Angeles` via `timedatectl`. Pure quality-of-life: log timestamps match wall time.
21. **Prints a summary** listing what was done and the next commands to run.

## Replicate manually (no script)

These are the equivalent commands in the same order. Run them as `root`.

```bash
# --- Pre-flight ---
export DEBIAN_FRONTEND=noninteractive

# --- Update ---
apt-get update && apt-get upgrade -y && apt-get autoremove -y

# --- Packages ---
apt-get install -y ufw fail2ban unattended-upgrades apt-listchanges \
    htop iotop sysstat curl wget rsync git ca-certificates gnupg \
    software-properties-common libpam-google-authenticator qrencode

# --- New user ---
NEW_USER=curtis
adduser --disabled-password --gecos "" "$NEW_USER"
usermod -aG sudo "$NEW_USER"

# --- Password (used for sudo AND password+TOTP SSH path) ---
passwd "$NEW_USER"    # interactive; enter a password you'll remember

# --- SSH key ---
mkdir -p /home/"$NEW_USER"/.ssh
# Append your public key (don't > redirect — that clobbers existing keys)
echo 'ssh-ed25519 AAAA... your@laptop' >> /home/"$NEW_USER"/.ssh/authorized_keys
chmod 700 /home/"$NEW_USER"/.ssh
chmod 600 /home/"$NEW_USER"/.ssh/authorized_keys
chown -R "$NEW_USER":"$NEW_USER" /home/"$NEW_USER"/.ssh

# --- Enroll TOTP for NEW_USER ---
# Prints a QR code to scan with Authy/1Password/Bitwarden/etc.
# Save the emergency scratch codes somewhere safe (password manager).
sudo -u "$NEW_USER" google-authenticator \
    --time-based --disallow-reuse --force \
    --rate-limit=3 --rate-time=30 --window-size=3 --qr-mode=ANSI

# --- VERIFY in a second terminal: ssh with key must work before continuing ---
# On reruns with a custom port already active, use that current port here.

# --- SSH hardening ---
SSH_PORT=22   # or your chosen port
cp /etc/ssh/sshd_config /etc/ssh/sshd_config.backup.$(date +%Y%m%d-%H%M%S)
# Edit /etc/ssh/sshd_config so it contains exactly (remove/comment conflicting lines):
cat >> /etc/ssh/sshd_config <<EOF
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

# --- Configure PAM for TOTP on keyboard-interactive ---
cp /etc/pam.d/sshd /etc/pam.d/sshd.backup.$(date +%Y%m%d-%H%M%S)
# Insert pam_google_authenticator right after @include common-auth.
# No 'nullok' — users without ~/.google_authenticator can't use password path.
sed -i '/^@include common-auth/a auth required pam_google_authenticator.so' /etc/pam.d/sshd

CURRENT_SSH_PORT="$(awk '$1 == "Port" { print $2; exit }' /etc/ssh/sshd_config.d/00-vps-setup-hardening.conf 2>/dev/null || true)"
CURRENT_SSH_PORT="${CURRENT_SSH_PORT:-22}"

if ufw status 2>/dev/null | grep -q '^Status: active$' && [[ "$CURRENT_SSH_PORT" != "$SSH_PORT" ]]; then
    ufw allow "$SSH_PORT"/tcp comment 'SSH'
    # Keep the old SSH port open until you've confirmed the new port works.
fi

sshd -t
if systemctl list-unit-files --type=service --no-legend 2>/dev/null | awk '{print $1}' | grep -qx 'ssh.service'; then
    systemctl restart ssh
elif systemctl list-unit-files --type=service --no-legend 2>/dev/null | awk '{print $1}' | grep -qx 'sshd.service'; then
    systemctl restart sshd
else
    service ssh restart || service sshd restart
fi

# --- VERIFY AGAIN: key-based SSH must work on the configured port ---
# ssh -p $SSH_PORT $NEW_USER@<vps-ip>

# --- Test password+TOTP path (from another terminal) ---
# ssh -o PreferredAuthentications=keyboard-interactive \
#     -o PubkeyAuthentication=no \
#     -p $SSH_PORT $NEW_USER@<vps-ip>
# Expect: password prompt, then 6-digit TOTP prompt.
# NOTE: three bad attempts in 30 seconds temporarily rate-limit the password+TOTP path,
# but that does not disable normal key-based SSH.

# --- UFW firewall ---
ufw default deny incoming
ufw default allow outgoing
ufw allow "$SSH_PORT"/tcp comment 'SSH'
ufw --force enable

# If you changed ports on a rerun and the old SSH rule is still open, remove it
# only after you've confirmed the new port works:
# ufw --force delete allow "$CURRENT_SSH_PORT"/tcp

# --- fail2ban ---
cat > /etc/fail2ban/jail.local <<EOF
[DEFAULT]
bantime = 3600
findtime = 600
maxretry = 5

[sshd]
enabled = true
port = $SSH_PORT
EOF
systemctl enable --now fail2ban

# --- Unattended upgrades ---
cat > /etc/apt/apt.conf.d/20auto-upgrades <<EOF
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF

# --- Kernel hardening ---
cat > /etc/sysctl.d/99-hardening.conf <<'EOF'
net.ipv4.ip_forward = 0
net.ipv4.conf.all.accept_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv6.conf.all.accept_source_route = 0
net.ipv4.conf.all.log_martians = 1
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.tcp_syncookies = 1
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1
net.ipv4.tcp_rfc1337 = 1
EOF
sysctl --system

# --- Swap ---
if [ -z "$(swapon --show)" ]; then
    fallocate -l 4G /swapfile
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile
    echo '/swapfile none swap sw 0 0' >> /etc/fstab
    echo 'vm.swappiness=10' >> /etc/sysctl.d/99-hardening.conf
    sysctl vm.swappiness=10
fi

# --- Timezone ---
timedatectl set-timezone America/Los_Angeles
```

## Why this way

- **Pubkey OR password+TOTP (two tracks) instead of pubkey-only.** Keys are the right primary path — fast, non-interactive, unphishable. But they don't solve "SSH in from my phone" or "SSH in from a friend's laptop while I'm travelling." Password+TOTP solves that without weakening the key path, because `AuthenticationMethods publickey keyboard-interactive:pam` means each connection uses ONE of the methods; compromising the TOTP+password doesn't help attack a pubkey login and vice versa. Berkeley's Savio HPC cluster uses the same model for the same reason.
- **`PasswordAuthentication no` + `KbdInteractiveAuthentication yes` is not a contradiction.** They're different auth methods in SSH's protocol. `PasswordAuthentication` is the legacy single-factor password-only method (disabled). `KbdInteractiveAuthentication` runs PAM, and we've layered `pam_google_authenticator.so` on top of `@include common-auth`, so "interactive" is password-then-TOTP, never just password.
- **TOTP module ordering in `/etc/pam.d/sshd`.** pam_google_authenticator comes AFTER `@include common-auth`, so the user is prompted for password first, then TOTP. Reversing the order would leak which accounts have TOTP enrolled (attacker sends wrong password after wrong TOTP and learns from the sequence of prompts). Password-first avoids that.
- **No `nullok` on pam_google_authenticator.** If a user somehow ends up without `~/.google_authenticator`, the password path fails closed rather than accepting password-only. Bootstrap order in the script (enroll TOTP before flipping PAM on) ensures the primary user never hits this.
- **Authenticator app choice is the user's.** TOTP is RFC 6238 standard. `libpam-google-authenticator` on the server talks to any compliant client — Authy, 1Password, Bitwarden, Microsoft Authenticator, etc. Keeping this open means the user can use whatever password manager they already trust.
- **fail2ban stays in the picture.** Even with no password-only path, bots will still hammer sshd; fail2ban keeps logs quieter and blocks brute-force attempts against the password+TOTP path (3 tries per 30s from `google-authenticator --rate-limit` is a backup, not the primary throttle).
- **Validate `sshd -t` before restarting.** A typo in `sshd_config` + a blind service restart has locked out more people than any actual attack.
- **Three verification gates, but only two are mandatory.** Gate 1 (before sshd restart) confirms the existing key path works on the *current* port. Gate 2 (after sshd restart) confirms key login works on the *configured* port before the script proceeds. Gate 3 (password+TOTP) is optional because pubkey still works either way.
- **Conservative UFW sequencing on port changes.** If UFW is already active and you're changing SSH ports on a rerun, the script opens the new port before restarting SSH and keeps the old rule until you've verified the new port works. That avoids the "listener moved but firewall hasn't caught up yet" lockout path.
- **Additive UFW, not reset.** Any rules you add later layer on top of 00's base rules. A `ufw reset` in 00 would silently undo them every time you rerun hardening.
- **`sudo` requires password even with key-based SSH.** A common rookie move is `NOPASSWD:ALL` in sudoers — it turns a cheap SSH key compromise into immediate root. The default (password-required) is correct; the script leaves it alone.
- **Swap is sized small on purpose.** The VPS has 48 GB of RAM; swap exists to let the kernel evict cold pages under pressure, not as a performance crutch. `swappiness=10` keeps it as insurance, not default behaviour.

## Known gotchas

- **Authenticator app clock skew.** If the VPS and your phone disagree by more than ~30s, TOTP codes won't verify. `--window-size=3` accepts codes from ±1 30-second step (so ±30s slack). Beyond that, enable "sync time" in your authenticator app settings. `timedatectl status` on the VPS should show `System clock synchronized: yes`.
- **Scratch codes are your recovery path if you lose the authenticator app.** The enrollment step prints 5 one-time-use recovery codes. Save them in a password manager (or anywhere you can retrieve them without the lost device). Without them, losing your phone means console recovery.
- **Re-enrolling TOTP.** The script skips enrollment on rerun if `~/.google_authenticator` exists — re-enrollment generates a new secret and invalidates the old app. If you actually want to re-enroll: `rm ~/.google_authenticator` first, then rerun the script (or manually run the `google-authenticator` command from the replicate-manually section).
- **Three bad password/TOTP attempts trigger a temporary rate limit.** `google-authenticator --rate-limit=3 --rate-time=30` means the forced keyboard-interactive test can stop accepting attempts for about 30 seconds after three mistakes. That is annoying, but it does **not** disable normal key-based SSH.
- **The `AllowUsers` line.** If you already have other SSH-based user accounts on the VPS, `AllowUsers <new-user>` will restrict logins to only the new user. Add them (space-separated) in `/etc/ssh/sshd_config` if you need others to keep access. They'll also need their own TOTP enrollment if they use the password path.
- **`ssh.socket` is a special case.** If systemd socket activation is running SSH through `ssh.socket`, changing `Port` in `sshd_config` may not move the actual listener. The script now refuses to do an automatic port change in that mode; switch away from socket activation first or keep the existing port.
- The script hard-codes `America/Los_Angeles`. If you're not in the Pacific timezone, edit the `timedatectl` line or change it after the fact with `sudo timedatectl set-timezone <Region/City>`.
- The fail2ban `ignoreip` line is commented out. If your home IP is static, uncomment it and add your IP so a typo can't lock you out.
- **If you lock yourself out:** Contabo's control panel has a web VNC console. Fix `/etc/ssh/sshd_config` and/or `/etc/pam.d/sshd` there. The timestamped backups from steps 10 and 11 are your restore paths.
