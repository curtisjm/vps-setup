#!/usr/bin/env bash
#
# 02-setup-git.sh — Configure Git and GitHub access
#
# PURPOSE:
#   Sets up git with sensible defaults and generates an SSH key for GitHub.
#   This script is interactive because it needs your name, email, and you
#   need to copy the public key to GitHub manually (one-time step).
#
# WHAT IT DOES:
#   1. Sets global git config (name, email, editor, sensible defaults)
#   2. Generates a new SSH key specifically for GitHub (if none exists)
#   3. Displays the public key for you to paste into GitHub
#   4. Tests the connection to GitHub
#   5. Sets up useful git aliases
#   6. Configures a global .gitignore for files that should never be committed
#
# USAGE:
#   Run as your normal user (NOT root):
#     chmod +x 02-setup-git.sh
#     ./02-setup-git.sh
#
# NOTES:
#   - We generate a SEPARATE SSH key for GitHub, not reusing the one you
#     use to SSH into the VPS. This is good hygiene: different keys for
#     different purposes means one compromise doesn't cascade.
#   - The key lives on the VPS only. If you want to sync to your laptop,
#     that's a separate decision.

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

# ----------------------------------------------------------------------------
# Step 1: Gather git identity
# ----------------------------------------------------------------------------
# Git requires user.name and user.email for every commit. If they're already
# set, we offer to keep them; otherwise, prompt.

log "Configuring git identity..."

CURRENT_NAME=$(git config --global user.name || echo "")
CURRENT_EMAIL=$(git config --global user.email || echo "")

if [[ -n "$CURRENT_NAME" ]]; then
    read -rp "Git name is currently '$CURRENT_NAME'. Change it? [y/N]: " CHANGE_NAME
    if [[ "$CHANGE_NAME" == "y" || "$CHANGE_NAME" == "Y" ]]; then
        read -rp "New git name: " GIT_NAME
    else
        GIT_NAME="$CURRENT_NAME"
    fi
else
    read -rp "Your name (for git commits): " GIT_NAME
fi

if [[ -n "$CURRENT_EMAIL" ]]; then
    read -rp "Git email is currently '$CURRENT_EMAIL'. Change it? [y/N]: " CHANGE_EMAIL
    if [[ "$CHANGE_EMAIL" == "y" || "$CHANGE_EMAIL" == "Y" ]]; then
        read -rp "New git email: " GIT_EMAIL
    else
        GIT_EMAIL="$CURRENT_EMAIL"
    fi
else
    # GitHub noreply email recommendation: use your GitHub noreply address
    # (e.g., 12345+username@users.noreply.github.com) to avoid leaking
    # your real email in public commits. See GitHub settings > Emails.
    echo "Tip: You can use your GitHub no-reply email (Settings > Emails on GitHub)"
    echo "     e.g., 12345+username@users.noreply.github.com"
    read -rp "Your git email: " GIT_EMAIL
fi

# ----------------------------------------------------------------------------
# Step 2: Apply git config
# ----------------------------------------------------------------------------
# These are settings most developers eventually want. Going through each:

log "Applying git global configuration..."

# Basic identity
git config --global user.name "$GIT_NAME"
git config --global user.email "$GIT_EMAIL"

# Default editor — vim is always available; change to 'nano' if you prefer
git config --global core.editor "vim"

# Default branch name for new repos — 'main' instead of 'master'
git config --global init.defaultBranch main

# When pulling, rebase by default rather than merge. This keeps history
# linear and avoids useless merge commits. You can override per-pull with
# --no-rebase if you specifically want a merge.
git config --global pull.rebase true

# Automatically set up remote tracking when you push a new branch.
# Without this, 'git push' on a new branch gives you a "no upstream" error
# and tells you to run 'git push -u origin branch-name' — annoying.
git config --global push.autoSetupRemote true

# Use a global .gitignore (configured in step 5 below) for things you NEVER
# want committed anywhere: .env files, editor swapfiles, etc.
git config --global core.excludesfile "$HOME/.gitignore_global"

# Store git's credential cache in memory for 1 hour. Only matters for HTTPS
# remotes; SSH remotes (which we'll use for GitHub) don't need this.
git config --global credential.helper "cache --timeout=3600"

# Better diff algorithm — histogram is much better than the default 'myers'
# for moved/refactored code.
git config --global diff.algorithm histogram

# Show diffs with submodule changes inline rather than "Subproject commit abc..."
git config --global diff.submodule log
git config --global status.submoduleSummary true

# Colorize output when running in a terminal (default is 'auto' on newer
# git, but explicit is better)
git config --global color.ui auto

