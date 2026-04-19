# VPS Setup Scripts

A small collection of shell scripts for setting up and hardening a fresh Ubuntu/Debian VPS for AI agent workloads (Claude Code, Gas Town, etc.).

Designed initially for a Contabo VPS 40 (12 vCPU / 48GB RAM / 250GB NVMe) in US Central, but should work on any fresh Ubuntu 22.04+ or Debian 12+ system. The Docker install step in `01-install-dev-tools.sh` auto-detects whether to pull from the Ubuntu or Debian repo via `/etc/os-release`.

## Scripts

| Script | Purpose | Run as | Where | Deep dive |
|---|---|---|---|---|
| `00-harden.sh` | Security hardening (user, SSH, firewall, fail2ban, sysctl) | `root` | VPS | [docs/00-harden.md](docs/00-harden.md) |
| `01-install-dev-tools.sh` | Node, Python, Go, CLI tools, Docker, Claude Code, Codex, Atuin, gt+bd | regular user | VPS | [docs/01-install-dev-tools.md](docs/01-install-dev-tools.md) |
| `02-setup-git.sh` | Git config + GitHub SSH key + aliases | regular user | VPS | [docs/02-setup-git.md](docs/02-setup-git.md) |
| `03-install-dolt.sh` | Dolt (version-controlled SQL DB for Gas Town beads) | regular user | VPS | [docs/03-install-dolt.md](docs/03-install-dolt.md) |
| `04-contabo-diagnostics.sh` | Benchmark the VPS to check for noisy neighbors | regular user | VPS | [docs/04-contabo-diagnostics.md](docs/04-contabo-diagnostics.md) |
| `05-export-from-laptop.sh` | Snapshot Dolt data + ~/.claude into tarballs | regular user | **laptop** | [docs/05-export-from-laptop.md](docs/05-export-from-laptop.md) |
| `06-migrate-gastown.sh` | Clone ~/gt, restore tarballs, start daemon | regular user | VPS | [docs/06-migrate-gastown.md](docs/06-migrate-gastown.md) |
| `07-install-tailscale.sh` | Join VPS to tailnet, optionally lock SSH to Tailscale-only | regular user | VPS | [docs/07-install-tailscale.md](docs/07-install-tailscale.md) |

Each per-script doc has: what the script does in detail, how to replicate by hand, why it's built that way, and known gotchas. See [docs/README.md](docs/README.md) for the index.

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

The hardening script will prompt you for:

1. A username for the new non-root account
2. Your SSH public key (paste it; ed25519 is recommended)
3. A password for the new user — required for `sudo`. Not used for SSH login (SSH stays key-only), but the script will refuse to continue without one set

**Before it locks down SSH**, the script pauses and asks you to verify in a
separate terminal that you can log in as the new user. Don't skip that check.

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
./07-install-tailscale.sh     # join the VPS to your tailnet (recommended)
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

**On macOS laptops:** `05-export-from-laptop.sh` uses `tar --sparse` to skip
zeroed regions in the Dolt files (big size savings on a 20GB DB with lots of
sparse internal files). macOS ships BSD tar, which doesn't understand
`--sparse`. The script auto-detects and falls back in this order:

1. If `tar` identifies as GNU tar, use it with `--sparse`.
2. Else, if `gtar` is on PATH (`nix-env -iA nixpkgs.gnutar` or similar),
   use that with `--sparse`.
3. Else, fall back to plain `tar` without `--sparse` — still works, just
   produces a bigger archive.

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

## Fixing "Error opening terminal: xterm-ghostty"

If your local terminal is **Ghostty** (or any terminal with a custom `TERM`
like `xterm-kitty`, `wezterm`, etc.), ncurses apps on the VPS (tmux, btop,
htop, less) will fail with:

```
Error opening terminal: xterm-ghostty.
```

Your terminal sends `TERM=xterm-ghostty` over SSH, but the VPS has no
terminfo entry for it. Fix from your **laptop** (Ghostty must be installed
locally — the laptop has the terminfo, the VPS doesn't):

```bash
# One-liner: export terminfo on laptop, compile into ~/.terminfo on VPS
infocmp -x xterm-ghostty | ssh my-vps -- tic -x -

# Verify
ssh my-vps -- infocmp xterm-ghostty | head -3
```

This installs the terminfo into the VPS user's `~/.terminfo/` — no root
needed, doesn't affect other users. Same pattern works for other terminals:
replace `xterm-ghostty` with `xterm-kitty`, `wezterm`, etc.

**Fallback** (if you can't install terminfo): add to your laptop's
`~/.ssh/config` under the VPS host block:

```
SetEnv TERM=xterm-256color
```

Works instantly but drops terminal-specific features (true color in some
apps, graphics protocols). Fine for pure-text SSH sessions.

## Design principles

**Idempotent.** Every script should be safe to re-run. If something is already set up, the script detects that and skips it rather than clobbering working config. Specifically:

- `00-harden.sh` appends SSH keys to `authorized_keys` instead of overwriting; `ufw` rules are additive (no `--force reset`) so rules added later by `07-install-tailscale.sh` survive a rerun.
- `02-setup-git.sh` manages a BEGIN/END block in `~/.gitignore_global`; edits you make outside those markers are preserved across reruns. It also refuses to overwrite an existing `Host github.com` SSH config block that points to a different key.
- `03-install-dolt.sh` unsets before `--add`-ing dolt config so user.name/email don't grow duplicate entries on rerun.
- `07-install-tailscale.sh` applies the current `--ssh` preference even when Tailscale is already logged in (so toggling the prompt answer between runs takes effect).

This matters because you'll absolutely need to re-run parts of these as you iterate.

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
