# VPS Setup Scripts

A small collection of shell scripts for setting up and hardening a fresh Ubuntu/Debian VPS for AI agent workloads (Claude Code, Gas Town, etc.).

Designed initially for a Contabo VPS 40 (12 vCPU / 48GB RAM / 250GB NVMe) in US Central, but should work on any fresh Ubuntu 22.04+ or Debian 12+ system.

## Scripts

| Script | Purpose | Run as | Where |
|---|---|---|---|
| `00-harden.sh` | Security hardening (user, SSH, firewall, fail2ban, sysctl) | `root` | VPS |
| `01-install-dev-tools.sh` | Node, Python, Go, CLI tools, Docker, Claude Code, gt+bd | regular user | VPS |
| `02-setup-git.sh` | Git config + GitHub SSH key + aliases | regular user | VPS |
| `03-install-dolt.sh` | Dolt (version-controlled SQL DB for Gas Town beads) | regular user | VPS |
| `04-contabo-diagnostics.sh` | Benchmark the VPS to check for noisy neighbors | regular user | VPS |
| `05-export-from-laptop.sh` | Snapshot Dolt data + ~/.claude into tarballs | regular user | **laptop** |
| `06-migrate-gastown.sh` | Clone ~/gt, restore tarballs, start daemon | regular user | VPS |

## Quick start

On a fresh VPS, from your **local machine**:

```bash
# 1. Copy the scripts to the VPS
scp *.sh root@<vps-ip>:/root/

# 2. SSH in as root (use the initial password from Contabo)
ssh root@<vps-ip>

# 3. On the VPS, run the hardening script
chmod +x 00-harden.sh
./00-harden.sh
```

The hardening script will prompt you for a username and your SSH public key. **Before it locks down SSH**, it will pause and ask you to verify in a separate terminal that you can log in as the new user. Don't skip that check.

After hardening completes, log in as your new user:

```bash
ssh -p <port> <user>@<vps-ip>
```

Then run the remaining scripts:

```bash
chmod +x 01-install-dev-tools.sh 02-setup-git.sh 03-install-dolt.sh 04-contabo-diagnostics.sh

./01-install-dev-tools.sh    # installs everything including Go, gt, bd (15-20 min)
source ~/.bashrc              # pick up new PATH and aliases

./02-setup-git.sh             # interactive — will pause for you to add key to GitHub
./03-install-dolt.sh          # optional tmpfs setup for Contabo speed workaround
./04-contabo-diagnostics.sh   # run now to establish baseline; re-run periodically
```

## Gas Town migration (laptop → VPS)

Once the VPS is hardened and has the dev tools installed (scripts 00–03), you're
ready to migrate your Gas Town state from your laptop. This is a two-step dance
across machines:

```bash
# --- ON YOUR LAPTOP ---
cd ~/dev/vps-setup
chmod +x 05-export-from-laptop.sh
./05-export-from-laptop.sh

# This will:
#   1. Stop Dolt on the laptop (briefly)
#   2. Tarball ~/gt/.dolt-data and ~/.claude with sha256 manifest
#   3. Restart Dolt and print a scp command
#
# Copy the artifacts to the VPS:
scp gt-migration/*-<timestamp>.* my-vps:~/

# --- ON THE VPS ---
cd ~/dev/vps-setup   # or wherever you cloned this repo on the VPS
chmod +x 06-migrate-gastown.sh
./06-migrate-gastown.sh ~/dolt-data-<timestamp>.tar.gz ~/claude-<timestamp>.tar.gz

# This will:
#   1. git clone ~/gt (with submodules) from GitHub
#   2. Verify sha256 against the manifest
#   3. Extract the Dolt data into the new checkout
#   4. Build gt+bd from the local source (matches laptop commit exactly)
#   5. Start the daemon and run `gt doctor`
```

**Before exporting**, do yourself a favor:
- `cd ~/gt && git status` — push anything uncommitted; the VPS will git-clone from GitHub
- Check for unpushed polecat work (the export script scans and warns)
- Consider `gt daemon stop` on the laptop after migration so both machines
  aren't racing on the same bead DB if you briefly share a fork

**Keep both running in parallel for ~a week.** Don't delete anything on the
laptop until you've confirmed agents work correctly on the VPS across at
least a full patrol cycle.

## Recommended local SSH config

After running `00-harden.sh`, add this to your `~/.ssh/config` on your local machine:

```
Host my-vps
    HostName <vps-ip>
    Port <ssh-port>
    User <username>
    IdentityFile ~/.ssh/id_ed25519
    ServerAliveInterval 60
    ServerAliveCountMax 10
```