# Rerere ("reuse recorded resolution") — remembers how you resolved merge
# conflicts and auto-applies the same resolution if the same conflict
# appears again. Useful if you rebase the same branch repeatedly.
git config --global rerere.enabled true

ok "Git config applied"

# ----------------------------------------------------------------------------
# Step 3: Git aliases
# ----------------------------------------------------------------------------
# Aliases that make common operations faster. Tuned for someone who uses
# git from the command line a lot.

log "Setting up git aliases..."

# Shorter versions of common commands
git config --global alias.st "status -sb"          # short status with branch info
git config --global alias.co "checkout"
git config --global alias.br "branch"
git config --global alias.ci "commit"
git config --global alias.cm "commit -m"
git config --global alias.ca "commit --amend"
git config --global alias.can "commit --amend --no-edit"  # amend without changing message

# Nicer log views
git config --global alias.lg "log --graph --pretty=format:'%Cred%h%Creset -%C(yellow)%d%Creset %s %Cgreen(%cr) %C(bold blue)<%an>%Creset' --abbrev-commit"
git config --global alias.last "log -1 HEAD --stat"

# Show what you'd push before pushing (useful before force-pushing)
git config --global alias.unpushed "log @{push}.."

# Undo the last commit but keep changes staged
git config --global alias.undo "reset --soft HEAD^"

# Nuke local changes (CAREFUL)
git config --global alias.nuke "reset --hard HEAD"

# Show branches sorted by last commit
git config --global alias.recent "for-each-ref --sort=-committerdate refs/heads/ --format='%(committerdate:short) %(refname:short)'"

ok "Git aliases configured"

# ----------------------------------------------------------------------------
# Step 4: Global .gitignore
# ----------------------------------------------------------------------------
# Files that should NEVER be committed to any repo. Having these in a
# global gitignore is belt-and-suspenders — you still want per-repo
# .gitignore for project-specific stuff, but this catches the universally-
# dangerous ones (secrets, editor files, OS cruft).

log "Creating global .gitignore..."

cat > "$HOME/.gitignore_global" <<'EOF'
# ~/.gitignore_global
# Files that should never be committed to any repo.
# Per-repo .gitignore is still needed for project-specific stuff.

# ----- Secrets (MOST IMPORTANT — never commit these) -----
.env
.env.*
!.env.example
!.env.template
*.pem
*.key
*.crt
secrets/
credentials.json
.netrc

# ----- Editor/IDE files -----
# Vim
*.swp
*.swo
*~
.*.swp
.*.swo

# Emacs
\#*\#
.\#*

