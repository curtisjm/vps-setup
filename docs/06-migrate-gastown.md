# `06-migrate-gastown.sh` — Restore Gas Town on the VPS

**Run as:** regular user **on the VPS**, after 00–03 and after scp-ing the tarballs from 05.
**Goal:** reconstitute a fully working Gas Town install from (a) the GitHub-hosted `~/gt` repo and (b) the two tarballs produced by `05-export-from-laptop.sh`.

## What it does in detail

Takes 1 or 2 positional args: the Dolt tarball (required) and the Claude tarball (optional).

1. **Refuses root.** Gas Town runs per-user.
2. **Arg parsing + pre-flight.** Validates the tarballs exist, resolves to absolute paths with `readlink -f`, and checks `git`, `dolt`, `gt`, and `bd` are on PATH (hard-fails with a pointer to the earlier setup scripts if anything's missing).
3. **Clones `~/gt` from GitHub.** Default URL is `git@github.com:curtisjm/gt.git`; override via `GT_REPO_URL` env var. Uses `--recurse-submodules` so rig submodules (gascity, world_of_floorcraft, etc.) come with it. On rerun (`~/gt/.git` already exists), does `git pull --recurse-submodules` instead. Refuses to clobber a non-empty non-git `~/gt` — you'd rather get an error than lose whatever was there.
4. **Re-runs `git submodule update --init --recursive`.** Idempotent; ensures submodules are synced even if `--recurse-submodules` was skipped earlier or something drifted.
5. **sha256 verify.** Derives the manifest filename from the tarball's timestamp (`dolt-data-<STAMP>.tar.gz` → `MANIFEST-<STAMP>.sha256`) so it always matches the right export run, even if older manifests are still lying around. Runs `sha256sum -c` from the tarball directory. If the manifest is missing, warns and proceeds (not a hard error — scp corruption is rare).
6. **Extracts `.dolt-data/`.** If `~/gt/.dolt-data` already exists on the VPS, moves it to `~/gt/.dolt-data.pre-migration-<ts>` before extracting — tar merges on top of existing content, which silently creates a half-old half-new DB. Uses `pv` (installed by 01) for a progress bar if available.
7. **Extracts `~/.claude/`** if the optional tarball was passed. Same move-aside-first pattern.
8. **Confirms gt/bd/gc versions.** 01 already installed these from Linuxbrew; we just print the versions here for the log. The `~/gt/gastown/mayor/rig/` and `~/gt/gascity/mayor/rig/` checkouts are dev workspaces for contributing upstream, **not** the install source — the brew binaries are the daily drivers and are updated with `brew upgrade`.
9. **Starts the daemon.** Removes stale `dolt.pid` and `dolt-state.json` from `~/gt/daemon/` first. `gt daemon start` brings up Dolt on port 3307. If it fails, prints common recovery commands (`gt dolt status`, `gt dolt stop && gt daemon start`) and exits.
10. **`gt doctor`.** Exercises the full stack: Dolt reachable, schema present, identity resolves, workspace detected. Non-zero exit is a warning, not a hard fail — sometimes a doctor gripe is informational.
11. **Sanity-check beads.** Runs `bd list` and counts lines. A count of <10 suggests the tarball didn't extract correctly or was nearly empty; warns but doesn't error.
12. **Summary.** Prints what restored (including bead count), then a checklist:
    - `claude login` if you skipped the Claude tarball.
    - `gh auth login` (tokens don't migrate cleanly).
    - Push any unpushed laptop polecat work before decommissioning the laptop.
    - Consider a stable DNS name vs. just using `ssh <vps>`.
    - Run laptop + VPS in parallel for a few days before decommissioning the laptop.

## Replicate manually (no script)

```bash
# Args
DOLT_TARBALL=~/dolt-data-20260419-143022.tar.gz
CLAUDE_TARBALL=~/claude-20260419-143022.tar.gz      # optional

# --- Clone ~/gt ---
git clone --recurse-submodules git@github.com:curtisjm/gt.git ~/gt
git -C ~/gt submodule update --init --recursive

# --- Verify ---
TARBALL_DIR=$(dirname "$DOLT_TARBALL")
STAMP=$(basename "$DOLT_TARBALL" .tar.gz | sed 's/^dolt-data-//')
MANIFEST="$TARBALL_DIR/MANIFEST-$STAMP.sha256"
(cd "$TARBALL_DIR" && sha256sum -c "$(basename "$MANIFEST")")

# --- Extract Dolt data (move aside any existing) ---
[[ -d ~/gt/.dolt-data ]] && mv ~/gt/.dolt-data ~/gt/.dolt-data.pre-migration-$(date +%s)
pv "$DOLT_TARBALL" | tar -xzf - -C ~/gt    # or: tar -xzf "$DOLT_TARBALL" -C ~/gt

# --- Extract Claude (optional) ---
if [[ -n "$CLAUDE_TARBALL" ]]; then
    [[ -d ~/.claude ]] && mv ~/.claude ~/.claude.pre-migration-$(date +%s)
    tar -xzf "$CLAUDE_TARBALL" -C "$HOME"
fi

# --- Confirm gt/bd/gc (installed via brew in 01) ---
gt version
bd version
command -v gc && gc version

# --- Start daemon and verify ---
rm -f ~/gt/daemon/dolt.pid ~/gt/daemon/dolt-state.json
gt daemon start
sleep 3
gt doctor
bd list | wc -l                                  # sanity-check bead count
```

## Why this way

- **Split the state.** `~/gt` is reproducible from GitHub; `.dolt-data/` is not. Shipping only the non-reproducible part means small tarballs and no confusion about "did that node_modules come from the laptop or did the VPS rebuild it?"
- **Manifest derived from tarball stamp** (not `ls MANIFEST-*.sha256 | head -1`). If the user left old manifests in the tarball directory, the naive glob picks whichever sorted first — usually the wrong one. Deriving from the tarball filename means the manifest always matches.
- **Move-aside before extract.** Tar's default behaviour on collisions is to merge contents, which quietly creates Frankenstein state. Moving aside is cheap and reversible; you can even verify the new extraction works, then `rm -rf` the backup later.
- **gt/bd/gc come from brew, not from the cloned source.** The `~/gt/gastown/mayor/rig/` and `~/gt/gascity/mayor/rig/` checkouts exist for upstream contribution work, not as the install path. Curtis's laptop runs the brew binaries (`/opt/homebrew/bin/gt`, `(Homebrew)` in `bd version`); the VPS mirrors that via Linuxbrew in 01. Updates happen with `brew upgrade`. Building from `~/gt/.../rig` would replace the signed release binary with an unsigned fork HEAD — only do that if you're explicitly testing a local change.
- **`pv` for progress.** A multi-GB tarball extracting with no output feels frozen, so the tempted Ctrl-C is real. A progress bar removes the temptation.
- **`gt doctor` as validation.** It's not just a connectivity check — it actively exercises the parts of gastown that would silently break after a bad migration (identity resolution, schema queries, daemon liveness). Non-zero is signal.
- **Bead count sanity check.** `<10 beads` on a real install means something went wrong with extraction. Cheap check, worth having.

## Known gotchas

- **`GT_REPO_URL` defaults to Curtis's fork.** If you're running this as someone else, set `GT_REPO_URL=git@github.com:YOUR-USER/gt.git` before invoking the script.
- **SSH to GitHub must already work.** 02-setup-git.sh installs the key and asks you to upload it; run that first and verify `ssh -T git@github.com` before running 06.
- **Submodule access.** If any submodules are private or on a fork you don't have, the initial clone will fail partway through. Pull the base repo first with `--no-recurse-submodules`, then init submodules one at a time as needed.
- **Daemon start failures.** Usually means port 3307 is already bound (another Dolt instance, or the daemon started out-of-band). `gt dolt status` and `gt dolt stop` before retrying.
- **Auth tokens don't migrate cleanly.** Even with `~/.claude` copied over, some sessions and caches need to re-auth. Expect a few "hey, click this link" prompts on first use of Claude Code / gh after migration.
- **Parallel running risk.** If both the laptop and the VPS are writing to their (separate!) bead DBs while you're in parallel, divergence is inevitable. Stop the laptop's daemon (`gt daemon stop`) once the VPS is working, then decide later whether to decommission. Both boxes can safely *read* until you're ready.
