#!/usr/bin/env bash
#
# 06-migrate-gastown.sh — Restore Gas Town on the VPS from laptop tarballs
#
# PURPOSE:
#   Reconstitutes a working Gas Town install on a freshly-prepared VPS using
#   the artifacts produced by 05-export-from-laptop.sh.
#
# WHAT IT DOES (in order):
#   1. Pre-flight: on Linux? gt/bd/dolt installed? required tarballs present?
#   2. Clones ~/gt from GitHub (the user's tracked repo).
#   3. Initializes git submodules (rigs like gascity, world_of_floorcraft).
#   4. Verifies sha256 of transferred tarballs against the manifest.
#   5. Extracts the Dolt tarball into $GT_TOWN_ROOT/.dolt-data.
#   6. Extracts the ~/.claude tarball (if provided).
#   7. Starts the Dolt server and runs `gt doctor` to validate.
#   8. Prints next steps (re-auth gh/claude, onyx recovery, etc.).
#
# NOTE: This script does NOT build gt/bd/gc from the ~/gt checkouts. Those
# checkouts are dev workspaces; the installed binaries come from Linuxbrew
# (configured by 01-install-dev-tools.sh). Update tools with `brew upgrade`,
# not from source.
#
# USAGE:
#   ./06-migrate-gastown.sh <dolt-tarball> [claude-tarball]
#
#   Example:
#     ./06-migrate-gastown.sh ~/dolt-data-20260418-181530.tar.gz \
#                             ~/claude-20260418-181530.tar.gz
#
# PREREQUISITES:
#   - Run 00-harden.sh, 01-install-dev-tools.sh, 02-setup-git.sh, 03-install-dolt.sh
#     first. This script assumes gt, bd, dolt, git, and gh are on PATH.
#   - SSH key added to GitHub (02 does this).
#   - The tarballs have been scp'd over from your laptop.

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

refresh_gt_checkout() {
    local gt_root="$1"
    local gt_repo_url="$2"

    log "Cloning $gt_repo_url into $gt_root..."

    if [[ -d "$gt_root/.git" ]]; then
        warn "$gt_root is already a git repo — skipping clone, pulling latest instead"
        if ! git -C "$gt_root" pull --recurse-submodules; then
            error "Failed to update existing checkout at $gt_root"
            error "Resolve the git error above before restoring data onto this tree."
            return 1
        fi
    elif [[ -d "$gt_root" && "$(ls -A "$gt_root" 2>/dev/null)" ]]; then
        error "$gt_root exists and is non-empty, but not a git repo. Refusing to clobber."
        error "Move it aside or delete it, then re-run."
        return 1
    else
        git clone --recurse-submodules "$gt_repo_url" "$gt_root"
        ok "Clone complete"
    fi
}
# end refresh_gt_checkout

run_gt_doctor_or_fail() {
    log "Running gt doctor..."
    if gt doctor; then
        ok "gt doctor passed"
    else
        error "gt doctor failed — review the output above"
        return 1
    fi
}
# end run_gt_doctor_or_fail

# ----------------------------------------------------------------------------
# Step 1: Argument parsing + pre-flight
# ----------------------------------------------------------------------------
# Dolt tarball is REQUIRED — it's the data plane, without it nothing works.
# Claude tarball is OPTIONAL — you may prefer to re-authenticate fresh on the
# VPS rather than transferring auth tokens.

