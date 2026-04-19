# `03-install-dolt.sh` — Dolt, Gas Town's data plane

**Run as:** regular user with `sudo` access.
**Goal:** install Dolt ≥ 1.82.4 (the version gastown requires), configure its identity to match git, and optionally set up a tmpfs RAM disk for hot working data (Contabo-specific speed workaround).

## What it does in detail

1. **Refuses root.** Dolt's config is per-user (`~/.dolt/`).
2. **Version gate.** Defines `MIN_DOLT_VERSION="1.82.4"` and a `version_lt` helper (dotted `sort -V` comparison). Enforces that any install end up at or above that — older Dolt hits gastown schema bugs like "`column started_at could not be found in any table in scope`" that are hours of debugging for you to discover.
3. **Install.** If `dolt` is missing, runs the official installer: `sudo bash -c 'curl -L https://github.com/dolthub/dolt/releases/latest/download/install.sh | bash'`. If Dolt is already installed but below `MIN_DOLT_VERSION`, force-upgrades. If already ≥ min, prompts whether to reinstall anyway (for when you want latest). After install, verifies the installed version is at least the minimum and hard-fails otherwise (extremely unusual; would require dolthub to publish a regression).
4. **Identity.** Reads `git config --global user.name/email`, prompts if empty. Then `--unset`s existing `user.name`/`user.email` from Dolt's global config (tolerating "not set") and `--add`s the new values. The `--unset`-first pattern is important: Dolt's `--add` appends to a list, so reruns accumulate duplicate entries in the config file, which eventually confuses `dolt commit` about whose identity to use.
5. **Optional tmpfs.** Prompts whether to set up a 4 GB tmpfs at `~/dolt-tmpfs` and a paired `~/dolt-persistent` disk dir. If yes:
   - Creates both dirs.
   - Adds an fstab entry: `tmpfs ~/dolt-tmpfs tmpfs size=4G,noatime,nodev,nosuid,uid=<uid>,gid=<gid> 0 0`.
   - Mounts it.
   - Writes two helper scripts: `~/.local/bin/dolt-sync-to-disk` (`rsync -a --delete` tmpfs → persistent) and `~/.local/bin/dolt-restore-from-disk` (the reverse, for post-reboot restore).
   - Prints reminders: data is volatile; cron the sync; push to a Dolt remote for real backups.
6. **Summary** with quick-reference `dolt` commands (`dolt init`, `dolt sql`, `dolt sql-server`, `dolt status`, `dolt diff`, `dolt commit -am`, `dolt log`).

## Replicate manually (no script)

```bash
# --- Install ---
sudo bash -c 'curl -L https://github.com/dolthub/dolt/releases/latest/download/install.sh | bash'
dolt version   # verify >= 1.82.4

# --- Identity ---
dolt config --global --unset user.name  || true
dolt config --global --unset user.email || true
dolt config --global --add user.name  "$(git config --global user.name)"
dolt config --global --add user.email "$(git config --global user.email)"

# --- Optional: tmpfs for hot data ---
mkdir -p ~/dolt-tmpfs ~/dolt-persistent

# Add to /etc/fstab (one line):
echo "tmpfs $HOME/dolt-tmpfs tmpfs size=4G,noatime,nodev,nosuid,uid=$(id -u),gid=$(id -g) 0 0" \
    | sudo tee -a /etc/fstab
sudo mount ~/dolt-tmpfs

# Sync helper (put in ~/.local/bin/dolt-sync-to-disk, chmod +x):
cat > ~/.local/bin/dolt-sync-to-disk <<EOF
#!/usr/bin/env bash
set -e
rsync -a --delete "$HOME/dolt-tmpfs/" "$HOME/dolt-persistent/"
EOF
chmod +x ~/.local/bin/dolt-sync-to-disk

# Restore helper (post-reboot):
cat > ~/.local/bin/dolt-restore-from-disk <<EOF
#!/usr/bin/env bash
set -e
rsync -a "$HOME/dolt-persistent/" "$HOME/dolt-tmpfs/"
EOF
chmod +x ~/.local/bin/dolt-restore-from-disk

# Cron the sync every 30 minutes:
crontab -l | { cat; echo '*/30 * * * * ~/.local/bin/dolt-sync-to-disk >> ~/dolt-sync.log 2>&1'; } | crontab -
```

## Why this way

- **Version pin.** Gas Town is picky about Dolt. The enforced floor saves you from `bd`/`gt` crashing with cryptic SQL errors on a "works on my machine" Dolt version.
- **`--unset` then `--add`** instead of `--set`: Dolt's global config models some fields as lists internally, so `--add` on rerun duplicates. `--unset` clears the slot; `--add` writes one clean entry. `dolt config --global --set` is not supported for all fields; the unset+add dance is universal.
- **tmpfs is opt-in.** It's a sharper tool than most users expect:
  - Pro: eliminates Contabo's shared-disk 4 k IOPS variance from your write path. Dolt commits and git-like operations feel instant.
  - Con: you lose data on reboot unless you sync. The sync helpers reduce this to "up to 30 min of lost work" if you cron every 30 min, but for the canonical bead history you still want disk or a Dolt remote.
- **The 4 GB tmpfs cap** is a balance: gastown's working Dolt DB grows over time but usually stays well under 2 GB for a single user. 4 GB gives headroom without eating too much RAM. On 48 GB systems this is rounding error.
- **`noatime,nodev,nosuid` tmpfs flags.** No reason to track access times on a RAM disk; you don't need device nodes or setuid binaries there (security hygiene).

## Known gotchas

- **Dolt installer runs a remote `curl | bash`.** This is the vendor's own documented install path, but it's still pulling and executing an arbitrary script at install time. If you want to audit it first, fetch and inspect before piping to bash.
- **The tmpfs isn't where Gas Town looks by default.** Gas Town's canonical location for Dolt data is `~/gt/.dolt-data/`. If you want to use the tmpfs, you need to either (a) point `GT_DOLT_HOST` / `GT_TOWN_ROOT` at the tmpfs-backed path, or (b) symlink `~/gt/.dolt-data` to `~/dolt-tmpfs/.dolt-data` and make sure the restore-from-disk script runs before gastown starts on boot. Neither is handled by this script.
- **`crontab` isn't set up by 03.** If you enable tmpfs, you'll need to cron the sync yourself. The script just writes the helper scripts.
- **`version_lt` is a dumb sort compare.** It correctly handles the common cases (`1.82.3 < 1.82.4 < 1.83.0`) but pre-release tags like `1.82.4-rc.1` sort in ways that surprise some people. Stick to stable releases and you're fine.