# VSCode (but keep .vscode/ dirs that projects want to commit)
.vscode/*.log

# JetBrains IDEs
.idea/
*.iml

# Sublime
*.sublime-project
*.sublime-workspace

# ----- OS files -----
# macOS
.DS_Store
.AppleDouble
.LSOverride
._*

# Linux
.directory
.Trash-*

# Windows
Thumbs.db
Desktop.ini

# ----- Build artifacts (usually handled per-repo but good catches) -----
*.log
*.pid
*.seed
*.pid.lock

# ----- AI tool artifacts -----
.claude/
.cursor/
.aider*

EOF

ok "Global .gitignore created at ~/.gitignore_global"

# ----------------------------------------------------------------------------
# Step 5: Generate SSH key for GitHub
# ----------------------------------------------------------------------------
# We use a DIFFERENT key than the one used to SSH into the VPS.
# Reasoning: separation of concerns. If your VPS SSH key is ever
# compromised, you don't also want to give the attacker GitHub access.
#
# Key name convention: id_ed25519_github (or id_ed25519_vps etc.)
# This pattern makes it obvious what each key is for.

GITHUB_KEY="$HOME/.ssh/id_ed25519_github"

log "Setting up SSH key for GitHub..."

if [[ -f "$GITHUB_KEY" ]]; then
    warn "GitHub SSH key already exists at $GITHUB_KEY, skipping generation"
else
    log "Generating new ed25519 SSH key for GitHub..."
    # ed25519: modern, fast, small, as secure as anything
    # -N "": no passphrase (add one if you prefer — comes with UX cost)
    # -C: comment to identify the key (shows up on GitHub's key list)
    ssh-keygen -t ed25519 -f "$GITHUB_KEY" -N "" -C "github@$(hostname)"
    ok "GitHub SSH key generated"
fi

# Configure SSH to use this specific key for github.com connections.
# Without this, SSH would try the default ~/.ssh/id_ed25519 (which we
# used for VPS access) and fail.
SSH_CONFIG="$HOME/.ssh/config"
touch "$SSH_CONFIG"
chmod 600 "$SSH_CONFIG"

if ! grep -q "Host github.com" "$SSH_CONFIG"; then
    cat >> "$SSH_CONFIG" <<EOF

# GitHub — use dedicated key
Host github.com
    HostName github.com
    User git
    IdentityFile $GITHUB_KEY
    IdentitiesOnly yes
EOF
    ok "Added github.com entry to ~/.ssh/config"
else
    warn "~/.ssh/config already has a github.com entry, skipping"
fi

# ----------------------------------------------------------------------------
# Step 6: Show the public key and wait for GitHub setup
# ----------------------------------------------------------------------------
# We have to pause here because adding the key to GitHub is a manual step
# (there's no API key that could add itself — you'd need auth for that too).

echo ""
echo -e "${YELLOW}=========================================================================${NC}"
echo -e "${YELLOW}  ADD THIS PUBLIC KEY TO GITHUB${NC}"
echo -e "${YELLOW}=========================================================================${NC}"
echo ""
echo "1. Copy everything between the dashed lines:"
echo ""
echo "----- BEGIN PUBLIC KEY -----"
cat "${GITHUB_KEY}.pub"
echo "----- END PUBLIC KEY -----"
echo ""
echo "2. Go to: https://github.com/settings/ssh/new"
echo "3. Paste the key, give it a title like 'Contabo VPS $(hostname)'"
echo "4. Click 'Add SSH key'"
echo ""
read -rp "Press Enter when you've added the key to GitHub (or Ctrl+C to skip test)..."

# ----------------------------------------------------------------------------
# Step 7: Test GitHub SSH connection
# ----------------------------------------------------------------------------
# GitHub's SSH server sends a specific success message when authentication
# works: "Hi <username>! You've successfully authenticated...". It still
# returns exit code 1 (because you can't actually open an interactive
# shell on github.com), so we check stdout not exit code.

log "Testing GitHub SSH connection..."

# StrictHostKeyChecking=accept-new auto-accepts github.com's host key the
# first time (rather than prompting) — safe because we're connecting to
# a well-known host for the first time from this fresh VPS.
TEST_OUTPUT=$(ssh -o StrictHostKeyChecking=accept-new -T git@github.com 2>&1 || true)

if echo "$TEST_OUTPUT" | grep -q "successfully authenticated"; then
    ok "GitHub SSH authentication works!"
    echo "    $TEST_OUTPUT"
elif echo "$TEST_OUTPUT" | grep -q "Permission denied"; then
    error "GitHub rejected the key. Did you add it to GitHub? Output:"
    echo "    $TEST_OUTPUT"
    exit 1
else
    warn "Unexpected output from GitHub SSH test:"
    echo "    $TEST_OUTPUT"
    warn "Check manually with: ssh -T git@github.com"
fi

# ----------------------------------------------------------------------------
# Step 8: GitHub CLI auth (if gh is installed)
# ----------------------------------------------------------------------------
# gh works separately from git — it needs its own auth for API operations
# (creating PRs, cloning private repos by name, etc.). Device flow is
# easiest: it gives you a code to paste at github.com/login/device.

if command -v gh &> /dev/null; then
    if gh auth status &> /dev/null; then
        warn "gh already authenticated, skipping"
    else
        echo ""
        log "Authenticating GitHub CLI (gh)..."
        log "Choose 'GitHub.com', then 'SSH', then 'Login with a web browser'"
        log "You'll get a one-time code to paste at https://github.com/login/device"
        echo ""
        read -rp "Press Enter to start gh auth..."
        gh auth login
    fi
fi

# ----------------------------------------------------------------------------
# Final summary
# ----------------------------------------------------------------------------

echo ""
echo -e "${GREEN}==========================================================================${NC}"
echo -e "${GREEN}  Git setup complete!${NC}"
echo -e "${GREEN}==========================================================================${NC}"
echo ""
echo "Configured:"
echo "  ✓ Git identity: $GIT_NAME <$GIT_EMAIL>"
echo "  ✓ Sensible git defaults (main branch, rebase pulls, autoSetupRemote)"
echo "  ✓ Git aliases (st, co, lg, etc.)"
echo "  ✓ Global .gitignore"
echo "  ✓ Dedicated SSH key for GitHub at $GITHUB_KEY"
echo "  ✓ SSH config entry for github.com"
echo ""
echo "Test it:"
echo "  ssh -T git@github.com                           # should greet you by name"
echo "  git clone git@github.com:yourusername/repo.git  # should work"
echo ""
echo "Next steps:"
echo "  - Run 03-install-dolt.sh to install Dolt for Gas Town bead storage"
echo ""
