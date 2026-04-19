#!/usr/bin/env bash
#
# 05-export-from-laptop.sh — Snapshot Gas Town state on the laptop for VPS migration
#
# PURPOSE:
#   Creates the tarballs you'll ship to the VPS. Run this ON YOUR LAPTOP, not
#   on the VPS. It packages the two non-git pieces of Gas Town state:
#     1. ~/gt/.dolt-data/   — the live Dolt databases (beads, mail, identity,
#                              work history). NOT in git. Authoritative.
#     2. ~/.claude/         — Claude Code configs, projects, auto-memory.
#                              Personal, not in gastown. Partially portable.
#
# WHAT IT DOES (in order):
#   1. Pre-flight checks: on macOS? gt tools present? any agents running?
#   2. Stops the Dolt server cleanly so the .dolt-data snapshot isn't torn.
#   3. Warns about uncommitted changes / unpushed commits in ~/gt.
#   4. Tarballs .dolt-data/ with a timestamp into ./gt-migration/
#   5. Tarballs ~/.claude/ (minus obvious ephemera) into ./gt-migration/
#   6. Emits a sha256 manifest so the VPS side can verify nothing corrupted.
#   7. Prints the scp command you'll use to ship it to the VPS.
#
# USAGE:
#   ./05-export-from-laptop.sh [output-dir]
#
#   By default writes to ./gt-migration/ in the current working directory.
#
# DESIGN NOTES:
#   - We DO NOT push anything anywhere. Producing local artifacts is the right
#     primitive; you decide how to ship them (scp, rsync over ssh, restic to
#     B2, encrypted USB stick, whatever).
#   - Dolt MUST be stopped during the tarball — an online snapshot will be
#     torn across SQL transactions and may fail to replay on the VPS. The
#     script restarts it at the end so your laptop keeps working.
#   - We deliberately DO NOT tar up ~/gt itself. That tree IS in git
#     (curtisjm/gt on GitHub); the VPS will `git clone` it fresh. Tarballing
#     a 30GB+ tree of worktrees and node_modules would be waste on waste.

set -euo pipefail

# ----------------------------------------------------------------------------
# Pre-flight
# ----------------------------------------------------------------------------

# macOS-only check. The VPS side (06) runs on Linux.
# Not a hard error on Linux laptops, just a heads-up — the logic should still work.
if [[ "$(uname)" != "Darwin" ]]; then
    echo "[!] This script is written for a macOS laptop. On Linux, review before running."
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

# Output directory — defaults to ./gt-migration but caller can override.
# Artifacts are timestamped so multiple exports don't clobber each other.
OUT_DIR="${1:-$PWD/gt-migration}"
STAMP="$(date +%Y%m%d-%H%M%S)"
mkdir -p "$OUT_DIR"

# Resolve real locations. We read from env so unusual setups still work, with
# sane defaults for the standard Gas Town layout.
GT_ROOT="${GT_TOWN_ROOT:-$HOME/gt}"
DOLT_DATA="$GT_ROOT/.dolt-data"
CLAUDE_DIR="$HOME/.claude"

# ----------------------------------------------------------------------------
# Step 1: Verify Gas Town is actually installed here
# ----------------------------------------------------------------------------
# If ~/gt isn't present, or .dolt-data is missing, we're running this from the
# wrong machine. Bail early — don't create an empty tarball.

log "Verifying Gas Town state..."

if [[ ! -d "$GT_ROOT" ]]; then
    error "$GT_ROOT does not exist. Is this the right machine?"
    exit 1
fi

if [[ ! -d "$DOLT_DATA" ]]; then
    error "$DOLT_DATA does not exist. Gas Town Dolt data is missing."
    exit 1
fi

if ! command -v gt &> /dev/null; then
    warn "'gt' not on PATH — we can still snapshot, but can't do a clean daemon stop."
fi

ok "Found Gas Town at $GT_ROOT (Dolt data: $(du -sh "$DOLT_DATA" | awk '{print $1}'))"

