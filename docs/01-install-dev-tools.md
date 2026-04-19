# `01-install-dev-tools.sh` — Developer tooling

**Run as:** regular (non-root) user with `sudo` access.
**Goal:** install everything you'd curse the absence of five minutes into real work: languages, CLI tools, Docker, Claude Code, Codex, Atuin, the Gas Town binaries.

## What it does in detail

1. **Pre-flight.** Refuses to run as root (nvm, pipx, Atuin all install per-user and would end up in `/root` if you ran this as root). Calls `sudo -v` once up front so the script isn't prompting for your password mid-install.
2. **Build essentials.** `build-essential`, `pkg-config`, `libssl-dev`, `libffi-dev`, `zlib1g-dev`, `libbz2-dev`, `libreadline-dev`, `libsqlite3-dev`, `libncursesw5-dev`, `xz-utils`, `tk-dev`, `libxml2-dev`, `libxmlsec1-dev`, `liblzma-dev`, and `bc`. Without these, anything that compiles native code (most real npm/pip packages) will fail mysteriously. `bc` specifically is pulled in because `04-contabo-diagnostics.sh` uses it both for the CPU stress loop and float comparisons in the verdict block — Ubuntu Server minimal doesn't ship it.
3. **CLI productivity tools.** `tmux`, `ripgrep`, `fd-find`, `fzf`, `jq`, `bat`, `tree`, `ncdu`, `tldr`, `mtr-tiny`, `mosh`, `restic`, `direnv`, `make`, `pv`, `unzip`, `zip`, `vim`, `nano`, `less`. On Ubuntu, `bat` installs as `batcat` and `fd` as `fdfind` (to avoid name collisions with other packages); the script symlinks them to `~/.local/bin/{bat,fd}` so they work under the expected names.
4. **Node via nvm.** Installs nvm v0.40.1 via the official installer, sources it into the current shell, then `nvm install --lts && nvm use --lts && nvm alias default lts/*`. Deliberately avoids `apt install nodejs` because Ubuntu's Node is usually 1–2 years stale, and nvm lets you switch versions per-project for AI tools that need specific Node versions.
5. **Python tooling.** `python3`, `python3-pip`, `python3-venv`, `python3-dev`, `pipx`. Calls `pipx ensurepath` to add its bin dir to `PATH`.
6. **uv.** Installs via `curl ... | sh` from `astral.sh/uv`. uv is the de facto Python package manager for modern AI tooling; having it installed costs nothing even if you don't use it directly.
7. **Go toolchain.** Downloads Go 1.24.12 (pinned in the script) from `go.dev/dl/`, removes any old `/usr/local/go`, extracts the tarball into `/usr/local`. Arch-aware: uses `dpkg --print-architecture` to fetch `amd64` or `arm64`. `apt` is explicitly avoided because Ubuntu 22.04 ships Go 1.18 and 24.04 ships something older than what gastown requires (1.24+). `PATH` is exported for the rest of this script; the bashrc block in step 15 makes it permanent.
8. **GitHub CLI (`gh`).** Adds GitHub's apt keyring and repo, then `apt install gh`. Not snap — snap Node/gh are both slower to start and weird about home-dir access.
9. **Docker.** Removes any conflicting old Docker packages, detects the distro via `/etc/os-release` (branches between `ubuntu` and `debian` repo URLs), adds Docker's keyring and repo, installs `docker-ce`, `docker-ce-cli`, `containerd.io`, `docker-buildx-plugin`, `docker-compose-plugin`, and adds the current user to the `docker` group. You need to log out and back in for group membership to take effect.
10. **Claude Code CLI.** `npm install -g @anthropic-ai/claude-code`. First-run auth happens when you invoke `claude`.
11. **OpenAI Codex CLI.** `npm install -g @openai/codex`. First-run auth is `codex login`.
12. **Atuin.** Shell history replacement with fuzzy search, per-directory context, and optional E2E-encrypted sync. Installs via the official installer from `setup.atuin.sh`, which drops a binary at `~/.atuin/bin/atuin`. Sync is opt-in — the default is local-only, which is saner on a VPS.
13. **Gas Town binaries.** `go install github.com/steveyegge/gastown/cmd/gt@latest` and `github.com/steveyegge/beads/cmd/bd@latest`. Lands binaries in `~/go/bin`. Wasteland (`wl`) is skipped — optional, and you might want it from a fork.
14. **Shell customizations.** Appends a marker-gated block to `~/.bashrc` with: HISTSIZE/HISTFILESIZE, shared history across tmux panes, PATH additions for `~/.local/bin`, `~/.cargo/bin`, `/usr/local/go/bin`, `~/go/bin`, `~/.atuin/bin`, `direnv hook bash`, `atuin init bash --disable-up-arrow`, a small set of aliases (`ll`, `la`, `..`, `grep --color`, `df -h`, etc.), and two diagnostic aliases: `steal` (watches vmstat's `st` column, the Contabo noisy-neighbor metric) and `bigfiles` (top 20 disk-users in CWD).
15. **tmux config.** Writes a minimal `~/.tmux.conf` if one doesn't exist: Ctrl-a prefix (easier than Ctrl-b), mouse on, 50k history, `|` and `-` for splits, pane numbering from 1.

The marker (`# === VPS setup customizations ===`) guards against duplicate appends on rerun; the tmux config is only written if the file doesn't exist (so personal tweaks survive). Most steps have a `command -v <tool> && skip` idiom so rerunning the script is safe.

## Replicate manually (no script)

```bash
# --- Build essentials ---
sudo apt-get update
sudo apt-get install -y build-essential pkg-config libssl-dev libffi-dev \
    zlib1g-dev libbz2-dev libreadline-dev libsqlite3-dev libncursesw5-dev \
    xz-utils tk-dev libxml2-dev libxmlsec1-dev liblzma-dev bc

# --- CLI tools ---
sudo apt-get install -y tmux ripgrep fd-find fzf jq bat tree ncdu tldr \
    mtr-tiny mosh restic direnv make pv unzip zip vim nano less
mkdir -p ~/.local/bin
ln -sf /usr/bin/batcat ~/.local/bin/bat
ln -sf /usr/bin/fdfind ~/.local/bin/fd

# --- Node via nvm ---
curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash
export NVM_DIR="$HOME/.nvm"
. "$NVM_DIR/nvm.sh"
nvm install --lts && nvm alias default lts/*

# --- Python ---
sudo apt-get install -y python3 python3-pip python3-venv python3-dev pipx
pipx ensurepath

# --- uv ---
curl -LsSf https://astral.sh/uv/install.sh | sh

# --- Go ---
GO_VERSION=1.24.12
ARCH=$(dpkg --print-architecture)
curl -fsSL -o /tmp/go.tar.gz "https://go.dev/dl/go${GO_VERSION}.linux-${ARCH}.tar.gz"
sudo rm -rf /usr/local/go
sudo tar -C /usr/local -xzf /tmp/go.tar.gz
export PATH="/usr/local/go/bin:$HOME/go/bin:$PATH"

# --- GitHub CLI ---
curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
    | sudo dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg
sudo chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
    | sudo tee /etc/apt/sources.list.d/github-cli.list
sudo apt-get update && sudo apt-get install -y gh

# --- Docker (Ubuntu shown; swap 'ubuntu' -> 'debian' on Debian) ---
sudo apt-get remove -y docker docker-engine docker.io containerd runc 2>/dev/null || true
sudo install -m 0755 -d /etc/apt/keyrings
. /etc/os-release  # for VERSION_CODENAME
curl -fsSL "https://download.docker.com/linux/${ID}/gpg" \
    | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
sudo chmod a+r /etc/apt/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/${ID} ${VERSION_CODENAME} stable" \
    | sudo tee /etc/apt/sources.list.d/docker.list
sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io \
    docker-buildx-plugin docker-compose-plugin
sudo usermod -aG docker "$USER"   # re-login required

# --- CLIs via npm ---
npm install -g @anthropic-ai/claude-code
npm install -g @openai/codex

# --- Atuin ---
curl --proto '=https' --tlsv1.2 -LsSf https://setup.atuin.sh | sh

# --- Gas Town binaries ---
mkdir -p ~/go/bin
go install github.com/steveyegge/gastown/cmd/gt@latest
go install github.com/steveyegge/beads/cmd/bd@latest

# --- Bashrc block (abbreviated; see the script for the full version) ---
cat >> ~/.bashrc <<'EOF'

# === VPS setup customizations ===
export HISTSIZE=10000 HISTFILESIZE=20000 HISTCONTROL=ignoredups:erasedups
shopt -s histappend
PROMPT_COMMAND="history -a; history -n; ${PROMPT_COMMAND:-}"
case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) export PATH="$HOME/.local/bin:$PATH" ;; esac
[[ -d /usr/local/go/bin ]] && export PATH="$PATH:/usr/local/go/bin"
[[ -d $HOME/go/bin ]]      && export PATH="$PATH:$HOME/go/bin"
[[ -x $HOME/.atuin/bin/atuin ]] && export PATH="$HOME/.atuin/bin:$PATH"
command -v direnv &>/dev/null && eval "$(direnv hook bash)"
command -v atuin  &>/dev/null && eval "$(atuin init bash --disable-up-arrow)"
alias ll='ls -alhF --color=auto'
alias steal="vmstat 1 | awk 'NR>2 {print \"steal:\",\$16\"%\"}'"
EOF

source ~/.bashrc
```

## Why this way

- **`go install @latest` for gt/bd** (not a binary release): upstream doesn't ship per-commit binaries, and `go install` gives you a build reproducibly tied to your local Go toolchain. `06-migrate-gastown.sh` will overwrite these with `make install` from your tracked `~/gt` checkout if you want the exact commit your laptop is on.
- **Pinned Go version (1.24.12).** Tracking `latest` silently shifts your toolchain under you. Bumping is a one-line edit when gastown's minimum moves.
- **Arch detection.** `dpkg --print-architecture` means this works on both amd64 Contabo VPSes and arm64 Hetzner/Oracle boxes without editing the script.
- **`pipx` for Python CLIs, `pip` for libraries.** Breaking `pip install --user` into the system site-packages is the #1 way to end up with unrelentingly bizarre Python errors. `pipx` gives each CLI its own venv.
- **Atuin with `--disable-up-arrow`.** The default binds Atuin to Up Arrow in addition to Ctrl-R, which overrides the vanilla shell history behaviour you're still used to. Most people prefer to keep Up Arrow doing what it always did.
- **Docker is optional but kept in.** If you don't want it, comment out the Docker block. The script's designed so skipping it doesn't break anything downstream.
- **Idempotent.** Every step either checks for the tool first (`command -v ...`) or uses a marker in bashrc. You can rerun this entire script any time and it won't double-up on PATH entries or re-install Go.

## Known gotchas

- **Docker requires re-login** before `docker` works without `sudo`. The script warns about this but doesn't force it — you can just log out and back in after the script finishes.
- **`source ~/.bashrc`** is required at the end for the new PATH and aliases to take effect in your current shell. Don't skip this and then wonder why `gt` isn't found.
- **`npm install -g` global flags.** The CLAUDE.md policy here is "no homebrew installs" — we're on Linux so this is moot, but worth noting that globally-installed npm packages install into nvm's current node prefix (`~/.nvm/versions/node/...`). Switching Node versions will switch which global packages are visible; reinstall if that bites you.
- **Codex and Claude Code first-run auth.** Both need browser-based auth. On a headless VPS, they print a URL you open on your laptop, paste the code, and that's it.
- **Atuin sync is off by default.** If you want cross-machine history, run `atuin register` then `atuin sync` — but be aware the server has your full shell history (E2E encrypted, but still a trust decision).
