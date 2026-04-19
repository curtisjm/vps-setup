# `05-export-from-laptop.sh` — Snapshot Gas Town state on the laptop

**Run as:** regular user **on your laptop** (not on the VPS).
**Goal:** produce a pair of timestamped tarballs plus a sha256 manifest, safe to scp to the new VPS, containing the bits of Gas Town that aren't in git.

## What it does in detail

1. **Pre-flight.** Warns (not errors) if not running on macOS — the script is written and tested on a macOS laptop, but the logic is portable. Looks up `GT_TOWN_ROOT` (defaults to `~/gt`), verifies the directory and `~/gt/.dolt-data/` both exist, and that `gt` is on PATH (if missing, it warns but continues — you just lose the clean daemon stop).
2. **In-flight agent check.** If `bd` is available, counts beads with status `in_progress`. If non-zero, prompts for confirmation. Rationale: a cold snapshot mid-task captures inconsistent state (bead marked in_progress without a completing commit) — not fatal, but worth flagging.
3. **Unpushed polecat scan.** Walks `~/gt/*/polecats/*/` worktrees looking for local commits ahead of upstream (`git rev-list --count @{upstream}..HEAD`). If any are found, warns and requires an explicit y/N to continue — commits not pushed to GitHub will be lost the moment you decommission the laptop, because the VPS reconstructs `~/gt` by `git clone`, not by tarball.
4. **Stops Dolt cleanly.** Checks `gt dolt status` for "is running"; if so, runs `gt dolt stop` and sleeps 2 seconds for the pid file to clear. Records `DOLT_WAS_RUNNING=1` and installs an `EXIT` trap that always restarts Dolt at the end, even on error — never leaves the laptop in a half-broken state.
5. **Tars `.dolt-data/`.** Timestamp format `YYYYMMDD-HHMMSS`. Archive path: `<out-dir>/dolt-data-<stamp>.tar.gz`. Tar root is `$GT_ROOT` so the archive extracts to `./.dolt-data/` (portable across VPSes whose `$GT_TOWN_ROOT` might differ from the laptop's).
   - `--sparse` handling is tiered: prefer `tar --sparse` if the default `tar` is GNU tar (rare on macOS, common on Linux); else try `gtar` (installed via `brew install gnu-tar`); else fall back to plain tar without `--sparse` and warn. Sparse files in Dolt storage are usually small enough that the optimization isn't critical, but larger archives are slower to scp.
6. **Tars `~/.claude/`.** Excludes `shell-snapshots/`, `ide/`, `statsig/`, `todos/`, `__store.db` — all transient or personal analytics that waste bytes. Auth tokens do get included, which is fine on a single-user setup; if you'd rather re-authenticate on the VPS, simply don't pass this tarball to `06-migrate-gastown.sh`.
7. **sha256 manifest.** Runs `shasum -a 256` against each tarball (basenames, not paths, because the VPS side will `cd $TARBALL_DIR` before verifying). Writes to `<out-dir>/MANIFEST-<stamp>.sha256`.
8. **Prints next steps.** The exact `scp` command and the exact `06-migrate-gastown.sh` invocation with the timestamped filenames filled in. The less you have to think at 2 AM, the better.

## Replicate manually (no script)

```bash
# --- Stop the laptop's Dolt daemon so the snapshot isn't torn ---
gt dolt stop
sleep 2

# --- Tarball locations ---
STAMP=$(date +%Y%m%d-%H%M%S)
OUT_DIR=$PWD/gt-migration
mkdir -p "$OUT_DIR"
GT_ROOT="$HOME/gt"

# --- Dolt data (use gtar on macOS for --sparse; fall back to plain tar) ---
if tar --version | grep -qi 'gnu tar'; then
    tar --sparse -C "$GT_ROOT" -czf "$OUT_DIR/dolt-data-$STAMP.tar.gz" .dolt-data
elif command -v gtar >/dev/null; then
    gtar --sparse -C "$GT_ROOT" -czf "$OUT_DIR/dolt-data-$STAMP.tar.gz" .dolt-data
else
    tar -C "$GT_ROOT" -czf "$OUT_DIR/dolt-data-$STAMP.tar.gz" .dolt-data
fi

# --- ~/.claude (skip the transient bits) ---
tar -C "$HOME" -czf "$OUT_DIR/claude-$STAMP.tar.gz" \
    --exclude='.claude/shell-snapshots' \
    --exclude='.claude/ide' \
    --exclude='.claude/statsig' \
    --exclude='.claude/todos' \
    --exclude='.claude/__store.db' \
    .claude

# --- sha256 manifest ---
(
    cd "$OUT_DIR"
    shasum -a 256 "dolt-data-$STAMP.tar.gz" > "MANIFEST-$STAMP.sha256"
    shasum -a 256 "claude-$STAMP.tar.gz"   >> "MANIFEST-$STAMP.sha256"
)

# --- Restart laptop's Dolt daemon ---
gt dolt start

# --- Ship to VPS ---
scp "$OUT_DIR"/*-"$STAMP".* my-vps:~/
```

## What the tarballs contain (and don't)

**Dolt tarball** (`~/gt/.dolt-data/`):
- All Dolt DBs gastown manages: beads, mail, identity, work history, per-rig state.
- NOT in git on purpose — it's live mutable data.
- Authoritative; losing this is losing your bead history.

**Claude tarball** (`~/.claude/`):
- `projects/` — per-project conversation histories and auto-memory (useful, includes MEMORY.md index + individual memory files).
- `settings.json` — your global Claude Code settings, hooks, MCP servers.
- NOT `shell-snapshots/`, `ide/`, `statsig/`, `todos/`, `__store.db` (excluded — transient).

**NOT included** (lives in git, VPS will clone):
- `~/gt/` itself — cloned fresh from GitHub by `06-migrate-gastown.sh`.
- Rig submodules (gascity, world_of_floorcraft, etc.) — pulled as submodules.
- Polecat worktrees — recreated on demand after migration.
- Go module cache, node_modules, build artifacts — rebuilt.

## Why this way

- **Two tarballs, not one.** The Dolt DB is mandatory for Gas Town to work; `~/.claude` is personal and optional. Separating lets you ship just the Dolt tarball if you'd rather re-auth Claude Code fresh on the VPS.
- **Stop Dolt for the snapshot.** A running Dolt database is mid-transaction at any moment. A tar of that file tree is torn: different tables at slightly different logical points. Tar + live DB is a recipe for "it replayed fine on my laptop but `bd list` fails on the VPS." 5 seconds of downtime is cheap; debugging phantom DB corruption is not.
- **Exit trap restarts Dolt.** If the tarball step fails, the trap still fires — you don't come back to a laptop with a stopped Dolt daemon and a confused gastown.
- **sha256 manifest.** scp corruption is rare but real, especially across sketchy links. Having the VPS verify before extracting catches it immediately; no manifest would mean you find out when Dolt fails to open a subtly-corrupted blob a week later.
- **Timestamp in every filename.** Lets you run the export multiple times during validation without clobbering the previous attempt. Also disambiguates on the VPS side — `06-migrate-gastown.sh` derives the manifest filename from the tarball's timestamp, so the right manifest always matches the right tarball.
- **Unpushed-polecat scan.** A subtle failure mode: a polecat worktree has a local branch with un-pushed commits. The Dolt DB knows the polecat exists (bead state), and `~/gt` is cloned cleanly from GitHub, but the polecat's work is only in the laptop's git. Flagging before export gives you a chance to push.

## Known gotchas

- **macOS BSD tar doesn't do `--sparse`.** Without `gtar`, the archive is bigger (and takes longer to scp) than it needs to be. `brew install gnu-tar` is one command. The script auto-detects and warns.
- **The in-progress bead check requires `bd` on PATH.** If you haven't sourced `~/.bashrc` or `bd` isn't installed locally, the check silently skips.
- **Unpushed-commit detection only walks `*/polecats/*/`.** If you have ad-hoc worktrees elsewhere (e.g. `~/gt/tmp/scratch-branch`), they're not scanned. Run `git -C <path> status` on anything you care about before exporting.
- **Auth tokens in `~/.claude` are transferred as-is.** Fine for personal use; think twice before tarballing `~/.claude` on a shared or work machine.
- **The restart at the end needs `gt` on PATH** — the script errors to stderr if it can't and leaves Dolt stopped; you'd run `gt dolt start` manually.
