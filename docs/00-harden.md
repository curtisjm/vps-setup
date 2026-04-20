# `00-harden.sh` — Initial VPS hardening

**Run as:** `root`, once, on a fresh VPS.
**Goal:** turn a default Contabo/Ubuntu image into a non-embarrassing SSH-only box before it sits on the public internet for longer than necessary.

## What it does in detail

The script is a top-to-bottom walk through "bare minimum hardening for a personal server exposed to the internet." It runs these steps in order:

1. **Pre-flight.** Refuses to run unless `$EUID == 0` (needs to write system files, create users, manage services). Sets `set -euo pipefail` so any unexpected error aborts — hardening half-applied is worse than not applied.
2. **Gathers input upfront.** Prompts for the new username, the user's SSH public key (validated to start with `ssh-ed25519`, `ssh-rsa`, or `ecdsa-sha2`), and an optional custom SSH port. Also asks for a password (step 4b below). Collecting all input at the top means the rest of the script runs unattended — you can go make coffee.
3. **System update.** `apt-get update && apt-get upgrade` with `DEBIAN_FRONTEND=noninteractive` to suppress the "keep current config or use maintainer's?" prompts that will otherwise hang the script.
4. **Installs baseline packages:** `ufw`, `fail2ban`, `unattended-upgrades`, `apt-listchanges`, plus utilities (`htop`, `iotop`, `sysstat`, `curl`, `wget`, `rsync`, `git`, `ca-certificates`, `gnupg`, `software-properties-common`).
5. **Creates the non-root user** (`adduser --disabled-password --gecos ""`) and adds them to the `sudo` group. Working as root is dangerous; `sudo` forces conscious escalation.
6. **Step 4b: sets a UNIX password for that user.** Required because `sudo` on Ubuntu/Debian defaults to password-required — a `--disabled-password` account can't even run `sudo -v`, which means `01-install-dev-tools.sh` would fail immediately. Uses `passwd -S` to detect an already-set password on reruns and skips the prompt if so. Loops until the user provides two matching non-empty entries, then pipes through `chpasswd`.
7. **Installs the SSH public key** into `/home/<user>/.ssh/authorized_keys`. Key behaviour: append-if-missing (using `grep -qxF`) rather than overwrite — overwriting silently wipes any other keys the user previously added. Sets perms to the exact values `sshd` insists on (`.ssh` = 700, `authorized_keys` = 600), or it will silently ignore the file.
8. **Stop-and-verify gate.** Prints a big warning and asks the user to confirm (in a second terminal) that they can SSH in as the new user with their key, *before* the script disables password auth and root login. Skipping this is how people lock themselves out.
9. **Hardens sshd.** Backs up `/etc/ssh/sshd_config` with a timestamp, then uses a `set_ssh_option` helper to remove any existing line for each key (commented or not) and append the new one. Settings applied: custom `Port`, `PermitRootLogin no`, `PasswordAuthentication no`, `PubkeyAuthentication yes`, `PermitEmptyPasswords no`, `X11Forwarding no`, `MaxAuthTries 3`, `ClientAliveInterval 300` / `ClientAliveCountMax 2`, `AllowUsers <new-user>`. Validates with `sshd -t` before restarting `sshd` — if validation fails we abort without restarting, so the existing session keeps working while you fix it.
10. **Configures UFW.** Sets `default deny incoming` / `default allow outgoing`, opens the chosen SSH port with a comment, then `ufw --force enable`. Deliberately additive — no `ufw --force reset` — so any rules you add later survive a rerun of 00.
11. **Configures fail2ban.** Writes `/etc/fail2ban/jail.local` with a `[DEFAULT]` section (`bantime=3600`, `findtime=600`, `maxretry=5`) and an `[sshd]` section that points at the custom port. Uses `jail.local` (not `jail.conf`) because `jail.conf` is owned by the package and gets overwritten on upgrade.
12. **Enables unattended security upgrades.** Writes `/etc/apt/apt.conf.d/20auto-upgrades` — that plus the default `50unattended-upgrades` shipped by Ubuntu is enough to get security-only auto-patching.
13. **Applies kernel hardening.** Writes `/etc/sysctl.d/99-hardening.conf` with the sysctl knobs most often wrong on a stock image: disables IP forwarding, ICMP redirects (accept and send), source routing, enables reverse path filtering, SYN cookies, martian logging, ignores broadcast echoes, TIME_WAIT assassination protection. `sysctl --system` reloads.
14. **Swap file.** If `swapon --show` is empty, creates a 4 GB `/swapfile` (chmod 600, `mkswap`, `swapon`, add to `/etc/fstab`) and sets `vm.swappiness=10` so it's only used under real memory pressure rather than at the whim of the default `60`.
15. **Sets timezone** to `America/Los_Angeles` via `timedatectl`. Pure quality-of-life: log timestamps match wall time.
16. **Prints a summary** listing what was done and the next commands to run.

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
    software-properties-common