if [[ $# -lt 1 ]]; then
    error "Usage: $0 <dolt-tarball> [claude-tarball]"
    error ""
    error "  dolt-tarball:   path to dolt-data-*.tar.gz from 05-export-from-laptop.sh"
    error "  claude-tarball: (optional) path to claude-*.tar.gz"
    exit 1
fi

DOLT_TARBALL="$1"
CLAUDE_TARBALL="${2:-}"

# Resolve to absolute paths — we cd around later and relative paths would break.
DOLT_TARBALL="$(readlink -f "$DOLT_TARBALL")"
[[ -n "$CLAUDE_TARBALL" ]] && CLAUDE_TARBALL="$(readlink -f "$CLAUDE_TARBALL")"

[[ -f "$DOLT_TARBALL" ]] || { error "Dolt tarball not found: $DOLT_TARBALL"; exit 1; }
if [[ -n "$CLAUDE_TARBALL" && ! -f "$CLAUDE_TARBALL" ]]; then
    error "Claude tarball specified but not found: $CLAUDE_TARBALL"
    exit 1
fi

# Toolchain check: fail fast with a specific message rather than blowing up
# halfway through with an obscure 'command not found'. gt/bd come from
# Linuxbrew (installed by 01); we don't need `go` here since we no longer
# build from source.
for cmd in git dolt gt bd; do
    if ! command -v "$cmd" &> /dev/null; then
        error "'$cmd' not found on PATH. Run earlier setup scripts first."
        exit 1
    fi
done

# GT_TOWN_ROOT is the canonical workspace location. Default matches laptop.
GT_ROOT="${GT_TOWN_ROOT:-$HOME/gt}"

# Configurable GitHub source — default to Curtis's fork. Override with env var
# for other users or if you've moved the repo.
GT_REPO_URL="${GT_REPO_URL:-git@github.com:curtisjm/gt.git}"

# ----------------------------------------------------------------------------
# Step 2: Clone ~/gt from GitHub
# ----------------------------------------------------------------------------
# The ~/gt tree is a git repo (curtisjm/gt) that tracks:
#   - Role context (CLAUDE.md files per rig/role)
#   - Beads export state (.beads/issues.jsonl — a *snapshot*, not live data)
#   - Rig submodules (gascity, world_of_floorcraft, etc.)
# It does NOT track:
#   - .dolt-data/ (live DB — that's this script's job)
#   - daemon/ (pid/log/state — rebuilt by `gt daemon start`)
#   - polecat worktrees, mayor/rig clones, refinery/rig clones
#
# Using --recurse-submodules pulls rig code in one step. The submodules may
# point to a fork (curtisjm/gascity) or upstream — whatever the laptop had
# pinned at last push.

refresh_gt_checkout "$GT_ROOT" "$GT_REPO_URL" || exit 1

# Init/update submodules explicitly in case --recurse-submodules was skipped
# or something is out of sync. Idempotent.
log "Syncing submodules..."
git -C "$GT_ROOT" submodule update --init --recursive
ok "Submodules synced"

# ----------------------------------------------------------------------------
# Step 3: Verify tarball integrity (if manifest present)
# ----------------------------------------------------------------------------
# The export script writes a MANIFEST-*.sha256 alongside the tarballs. If the
# user scp'd it over too, we verify before extracting. If they didn't, we warn
# and proceed — not a hard failure because scp corruption is rare.

log "Checking for sha256 manifest..."

TARBALL_DIR="$(dirname "$DOLT_TARBALL")"
# Derive manifest path from the tarball's timestamp so we match the exact
# export run, not whatever MANIFEST-*.sha256 sorted first. Export names the
# tarball dolt-data-${STAMP}.tar.gz and the manifest MANIFEST-${STAMP}.sha256.
TARBALL_BASE="$(basename "$DOLT_TARBALL")"
STAMP="${TARBALL_BASE#dolt-data-}"
STAMP="${STAMP%.tar.gz}"
MANIFEST="$TARBALL_DIR/MANIFEST-${STAMP}.sha256"

if [[ -f "$MANIFEST" ]]; then
    log "Verifying against $MANIFEST..."
    # Verify only the artifacts the user actually supplied. The Claude tarball
    # is optional, so a manifest containing both files must not block a
    # dolt-only restore.
    verify_artifact() {
        local artifact_path="$1"
        local artifact_name expected actual
        artifact_name="$(basename "$artifact_path")"
        expected="$(awk -v file="$artifact_name" '$2 == file { print $1; exit }' "$MANIFEST")"

        if [[ -z "$expected" ]]; then
            error "Manifest $MANIFEST has no checksum entry for $artifact_name"
            exit 1
        fi

        actual="$(sha256sum "$artifact_path" | awk '{print $1}')"
        if [[ "$actual" != "$expected" ]]; then
            error "sha256 verification failed for $artifact_name"
            error "Expected: $expected"
            error "Actual:   $actual"
            error "Re-scp from laptop and try again."
            exit 1
        fi
    }

    verify_artifact "$DOLT_TARBALL"
    [[ -n "$CLAUDE_TARBALL" ]] && verify_artifact "$CLAUDE_TARBALL"
    ok "Tarballs verified intact"
else
    warn "No manifest found — skipping integrity check"
fi

# ----------------------------------------------------------------------------
# Step 4: Extract Dolt data
# ----------------------------------------------------------------------------
# If .dolt-data already exists on the VPS (e.g. from a prior attempt), we
# MUST move it aside before extracting — otherwise tar merges on top and you
# end up with a Frankenstein half-old, half-new database.

log "Extracting Dolt data into $GT_ROOT/.dolt-data..."

if [[ -d "$GT_ROOT/.dolt-data" ]]; then
    BACKUP="$GT_ROOT/.dolt-data.pre-migration-$(date +%Y%m%d-%H%M%S)"
    warn "$GT_ROOT/.dolt-data already exists — moving to $BACKUP"
    mv "$GT_ROOT/.dolt-data" "$BACKUP"
fi

# Use pv if available to get a progress bar on the extract — large tarballs
# otherwise look frozen and tempt the user to Ctrl+C.
if command -v pv &> /dev/null; then
    pv "$DOLT_TARBALL" | tar -xzf - -C "$GT_ROOT"
else
    tar -xzf "$DOLT_TARBALL" -C "$GT_ROOT"
fi

ok "Dolt data extracted ($(du -sh "$GT_ROOT/.dolt-data" | awk '{print $1}'))"

# ----------------------------------------------------------------------------
# Step 5: Extract ~/.claude/ (optional)
# ----------------------------------------------------------------------------
# Only if the user provided a tarball. Same move-aside logic to avoid merges.

if [[ -n "$CLAUDE_TARBALL" ]]; then
    log "Extracting ~/.claude/..."

    if [[ -d "$HOME/.claude" ]]; then
        BACKUP="$HOME/.claude.pre-migration-$(date +%Y%m%d-%H%M%S)"
        warn "$HOME/.claude already exists — moving to $BACKUP"
        mv "$HOME/.claude" "$BACKUP"
    fi

    tar -xzf "$CLAUDE_TARBALL" -C "$HOME"
    ok "~/.claude extracted"
else
    log "No Claude tarball provided — you'll need 'claude login' later"
fi

# ----------------------------------------------------------------------------
# Step 6: Confirm gt/bd versions (installed from brew by 01)
# ----------------------------------------------------------------------------
# We deliberately do NOT `make install` from the ~/gt/gastown/mayor/rig or
# ~/gt/beads/mayor/rig checkouts. Those are dev workspaces for contributing
# upstream — not the source of the binary Curtis uses day-to-day. The
# daily-driver gt/bd/gc came from Linuxbrew in step 01, and updates flow
# through `brew upgrade`.
#
# If you specifically want to run a fork's build for testing, do it manually:
#     make -C ~/gt/gastown/mayor/rig install SKIP_UPDATE_CHECK=1
# ...but be aware that overwrites the brew binary until the next `brew reinstall`.

log "Confirming Gas Town toolchain versions..."
log "  gt: $(gt version 2>/dev/null | head -1 || echo 'unknown')"
log "  bd: $(bd version 2>/dev/null | head -1 || echo 'unknown')"
command -v gc &> /dev/null && log "  gc: $(gc version 2>/dev/null | head -1 || echo 'unknown')"

# ----------------------------------------------------------------------------
# Step 7: Start Dolt and validate
# ----------------------------------------------------------------------------
# Start the daemon (which manages Dolt lifecycle) and verify the restored
# data is readable. `gt doctor` exercises the full stack: Dolt health, schema
# presence, identity resolution, workspace detection.

log "Starting Gas Town daemon..."

# Ensure any stale pid/state files from a crashed prior run are gone.
rm -f "$GT_ROOT/daemon/dolt.pid" "$GT_ROOT/daemon/dolt-state.json" 2>/dev/null || true

if gt daemon start; then
    ok "Daemon started"
else
    error "Daemon failed to start — see logs in $GT_ROOT/daemon/"
    error "Common fixes:"
    error "  - gt dolt status    # see if Dolt is already running on :3307"
    error "  - gt dolt stop && gt daemon start"
    exit 1
fi

# Give Dolt a moment to come up before hammering it with queries
sleep 3

run_gt_doctor_or_fail || exit 1

# Sanity-check the beads data survived by counting a few things.
log "Sanity-checking bead data..."
BEAD_COUNT=$(bd list 2>/dev/null | wc -l | tr -d ' ')
log "  $BEAD_COUNT beads visible on this host"
if [[ "$BEAD_COUNT" -lt 10 ]]; then
    warn "Suspiciously few beads — check that the Dolt tarball extracted correctly"
fi

# ----------------------------------------------------------------------------
# Step 8: Final summary + next steps
# ----------------------------------------------------------------------------

echo ""
echo -e "${GREEN}==========================================================================${NC}"
echo -e "${GREEN}  Gas Town migration complete!${NC}"
echo -e "${GREEN}==========================================================================${NC}"
echo ""
echo "Restored:"
echo "  ✓ ~/gt cloned from $GT_REPO_URL"
echo "  ✓ Submodules initialized"
echo "  ✓ .dolt-data restored ($(du -sh "$GT_ROOT/.dolt-data" | awk '{print $1}'))"
[[ -n "$CLAUDE_TARBALL" ]] && echo "  ✓ ~/.claude restored"
echo "  ✓ gt/bd/gc already installed from brew (update with: brew upgrade)"
echo "  ✓ Daemon running, $BEAD_COUNT beads visible"
echo ""
echo "Next steps on the VPS:"
echo ""
echo "  1. Re-authenticate tools (tokens don't migrate cleanly):"
echo "       claude login                   # if you skipped the Claude tarball"
echo "       gh auth login                  # GitHub API auth"
echo ""
echo "  2. If you had unpushed polecat work (e.g. onyx wof-797), push from the"
echo "     laptop's worktrees before decommissioning the laptop."
echo ""
echo "  3. Decide your DNS/access story:"
echo "       - Keep using 'ssh <vps>' (simplest)"
echo "       - Assign a stable DNS name (e.g. gt.example.com -> VPS IP)"
echo ""
echo "  4. Run the laptop and VPS in parallel for a few days before"
echo "     decommissioning the laptop. Catch any 'oh, I forgot about X' early."
echo ""
echo "  5. On the laptop, consider:"
echo "       gt daemon stop                 # prevent accidental writes"
echo "       # Don't delete ~/gt yet — keep as a backup for a week"
echo ""