# ----------------------------------------------------------------------------
# Step 2: Warn about in-flight agent work
# ----------------------------------------------------------------------------
# If any agents are mid-task, a cold snapshot may capture inconsistent state
# (e.g. a bead marked in_progress with no completing commit). Not fatal, but
# worth flagging so the user can resolve first.

log "Checking for active agent work..."

if command -v bd &> /dev/null; then
    IN_PROGRESS=$(bd list --status=in_progress 2>/dev/null | wc -l | tr -d ' ' || echo 0)
    if [[ "$IN_PROGRESS" -gt 0 ]]; then
        warn "There are $IN_PROGRESS beads in_progress. Consider letting them finish first."
        warn "  (Or: accept that they'll restart cleanly on the VPS after migration.)"
        read -rp "Continue anyway? [y/N] " CONT
        [[ "$CONT" == "y" || "$CONT" == "Y" ]] || { warn "Aborting"; exit 0; }
    fi
fi

# Check for polecat worktrees with unpushed commits — witness normally catches
# these, but a final sweep before migration is prudent.
log "Scanning polecat worktrees for unpushed work..."
UNPUSHED_FOUND=0
while IFS= read -r -d '' worktree; do
    if [[ -d "$worktree/.git" || -f "$worktree/.git" ]]; then
        # Suppress errors from detached HEADs that have no upstream
        AHEAD=$(git -C "$worktree" rev-list --count '@{upstream}..HEAD' 2>/dev/null || echo 0)
        if [[ "$AHEAD" -gt 0 ]]; then
            warn "Unpushed commits in: $worktree ($AHEAD commits ahead of upstream)"
            UNPUSHED_FOUND=$((UNPUSHED_FOUND + 1))
        fi
    fi
done < <(find "$GT_ROOT" -maxdepth 4 -type d -name "polecats" -print0 2>/dev/null | xargs -0 -I {} find {} -maxdepth 2 -type d -print0 2>/dev/null)

if [[ "$UNPUSHED_FOUND" -gt 0 ]]; then
    warn "$UNPUSHED_FOUND polecat worktree(s) have unpushed commits."
    warn "These will be lost if you don't push them before migration."
    read -rp "Continue anyway? [y/N] " CONT
    [[ "$CONT" == "y" || "$CONT" == "Y" ]] || { warn "Aborting — push commits and rerun"; exit 0; }
else
    ok "No unpushed polecat commits detected"
fi

# ----------------------------------------------------------------------------
# Step 3: Stop the Dolt server cleanly
# ----------------------------------------------------------------------------
# A torn tarball of a running Dolt database is subtly broken — some tables
# may replay, others won't, and you find out days later when `bd list` fails
# on the VPS. Stop Dolt first; we'll restart it at the end.

log "Stopping Dolt server for a clean snapshot..."

DOLT_WAS_RUNNING=0
if command -v gt &> /dev/null && gt dolt status 2>&1 | grep -q "is running"; then
    DOLT_WAS_RUNNING=1
    gt dolt stop
    # Give it a moment to flush and release its pid file
    sleep 2
    ok "Dolt stopped"
else
    ok "Dolt was not running — proceeding"
fi

# Always restart Dolt at exit, even if a later step fails — don't leave the
# laptop in a broken state just because the tarball failed partway through.
cleanup() {
    if [[ "$DOLT_WAS_RUNNING" -eq 1 ]]; then
        log "Restarting Dolt on laptop..."
        gt dolt start || warn "Couldn't restart Dolt — run 'gt dolt start' manually"
    fi
}
trap cleanup EXIT

# ----------------------------------------------------------------------------
# Step 4: Tarball .dolt-data
# ----------------------------------------------------------------------------
# Use --sparse so the Dolt storage files (which may be sparsely allocated)
# don't balloon on disk. Use gzip — zstd would be faster/smaller but gzip is
# universal and doesn't need anything extra on the VPS side.
#
# We tar relative to $GT_ROOT so the archive extracts to '.dolt-data/' rather
# than an absolute path; that way the VPS can extract wherever $GT_TOWN_ROOT
# points to, not necessarily /Users/curtis/gt.

DOLT_TARBALL="$OUT_DIR/dolt-data-${STAMP}.tar.gz"

