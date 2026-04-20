#!/usr/bin/env bash
#
# 01-install-dev-tools.sh — Install development tools for AI agent work
#
# PURPOSE:
#   Installs the languages, runtimes, and utilities you'll need to run
#   Gas Town and other AI agent orchestration tools.
#
# WHAT IT DOES:
#   1. Installs build essentials (gcc, make, etc. — needed by native npm/pip modules)
#   2. Installs Node.js via nvm (lets you switch versions easily)
#   3. Installs Python 3 + pip + venv + pipx
#   4. Installs uv (fast Python package/project manager, useful for modern tools)
#   5. Installs Go (used for Go-based dev work; gt/bd themselves come from brew below)
#   6. Installs useful CLI tools (tmux, ripgrep, fzf, jq, mosh, restic, etc.)
#   7. Installs Docker (optional — needed if you want to containerize agents)
#   8. Installs GitHub CLI (for easier GitHub operations)
#   9. Installs Claude Code CLI + OpenAI Codex CLI via npm
#  10. Installs Linuxbrew and uses it to install gt (Gas Town), bd (Beads),
#      and gc (Gas City) — matching Curtis's laptop setup (upstream releases,
#      not fork HEAD). Daily updates: `brew upgrade`.
#
# USAGE:
#   Run as your normal user (NOT root). You'll be prompted for sudo.
#     chmod +x 01-install-dev-tools.sh
#     ./01-install-dev-tools.sh
#
# DESIGN NOTES:
#   - We install Node via nvm (not apt) because apt's Node is often old,
#     and nvm lets you switch versions per-project.
#   - We install Docker but don't require it — comment out that section
#     if you don't want it.
#   - Everything is idempotent: re-running should be safe.

set -euo pipefail

# ----------------------------------------------------------------------------
# Pre-flight checks
# ----------------------------------------------------------------------------

# Must NOT run as root — nvm, pipx, etc. should be installed per-user.
# If we install them as root they end up in /root and regular users can't use them.
if [[ $EUID -eq 0 ]]; then
    echo "ERROR: Do not run this script as root. Run as your regular user."
    echo "The script will use sudo when it needs to."
    exit 1
fi

# Check we have sudo access. Better to fail early than partway through.
if ! sudo -v; then
    echo "ERROR: This script requires sudo access."
    exit 1
fi

# Color output helpers (same as 00-harden.sh)
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log()   { echo -e "${BLUE}[*]${NC} $1"; }
ok()    { echo -e "${GREEN}[✓]${NC} $1"; }
warn()  { echo -e "${YELLOW}[!]${NC} $1"; }
error() { echo -e "${RED}[✗]${NC} $1"; }

run_nvm_safely() {
    local original_term="${TERM-}"
    local term_overridden=0
    local errexit_was_enabled=0
    local nounset_was_enabled=0
    local status=0

    # nvm uses tput for colored output. If the VPS doesn't know the laptop's
    # TERM (common with Ghostty/kitty/etc.), temporarily fall back to a basic
    # terminfo entry so the install doesn't emit distracting warnings.
    if [[ -n "${TERM-}" ]] && command -v infocmp &>/dev/null && ! infocmp "$TERM" >/dev/null 2>&1; then
        warn "TERM '$TERM' is unknown on this host — temporarily using xterm-256color for nvm"
        export TERM="xterm-256color"
        term_overridden=1
    fi

    case $- in
        *e*) errexit_was_enabled=1; set +e ;;
    esac

    case $- in
        *u*) nounset_was_enabled=1; set +u ;;
    esac

    nvm "$@"
    status=$?

    [[ "$nounset_was_enabled" -eq 1 ]] && set -u
    [[ "$errexit_was_enabled" -eq 1 ]] && set -e

    if [[ "$term_overridden" -eq 1 ]]; then
        export TERM="$original_term"
    fi

    return "$status"
}
# end run_nvm_safely