# --- New user ---
NEW_USER=curtis
adduser --disabled-password --gecos "" "$NEW_USER"
usermod -aG sudo "$NEW_USER"

# --- Password for sudo ---
passwd "$NEW_USER"    # interactive; enter a password you'll remember

# --- SSH key ---
mkdir -p /home/"$NEW_USER"/.ssh
# Append your public key (don't > redirect — that clobbers existing keys)
echo 'ssh-ed25519 AAAA... your@laptop' >> /home/"$NEW_USER"/.ssh/authorized_keys
chmod 700 /home/"$NEW_USER"/.ssh
chmod 600 /home/"$NEW_USER"/.ssh/authorized_keys
chown -R "$NEW_USER":"$NEW_USER" /home/"$NEW_USER"/.ssh

# --- VERIFY in a second terminal: ssh user@vps-ip must work before continuing ---

# --- SSH hardening ---
SSH_PORT=22   # or your chosen port
cp /etc/ssh/sshd_config /etc/ssh/sshd_config.backup.$(date +%Y%m%d-%H%M%S)
# Edit /etc/ssh/sshd_config so it contains exactly (remove/comment conflicting lines):
cat >> /etc/ssh/sshd_config <<EOF
Port $SSH_PORT
PermitRootLogin no
PasswordAuthentication no
PubkeyAuthentication yes
PermitEmptyPasswords no
X11Forwarding no
MaxAuthTries 3
ClientAliveInterval 300
ClientAliveCountMax 2
AllowUsers $NEW_USER
EOF
sshd -t && systemctl restart sshd

# --- UFW firewall ---
ufw default deny incoming
ufw default allow outgoing
ufw allow "$SSH_PORT"/tcp comment 'SSH'
ufw --force enable

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

- **Key-only SSH + fail2ban is belt-and-suspenders.** Keys alone make brute force infeasible; fail2ban mostly just keeps your logs quieter. Both are cheap.
- **Validate `sshd -t` before restarting.** A typo in `sshd_config` + a blind `systemctl restart sshd` has locked out more people than any actual attack.
- **Stop-and-verify gate before disabling root SSH.** If your key didn't actually install (bad clipboard paste, permissions off), you still have root password access to fix it. Once the daemon restarts, you don't.
- **Additive UFW, not reset.** Any rules you add later layer on top of 00's base rules. A `ufw reset` in 00 would silently undo them every time you rerun hardening.
- **`sudo` requires password even with key-based SSH.** A common rookie move is `NOPASSWD:ALL` in sudoers — it turns a cheap SSH key compromise into immediate root. The default (password-required) is correct; the script leaves it alone.
- **Swap is sized small on purpose.** The VPS has 48 GB of RAM; swap exists to let the kernel evict cold pages under pressure, not as a performance crutch. `swappiness=10` keeps it as insurance, not default behaviour.

## Known gotchas

- The script hard-codes `America/Los_Angeles`. If you're not in the Pacific timezone, edit the `timedatectl` line or change it after the fact with `sudo timedatectl set-timezone <Region/City>`.
- If you already have SSH-based user accounts on the VPS with passwords, the `AllowUsers` line will restrict logins to only the new user you create. Add them (space-separated) in `/etc/ssh/sshd_config` if you need others to keep access.
- The fail2ban `ignoreip` line is commented out. If your home IP is static, uncomment it and add your IP so a typo can't lock you out.
- If you lock yourself out anyway: Contabo's control panel has a web VNC console. Fix `/etc/ssh/sshd_config` (or `~/.ssh/authorized_keys`) there. The timestamped backup from step 9 is your restore path.