log "Creating Dolt tarball: $DOLT_TARBALL"
log "  (this can take a minute — $(du -sh "$DOLT_DATA" | awk '{print $1}') of data)"

tar --sparse -C "$GT_ROOT" -czf "$DOLT_TARBALL" .dolt-data

ok "Dolt tarball created: $(du -sh "$DOLT_TARBALL" | awk '{print $1}')"

# ----------------------------------------------------------------------------
# Step 5: Tarball ~/.claude/
# ----------------------------------------------------------------------------
# Claude Code stores:
#   - ~/.claude/projects/     — per-project conversation histories (useful)
#   - ~/.claude/projects/*/memory/ — the auto-memory MEMORY.md + notes (useful)
#   - ~/.claude/settings.json — global settings (useful)
#   - ~/.claude/shell-snapshots/ — transient, can skip
#   - ~/.claude/ide/          — IDE integration sockets, transient, skip
#   - ~/.claude/statsig/      — anon analytics, transient, skip
#
# We exclude transient dirs to keep the archive small. Auth tokens go with
# the archive — you can either trust that (single-user laptop + single-user
# VPS) or re-login on the VPS and omit this step entirely.

CLAUDE_TARBALL="$OUT_DIR/claude-${STAMP}.tar.gz"

if [[ -d "$CLAUDE_DIR" ]]; then
    log "Creating ~/.claude tarball: $CLAUDE_TARBALL"
    tar -C "$HOME" -czf "$CLAUDE_TARBALL" \
        --exclude='.claude/shell-snapshots' \
        --exclude='.claude/ide' \
        --exclude='.claude/statsig' \
        --exclude='.claude/todos' \
        --exclude='.claude/__store.db' \
        .claude
    ok "Claude tarball created: $(du -sh "$CLAUDE_TARBALL" | awk '{print $1}')"
else
    warn "~/.claude not found — skipping"
    CLAUDE_TARBALL=""
fi

# ----------------------------------------------------------------------------
# Step 6: Generate sha256 manifest
# ----------------------------------------------------------------------------
# If an scp gets corrupted (rare, but happens over sketchy networks), you
# want to know on the VPS side before extracting. Manifest goes alongside
# the tarballs; 06-migrate-gastown.sh verifies it.

log "Writing sha256 manifest..."

MANIFEST="$OUT_DIR/MANIFEST-${STAMP}.sha256"
(
    cd "$OUT_DIR"
    shasum -a 256 "$(basename "$DOLT_TARBALL")" >> "$MANIFEST"
    [[ -n "$CLAUDE_TARBALL" ]] && shasum -a 256 "$(basename "$CLAUDE_TARBALL")" >> "$MANIFEST"
)
ok "Manifest: $MANIFEST"

# ----------------------------------------------------------------------------
# Step 7: Final instructions
# ----------------------------------------------------------------------------
# Print the exact commands the user will run next. The less they have to
# remember/type, the less likely a silly mistake.

echo ""
echo -e "${GREEN}==========================================================================${NC}"
echo -e "${GREEN}  Export complete!${NC}"
echo -e "${GREEN}==========================================================================${NC}"
echo ""
echo "Artifacts in $OUT_DIR:"
ls -lh "$OUT_DIR" | grep -E "${STAMP}"
echo ""
echo "Next steps:"
echo ""
echo "  1. PUSH any uncommitted work in ~/gt (the VPS will 'git clone' this repo):"
echo "       cd ~/gt && git status"
echo "       cd ~/gt && git push  # if you have commits"
echo "       # same for submodules that have drift"
echo ""
echo "  2. SHIP the tarballs to the VPS (replace <vps> with your SSH host):"
echo "       scp $OUT_DIR/*-${STAMP}.* <vps>:~/"
echo ""
echo "  3. On the VPS, run:"
echo "       ./06-migrate-gastown.sh ~/dolt-data-${STAMP}.tar.gz ~/claude-${STAMP}.tar.gz"
echo ""
echo "Your laptop Gas Town is $([[ "$DOLT_WAS_RUNNING" -eq 1 ]] && echo 'being restarted now' || echo 'untouched')."