install_gascity_with_brew_conflict_workaround() {
    local relink_flock=0
    local errexit_was_enabled=0
    local install_status=0

    # Homebrew's gascity formula pulls util-linux, which also ships `flock`.
    # If the standalone brew `flock` formula is already linked, Homebrew
    # refuses the install until `flock` is temporarily unlinked.
    if brew list --formula flock >/dev/null 2>&1; then
        if brew unlink flock >/dev/null 2>&1; then
            relink_flock=1
            warn "Temporarily unlinked brew 'flock' so gascity can install util-linux"
        fi
    fi

    case $- in
        *e*) errexit_was_enabled=1; set +e ;;
    esac

    brew install gastownhall/gascity/gascity
    install_status=$?

    [[ "$errexit_was_enabled" -eq 1 ]] && set -e

    if [[ "$relink_flock" -eq 1 ]]; then
        if brew link flock >/dev/null 2>&1; then
            ok "Re-linked brew 'flock' after gascity install"
        else
            warn "Couldn't re-link brew 'flock' automatically"
            warn "Run 'brew link flock' manually if you still want the brew version first on PATH"
        fi
    fi

    return "$install_status"
}
# end install_gascity_with_brew_conflict_workaround

export DEBIAN_FRONTEND=noninteractive

# ----------------------------------------------------------------------------
# Step 1: Build essentials and system libraries
# ----------------------------------------------------------------------------
# These are needed to compile native modules (e.g. npm packages with C++
# bindings like better-sqlite3, or Python packages with C extensions).
# Without these, a LOT of npm/pip installs will fail mysteriously.

log "Installing build essentials and common libraries..."
# bc is installed here because 04-contabo-diagnostics.sh depends on it for the
# CPU stress loop ('echo "scale=5000; 4*a(1)" | bc -l') and for float
# comparisons in the verdict block. Ubuntu Server minimal doesn't ship bc.
sudo apt-get update -qq
sudo apt-get install -y -qq \
    build-essential \
    pkg-config \
    libssl-dev \
    libffi-dev \
    zlib1g-dev \
    libbz2-dev \
    libreadline-dev \
    libsqlite3-dev \
    libncursesw5-dev \
    xz-utils \
    tk-dev \
    libxml2-dev \
    libxmlsec1-dev \
    liblzma-dev \
    bc
ok "Build essentials installed"

# ----------------------------------------------------------------------------
# Step 2: Useful CLI tools
# ----------------------------------------------------------------------------
# This is a curated set of tools that make CLI life much nicer. Rationale:
#   - tmux: persistent terminal sessions (essential for long-running agents)
#   - ripgrep (rg): fast grep, much better than stock grep for code
#   - fd-find: fast 'find' alternative
#   - fzf: fuzzy finder, integrates with tmux and shell
#   - jq: JSON processor, invaluable for any API work
#   - bat: syntax-highlighted cat
#   - tree: directory visualization
#   - ncdu: interactive disk usage — useful when you fill up the VPS
#   - tldr: short cheatsheet-style man pages
#   - mtr: traceroute + ping, useful for network debugging
#   - ca-certificates: up-to-date CA bundle for HTTPS
#   - unzip/zip: basic archive tools

log "Installing CLI productivity tools..."
# Extras for Gas Town on a VPS:
#   - mosh: resilient SSH replacement — survives network blips and laptop sleep,
#     which matters when you're ssh'd into the VPS for long agent sessions.
#   - restic: encrypted, deduplicated backups. Used by 05/06 migration scripts
#     as an option for pushing ~/gt/.dolt-data off-box to B2/S3.
#   - direnv: per-directory env vars (e.g., GT_DOLT_HOST, auth tokens)
#     that auto-load when you cd into a rig. Keeps secrets out of ~/.bashrc.
#   - make: needed by gastown's Makefile ('make install' is the blessed path).
#   - pv: pipe viewer — shows progress on tarball restores during migration.
sudo apt-get install -y -qq \
    tmux \
    ripgrep \
    fd-find \
    fzf \
    jq \
    bat \
    tree \
    ncdu \
    tldr \
    mtr-tiny \
    mosh \
    restic \
    direnv \
    make \
    pv \
    unzip \
    zip \
    vim \
    nano \
    less

# On Ubuntu, 'bat' installs as 'batcat' and 'fd' as 'fdfind' due to naming
# conflicts with existing packages. Create symlinks so they work under
# their expected names. ~/.local/bin should be in PATH on modern Ubuntu.
mkdir -p "$HOME/.local/bin"
[[ ! -e "$HOME/.local/bin/bat" ]] && ln -s /usr/bin/batcat "$HOME/.local/bin/bat"
[[ ! -e "$HOME/.local/bin/fd" ]] && ln -s /usr/bin/fdfind "$HOME/.local/bin/fd"

ok "CLI tools installed"