Then you can just `ssh my-vps` from anywhere.

## Design principles

**Idempotent.** Every script should be safe to re-run. If something is already set up, the script should detect that and skip it, not error out or clobber working config. This matters because you'll absolutely need to re-run parts of these as you iterate.

**Loud failures.** All scripts use `set -euo pipefail` — any unexpected error halts the script rather than silently continuing with half-broken state.

**Explicit about what they do.** Heavy commenting in each script. When you come back in 6 months wondering "why did I add this sysctl tweak," the answer is right there.

**Separation of concerns.** One script = one area of setup. Makes it easier to tweak individual pieces without rerunning everything.

**No magic.** No custom tooling, no framework dependencies. Just bash + standard Ubuntu packages. Should still work in 5 years.

## What's NOT in these scripts

- **Backup strategy.** You should set up off-VPS backups separately (e.g., `rclone` to Backblaze B2, or `restic` to another VPS). These scripts handle the VPS itself, not backups.
- **Production service setup.** No systemd service files for specific apps, no reverse proxies, no TLS certs. Add what you need per-project.
- **Monitoring beyond basics.** For real observability, look at Netdata (single-node) or a lightweight Grafana + Prometheus setup.
- **Gas Town itself.** The tooling has its own install/setup flow; these scripts just prepare the ground.

## Adapting for other providers

Most of this should work as-is on Hetzner, DigitalOcean, Linode, Vultr. Things to watch for:

- **`04-contabo-diagnostics.sh`** is named for Contabo but works anywhere. The thresholds it warns about (steal > 10%, IOPS < 5k) are most relevant to oversold providers.
- **`03-install-dolt.sh`** — the tmpfs workaround is a Contabo-specific optimization. On a provider with real NVMe, the speed win is smaller, though tmpfs is still faster.
- **Swap file size** in `00-harden.sh` is 4GB. Hetzner's ARM cloud instances often have less RAM, so you might want more swap there.

## Migration checklist (when you're ready to move providers)

1. On old VPS: run final backups, push Dolt data to remote, push git repos
2. On new VPS: run scripts `00` through `03` (re-use the SSH key setup steps; or generate fresh keys and rotate)
3. Transfer data: `rsync -avz --progress old-vps:~/data/ new-vps:~/data/`
   - For Gas Town specifically, use `05-export-from-laptop.sh` +
     `06-migrate-gastown.sh` (they work VPS→VPS too; just run 05 on the old VPS)
4. Update DNS if you're using a domain
5. Decommission old VPS after a week of parallel running

## Backup strategy (once migrated)

The migration scripts are a one-shot. For ongoing protection of the VPS, set up:

```bash
# restic is installed by 01-install-dev-tools.sh
restic init --repo b2:my-bucket:gt-backup       # one-time init
# In a cron:
#   0 */6 * * * gt dolt stop && restic backup ~/gt/.dolt-data && gt dolt start
```

Backing up a running Dolt server produces torn snapshots (same reason the
migration script stops Dolt). Either stop it briefly in your backup cron, or
use Dolt's native push to a DoltHub remote as a continuous backup channel.

## Notes on secrets

The scripts don't handle secrets for you. Your API keys, tokens, etc. should go in `~/.config/<app>/` or `~/.env` files with `chmod 600`. The global `.gitignore` set up by `02-setup-git.sh` catches the obvious ones (`.env`, `*.pem`, `*.key`) but it's not a substitute for thinking about where secrets live.

For real secrets management on a single VPS, consider:
- `pass` (unix password manager, GPG-backed)
- `sops` + `age` (for encrypted config files in git)
- Environment variables loaded by systemd service files

## Troubleshooting

**"I locked myself out of SSH after running 00-harden.sh"**
Log into Contabo's web-based VNC console (in the control panel). From there you can fix `/etc/ssh/sshd_config` or re-add your key to `~/.ssh/authorized_keys`. The original SSH config is backed up to `/etc/ssh/sshd_config.backup.<timestamp>`.

**"nvm: command not found after running 01-install-dev-tools.sh"**
You need to `source ~/.bashrc` or open a new shell. nvm adds itself to `.bashrc` but doesn't inject into the current shell automatically.

**"Permission denied when running docker"**
The script adds your user to the `docker` group, but you need to log out and back in for that to take effect. Alternatively: `newgrp docker`.

**"04-contabo-diagnostics.sh shows concerning steal numbers"**
First, re-run at a different time of day. Noisy-neighbor issues often correlate with time of day. If consistently bad, open a Contabo support ticket requesting node migration, citing the steal measurements.