# ----------------------------------------------------------------------------
# Step 3: Install nvm (Node Version Manager)
# ----------------------------------------------------------------------------
# Why nvm instead of apt's nodejs:
#   - apt's version is often old (LTS from 1-2 years ago)
#   - nvm lets you install multiple Node versions and switch between them
#   - agent tools sometimes require specific Node versions
# The installer adds shell init lines to ~/.bashrc.

log "Installing nvm (Node Version Manager)..."
if [[ -d "$HOME/.nvm" ]]; then
    warn "nvm already installed, skipping"
else
    # Install script is from the official nvm repo.
    # We pin to a specific version rather than 'latest' for reproducibility.
    curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash
    ok "nvm installed"
fi

# Source nvm into the current shell so we can use it immediately
# (normally you'd need to re-open the shell for ~/.bashrc changes to take effect)
export NVM_DIR="$HOME/.nvm"
# shellcheck source=/dev/null
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"

# Install latest LTS Node. LTS is the stable, long-supported line —
# what you want for running tools, not the bleeding-edge "current" line.
log "Installing Node.js LTS..."
run_nvm_safely install --lts
run_nvm_safely use --lts
run_nvm_safely alias default lts/*
ok "Node.js $(node --version) installed"

# ----------------------------------------------------------------------------
# Step 4: Python 3 tooling
# ----------------------------------------------------------------------------
# Ubuntu comes with Python 3, but we want pip, venv, and pipx:
#   - python3-pip: standard package installer
#   - python3-venv: virtual environment support (never pip install globally)
#   - pipx: installs Python CLI tools in isolated envs (use for tools, not libs)

log "Installing Python tooling..."
sudo apt-get install -y -qq \
    python3 \
    python3-pip \
    python3-venv \
    python3-dev \
    pipx

# Ensure pipx's bin dir is on PATH (adds to ~/.bashrc if not already)
pipx ensurepath > /dev/null 2>&1 || true
ok "Python tooling installed (Python $(python3 --version | cut -d' ' -f2))"

# ----------------------------------------------------------------------------
# Step 5: Install uv (modern Python package/project manager)
# ----------------------------------------------------------------------------
# uv is a fast replacement for pip/pip-tools/virtualenv/pyenv, written in Rust.
# Many modern Python AI tools assume uv is available. Even if you don't use
# it directly, having it installed doesn't hurt.

log "Installing uv (fast Python package manager)..."
if command -v uv &> /dev/null; then
    warn "uv already installed, skipping"
else
    curl -LsSf https://astral.sh/uv/install.sh | sh
    ok "uv installed"
fi

# ----------------------------------------------------------------------------
# Step 5b: Install Go toolchain
# ----------------------------------------------------------------------------
# Go is kept around for Go-based dev work (building gastown/beads from source
# when you're working on a PR, running `go test` in the rig checkouts, etc.).
# The daily-driver gt/bd/gc binaries come from Linuxbrew further down — this
# Go install is NOT the install source for them.
#
# Why NOT apt: Ubuntu 22.04 ships Go 1.18; gastown requires 1.24+. Even 24.04
# may lag behind. We install the official tarball to /usr/local/go, which is
# the method the Go team recommends and gastown's INSTALLING.md also recommends.
#
# Pin GO_VERSION explicitly. Bumping is a 2-line change here when a new release
# comes out; you should NOT blindly track 'latest' for reproducibility.

GO_VERSION="1.24.12"   # Minimum required by gastown as of 2026-04

log "Installing Go $GO_VERSION..."
if command -v go &> /dev/null && go version | grep -q "go${GO_VERSION%.*}"; then
    # Already have a matching major.minor (e.g. go1.24.x) — skip.
    warn "Go $(go version | awk '{print $3}') already installed, skipping"
else
    # Detect arch so this script works on both amd64 VPSes and arm64 VPSes.
    ARCH=$(dpkg --print-architecture)  # amd64 | arm64
    GO_TARBALL="go${GO_VERSION}.linux-${ARCH}.tar.gz"
    TMP_GO="/tmp/${GO_TARBALL}"

    curl -fsSL -o "$TMP_GO" "https://go.dev/dl/${GO_TARBALL}"
    # The tarball extracts to a 'go' directory. Replace any existing install
    # atomically-ish by removing old first, then extracting fresh.
    sudo rm -rf /usr/local/go
    sudo tar -C /usr/local -xzf "$TMP_GO"
    rm -f "$TMP_GO"
    ok "Go $GO_VERSION installed to /usr/local/go"
fi

# Make sure /usr/local/go/bin and ~/go/bin are on PATH for the current shell
# AND for future shells. The bashrc block added in Step 9 includes these lines
# so they persist; here we just export for the rest of this script.
export PATH="/usr/local/go/bin:$HOME/go/bin:$PATH"

# ----------------------------------------------------------------------------
# Step 6: GitHub CLI
# ----------------------------------------------------------------------------
# gh lets you do GitHub operations from the command line without fiddling
# with tokens. Useful for creating PRs, cloning repos, managing issues.
# Install from GitHub's official apt repo (not snap, not the old package).

log "Installing GitHub CLI..."
if command -v gh &> /dev/null; then
    warn "gh already installed, skipping"
else
    # GitHub's instructions, slightly adapted for idempotency
    curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
        | sudo dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg > /dev/null 2>&1
    sudo chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
        | sudo tee /etc/apt/sources.list.d/github-cli.list > /dev/null
    sudo apt-get update -qq
    sudo apt-get install -y -qq gh
    ok "GitHub CLI installed"
fi

# ----------------------------------------------------------------------------
# Step 7: Docker (optional but useful)
# ----------------------------------------------------------------------------
# Docker is useful for:
#   - Running agents in isolated containers
#   - Running databases (Dolt can run in Docker, as can Postgres/MySQL)
#   - Reproducible environments
#
# If you don't want Docker, comment out this entire section.

log "Installing Docker..."
if command -v docker &> /dev/null; then
    warn "Docker already installed, skipping"
else
    # Remove any old Docker packages that might conflict
    sudo apt-get remove -y -qq docker docker-engine docker.io containerd runc 2>/dev/null || true

    # Docker publishes separate apt repos for Ubuntu and Debian — using the
    # wrong one gives unsigned-repo errors or 404s. Detect which one to use.
    . /etc/os-release
    case "${ID:-}" in
        ubuntu) DOCKER_DISTRO="ubuntu" ;;
        debian) DOCKER_DISTRO="debian" ;;
        *)
            warn "Unsupported distro '${ID:-unknown}' for Docker repo — skipping Docker install"
            DOCKER_DISTRO=""
            ;;
    esac
fi

if [[ -n "${DOCKER_DISTRO:-}" ]] && ! command -v docker &> /dev/null; then
    # Set up Docker's official repository for the detected distro.
    sudo install -m 0755 -d /etc/apt/keyrings
    curl -fsSL "https://download.docker.com/linux/${DOCKER_DISTRO}/gpg" | \
        sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    sudo chmod a+r /etc/apt/keyrings/docker.gpg

    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
        https://download.docker.com/linux/${DOCKER_DISTRO} ${VERSION_CODENAME} stable" | \
        sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

    sudo apt-get update -qq
    sudo apt-get install -y -qq \
        docker-ce \
        docker-ce-cli \
        containerd.io \
        docker-buildx-plugin \
        docker-compose-plugin

    # Add current user to docker group so we don't need sudo for every command.
    # NOTE: this requires logging out and back in to take effect. Until then,
    # 'docker' commands will need sudo.
    sudo usermod -aG docker "$USER"
    warn "Added $USER to docker group — log out and back in for it to take effect"

    ok "Docker installed"
fi

# ----------------------------------------------------------------------------
# Step 8: Claude Code CLI
# ----------------------------------------------------------------------------
# Claude Code is Anthropic's CLI for agentic coding tasks. Install via npm.

log "Installing Claude Code CLI..."
if command -v claude &> /dev/null; then
    warn "Claude Code already installed, skipping"
else
    npm install -g @anthropic-ai/claude-code
    ok "Claude Code installed — run 'claude' to start, you'll be prompted to auth"
fi

# ----------------------------------------------------------------------------
# Step 8a: OpenAI Codex CLI
# ----------------------------------------------------------------------------
# Codex is OpenAI's agentic coding CLI — Curtis uses it alongside claude-code,
# typically with model gpt-5.4 and reasoning_effort=xhigh. Config lives at
# ~/.codex/config.toml (Claude-equivalent of ~/.claude/).
#
# Install via npm (official distribution channel). The package is published
# as @openai/codex. First auth happens on first run ('codex login').

log "Installing OpenAI Codex CLI..."
if command -v codex &> /dev/null; then
    warn "Codex already installed, skipping"
else
    npm install -g @openai/codex
    ok "Codex installed — run 'codex login' to authenticate"
fi

# ----------------------------------------------------------------------------
# Step 8b: Atuin — shell history replacement
# ----------------------------------------------------------------------------
# Atuin replaces the default shell history with a local sqlite database that
# supports fuzzy search, per-directory context, and (optionally) E2E-encrypted
# sync across machines.
#
# Why it matters on a VPS: you live in tmux for weeks. With stock bash
# history, every new pane starts empty and history gets clobbered across
# panes. Atuin gives you a unified searchable history with fzf-style UI
# bound to Ctrl-R.
#
# Curtis runs Atuin on his laptop via nix-darwin. We install on the VPS
# using the official installer (puts binary at ~/.atuin/bin/atuin).
# Sync is OPT-IN — by default, history is local-only, which is the safer
# default on a shared host. Run 'atuin register' later if you want sync.

log "Installing Atuin (shell history)..."
if command -v atuin &> /dev/null || [[ -x "$HOME/.atuin/bin/atuin" ]]; then
    warn "Atuin already installed, skipping"
else
    # The installer writes to ~/.atuin, adds PATH export to shell rc,
    # and installs shell init for bash/zsh/fish. Safe for non-interactive
    # use (no prompts).
    curl --proto '=https' --tlsv1.2 -LsSf https://setup.atuin.sh | sh
    ok "Atuin installed — the shell-customizations block below wires up the Ctrl-R binding"
fi

# ----------------------------------------------------------------------------
# Step 8b: Install Linuxbrew (for gt / bd / gc)
# ----------------------------------------------------------------------------
# Curtis runs gt (gastown), bd (beads), and gc (gascity) on the laptop via
# Homebrew (`/opt/homebrew/bin/gt|bd|gc`). To keep the VPS parallel, we install
# Linuxbrew here and use it for the same three tools. Benefits:
#   - `brew upgrade` updates all three with one command. No pulling source,
#     no `make install`, no version drift between laptop and VPS.
#   - Matches the installation Curtis's CLAUDE.md / workflow assumes.
#   - Upstream publishes signed release binaries through goreleaser; brew
#     pulls those rather than building locally.
#
# The ~/gt/gastown/mayor/rig and ~/gt/gascity/mayor/rig checkouts (cloned by
# 06-migrate-gastown.sh) are for DEV work on those projects — not the install
# source for the binary. Don't `make install` them and overwrite the brew
# binary unless you specifically want to run your fork's build.
#
# Linuxbrew lives at /home/linuxbrew/.linuxbrew. The installer creates a
# 'linuxbrew' user and group if they don't exist, and requires sudo to write
# into /home/linuxbrew. Shell init (brew shellenv) is wired into ~/.bashrc
# in Step 9 below so future shells pick it up.

log "Installing Linuxbrew..."
BREW_PREFIX="/home/linuxbrew/.linuxbrew"
BREW_BIN="$BREW_PREFIX/bin/brew"

if [[ -x "$BREW_BIN" ]]; then
    warn "Linuxbrew already installed at $BREW_PREFIX, skipping"
else
    # Homebrew's installer prompts by default; NONINTERACTIVE=1 skips the
    # "press enter to continue" prompt, which would hang a script run.
    # CI=1 is a further non-interactive hint it honors.
    NONINTERACTIVE=1 CI=1 /bin/bash -c \
        "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    ok "Linuxbrew installed at $BREW_PREFIX"
fi

# Source brew into the current shell so the next step can use it.
# shellenv exports PATH, HOMEBREW_PREFIX, HOMEBREW_CELLAR, MANPATH, INFOPATH.
eval "$("$BREW_BIN" shellenv)"

# ----------------------------------------------------------------------------
# Step 8c: Install gt (gastown), bd (beads), gc (gascity) via brew
# ----------------------------------------------------------------------------
# Three separate calls rather than one `brew install gastown beads ...` so
# the "already installed, skipping" warning is per-tool and doesn't mask a
# partial failure.

log "Installing Gas Town binaries via brew (gt, bd, gc)..."

# gastown (gt) — homebrew-core
if command -v gt &> /dev/null && [[ "$(command -v gt)" == "$BREW_PREFIX"* ]]; then
    warn "gt already installed from brew ($(gt version 2>/dev/null | head -1)), skipping"
else
    brew install gastown
    ok "gt installed: $(gt version 2>/dev/null | head -1 || echo 'unknown')"
fi

# beads (bd) — homebrew-core, works on Linux
if command -v bd &> /dev/null && [[ "$(command -v bd)" == "$BREW_PREFIX"* ]]; then
    warn "bd already installed from brew ($(bd version 2>/dev/null | head -1)), skipping"
else
    brew install beads
    ok "bd installed: $(bd version 2>/dev/null | head -1 || echo 'unknown')"
fi

# gascity (gc) — third-party tap gastownhall/gascity
if command -v gc &> /dev/null && [[ "$(command -v gc)" == "$BREW_PREFIX"* ]]; then
    warn "gc already installed from brew ($(gc version 2>/dev/null | head -1)), skipping"
else
    install_gascity_with_brew_conflict_workaround
    ok "gc installed: $(gc version 2>/dev/null | head -1 || echo 'unknown')"
fi

# Wasteland (wl) is intentionally not installed here — it's optional for
# basic Gas Town operation, and the upstream fork/install path varies. If
# you use federation, install it separately.

# ----------------------------------------------------------------------------
# Step 9: Shell quality-of-life improvements
# ----------------------------------------------------------------------------
# Add some useful aliases and shell settings to ~/.bashrc.
# We check for an existing marker to avoid appending duplicates on re-run.

log "Configuring shell..."
BASHRC_MARKER="# === VPS setup customizations ==="
if ! grep -qF "$BASHRC_MARKER" "$HOME/.bashrc"; then
    cat >> "$HOME/.bashrc" <<'EOF'

# === VPS setup customizations ===
# Added by 01-install-dev-tools.sh

# Better history settings: larger buffer, share between sessions, no dupes
export HISTSIZE=10000
export HISTFILESIZE=20000
export HISTCONTROL=ignoredups:erasedups
shopt -s histappend
# Append to history after every command so tmux panes share history
PROMPT_COMMAND="history -a; history -n; ${PROMPT_COMMAND:-}"

# Ensure ~/.local/bin is on PATH (for pipx tools, symlinks, etc.)
case ":$PATH:" in
    *":$HOME/.local/bin:"*) ;;
    *) export PATH="$HOME/.local/bin:$PATH" ;;
esac

# uv installs to ~/.cargo/bin or ~/.local/bin depending on version
[[ -d "$HOME/.cargo/bin" ]] && export PATH="$HOME/.cargo/bin:$PATH"

# Go toolchain + any locally-built Go binaries (for dev work on gastown/beads
# from source). The daily-driver gt/bd/gc come from Linuxbrew; these paths are
# for when you're building from ~/gt/gastown/mayor/rig/ etc.
# Keep these LAST in the PATH prefixes so apt-installed tools win ties.
[[ -d "/usr/local/go/bin" ]] && export PATH="$PATH:/usr/local/go/bin"
[[ -d "$HOME/go/bin" ]] && export PATH="$PATH:$HOME/go/bin"

# Linuxbrew — source of gt (gastown), bd (beads), gc (gascity). Put this
# AFTER the go-bin lines so brew binaries take precedence over any stray
# go-install artifacts in ~/go/bin. Update these tools with `brew upgrade`.
if [[ -x /home/linuxbrew/.linuxbrew/bin/brew ]]; then
    eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"
fi

# direnv hook — loads/unloads .envrc files when you cd into a directory.
# Used by Gas Town rigs that need GT_DOLT_HOST or per-rig tokens.
command -v direnv &> /dev/null && eval "$(direnv hook bash)"

# Atuin shell history (better Ctrl-R with fuzzy search, per-dir context).
# The installer normally adds its own init, but we add it here too so the
# binding works even on shells that don't source ~/.bashrc's Atuin block
# (e.g. non-login ssh sessions). Safe to have twice — atuin init is idempotent.
[[ -x "$HOME/.atuin/bin/atuin" ]] && export PATH="$HOME/.atuin/bin:$PATH"
command -v atuin &> /dev/null && eval "$(atuin init bash --disable-up-arrow)"

# Useful aliases
alias ll='ls -alhF --color=auto'
alias la='ls -A --color=auto'
alias l='ls -CF --color=auto'
alias ..='cd ..'
alias ...='cd ../..'
alias grep='grep --color=auto'
alias df='df -h'
alias du='du -h'
alias free='free -h'

# Show CPU steal time (the Contabo noisy-neighbor check)
alias steal="vmstat 1 | awk 'NR>2 {print \"steal:\",\$16\"%\"}'"

# Quick 'what's using disk' — useful when VPS fills up
alias bigfiles='du -h --max-depth=1 | sort -rh | head -20'

EOF
    ok "Shell customizations added to ~/.bashrc"
else
    warn "Shell customizations already in ~/.bashrc, skipping"
fi

# ----------------------------------------------------------------------------
# Step 10: tmux config (minimal, sensible defaults)
# ----------------------------------------------------------------------------
# Since you'll be running long-lived agent sessions over SSH, tmux is
# essential — it keeps your sessions alive if your SSH connection drops.

log "Setting up basic tmux config..."
if [[ ! -f "$HOME/.tmux.conf" ]]; then
    cat > "$HOME/.tmux.conf" <<'EOF'
# ~/.tmux.conf — minimal sensible tmux config

# Use Ctrl-a as prefix (easier to reach than default Ctrl-b)
unbind C-b
set-option -g prefix C-a
bind-key C-a send-prefix

# Start window/pane numbering at 1 (0 is far from the other number keys)
set -g base-index 1
setw -g pane-base-index 1

# Enable mouse (scroll, click to select, resize panes)
set -g mouse on

# Longer history buffer
set -g history-limit 50000

# Reduce Esc delay (useful if you use vim inside tmux)
set -sg escape-time 10

# More intuitive split commands: | for vertical, - for horizontal
bind | split-window -h -c "#{pane_current_path}"
bind - split-window -v -c "#{pane_current_path}"
unbind '"'
unbind %

# Easy config reload
bind r source-file ~/.tmux.conf \; display-message "Config reloaded"

# Status line: a bit of color and useful info
set -g status-bg colour235
set -g status-fg colour248
set -g status-right "#[fg=colour246]%Y-%m-%d %H:%M"
EOF
    ok "Tmux config created at ~/.tmux.conf"
else
    warn "~/.tmux.conf already exists, skipping"
fi

# ----------------------------------------------------------------------------
# Final summary
# ----------------------------------------------------------------------------

echo ""
echo -e "${GREEN}==========================================================================${NC}"
echo -e "${GREEN}  Dev tools installation complete!${NC}"
echo -e "${GREEN}==========================================================================${NC}"
echo ""
echo "Installed:"
echo "  ✓ Build essentials + libs for native modules"
echo "  ✓ CLI tools: tmux, ripgrep, fd, fzf, jq, bat, tree, ncdu, tldr, mtr, mosh, restic, direnv, pv"
echo "  ✓ Node.js $(node --version 2>/dev/null || echo 'LTS') via nvm"
echo "  ✓ Python 3 + pip + pipx + uv"
echo "  ✓ Go $GO_VERSION"
echo "  ✓ GitHub CLI (gh)"
echo "  ✓ Docker (you were added to docker group — re-login to use without sudo)"
echo "  ✓ Claude Code CLI (via npm; update: npm install -g @anthropic-ai/claude-code@latest)"
echo "  ✓ OpenAI Codex CLI (via npm; update: npm install -g @openai/codex@latest)"
echo "  ✓ Atuin (Ctrl-R for fuzzy shell history)"
echo "  ✓ Linuxbrew at /home/linuxbrew/.linuxbrew"
echo "  ✓ Gas Town: gt + bd + gc (via brew; update: brew upgrade)"
echo "  ✓ Shell aliases and tmux config"
echo ""
echo "IMPORTANT: Run 'source ~/.bashrc' or log out and back in to pick up"
echo "the new PATH entries and aliases."
echo ""
echo "Next steps:"
echo "  1. source ~/.bashrc"
echo "  2. Run 02-setup-git.sh to configure git and GitHub access"
echo "  3. Run 'claude' to authenticate Claude Code"
echo "  4. Run 'codex login' to authenticate OpenAI Codex"
echo "  5. Run 'gh auth login' to authenticate GitHub CLI"
echo "  6. (Optional) 'atuin register' to sync history across machines"
echo ""
echo "Keeping things up to date:"
echo "  brew upgrade                                  # gt, bd, gc, and any other brew tools"
echo "  npm install -g @anthropic-ai/claude-code@latest  # Claude Code"
echo "  npm install -g @openai/codex@latest           # Codex"
echo "  sudo apt-get update && sudo apt-get upgrade   # system packages (also runs unattended)"
echo ""
