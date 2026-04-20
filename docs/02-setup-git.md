# `02-setup-git.sh` — Git configuration and GitHub SSH

**Run as:** regular user (interactive — needs your name, email, and a GitHub browser session).
**Goal:** a sensibly-configured git, a dedicated SSH key for GitHub, and a working `gh` login.

## What it does in detail

1. **Refuses to run as root.** Git config is per-user; running as root would set `root`'s identity, not yours.
2. **Gathers identity.** If `git config --global user.name/email` are already set (from a prior run), offers to keep them; otherwise prompts. Suggests the GitHub no-reply email (`12345+username@users.noreply.github.com`) so you don't leak your real address in public commit history.
3. **Applies global git config.** Each value is a considered choice:
   - `core.editor = vim` (swap to nano if you prefer; always available).
   - `init.defaultBranch = main` — matches GitHub's current default.
   - `pull.rebase = true` — keeps history linear, avoids vestigial merge commits. Override per-pull with `--no-rebase`.
   - `push.autoSetupRemote = true` — no more "the current branch has no upstream" lecture on first push.
   - `core.excludesfile = ~/.gitignore_global` — points at the managed global gitignore set up below.
   - `credential.helper = cache --timeout=3600` — stops HTTPS prompts for an hour at a time (harmless since GitHub is SSH).
   - `diff.algorithm = histogram` — significantly better than Myers default for moved/refactored code.
   - `diff.submodule = log`, `status.submoduleSummary = true` — shows real diff content instead of `Subproject commit abc123...def456`.
   - `color.ui = auto`.
   - `rerere.enabled = true` — records conflict resolutions and replays them; invaluable if you rebase the same branch repeatedly.
4. **Git aliases.** `st`, `co`, `br`, `ci`, `cm`, `ca`, `can`, plus a graph `lg`, `last`, `unpushed` (log of commits ahead of `@{push}`), `undo` (soft reset HEAD~1), `nuke` (hard reset HEAD — destructive, used rarely), and `recent` (branches by committerdate).
5. **Managed-block `~/.gitignore_global`.** Writes a BEGIN/END-marker-gated block containing secrets patterns (`.env`, `.env.*` with `!` overrides for `.env.example`/`.env.template`, `*.pem`, `*.key`, `*.crt`, `secrets/`, `credentials.json`, `.netrc`), editor cruft (`*.swp`, `*~`, Emacs lock files, `.idea/`, `*.iml`, Sublime workspaces), OS files (`.DS_Store`, `._*`, `Thumbs.db`, `Desktop.ini`), build junk (`*.log`, `*.pid`), and AI-tool artifacts (`.claude/`, `.cursor/`, `.aider*`). Uses awk to replace the block in place on rerun so any user additions *outside* the markers survive.
6. **GitHub SSH key.** Generates `~/.ssh/id_ed25519_github` (ed25519, no passphrase, comment `github@<hostname>`) if it doesn't exist. Separate from the VPS-login key on purpose — so a compromise of one doesn't cascade.
7. **`~/.ssh/config`: `Host github.com` block.** Creates `~/.ssh/` if needed, then adds `IdentityFile`, `IdentitiesOnly yes` etc. if no exact `Host github.com` block exists. That exact-match part matters: `Host github.com-work` should not count. If a real github.com block already exists, the script uses `ssh -G github.com` to check whether it resolves to our dedicated key; if not, warns loudly and refuses to edit — you probably configured something on purpose and we don't want to silently point github.com at a different key.
8. **Manual-pause for GitHub key upload.** Prints the public key and instructions, waits for Enter. This is a human-in-the-loop step: there's no API to register an SSH key without already having credentials.
9. **Tests the SSH connection.** `ssh -o StrictHostKeyChecking=accept-new -T git@github.com` — matches on the "successfully authenticated" string rather than exit code (GitHub SSH always returns 1 since interactive shells aren't allowed).
10. **`gh` auth.** If `gh` is installed and not already authenticated, runs `gh auth login` interactively (device flow — paste a code at `github.com/login/device`).

## Replicate manually (no script)

```bash
# --- Identity ---
git config --global user.name "Curtis Mitchell"
git config --global user.email "12345+curtisjm@users.noreply.github.com"

# --- Defaults ---
git config --global core.editor vim
git config --global init.defaultBranch main
git config --global pull.rebase true
git config --global push.autoSetupRemote true
git config --global core.excludesfile "$HOME/.gitignore_global"
git config --global credential.helper "cache --timeout=3600"
git config --global diff.algorithm histogram
git config --global diff.submodule log
git config --global status.submoduleSummary true
git config --global color.ui auto
git config --global rerere.enabled true

# --- Aliases ---
git config --global alias.st "status -sb"
git config --global alias.co checkout
git config --global alias.br branch
git config --global alias.ci commit
git config --global alias.cm "commit -m"
git config --global alias.ca "commit --amend"
git config --global alias.can "commit --amend --no-edit"
git config --global alias.lg "log --graph --pretty=format:'%Cred%h%Creset -%C(yellow)%d%Creset %s %Cgreen(%cr) %C(bold blue)<%an>%Creset' --abbrev-commit"
git config --global alias.last "log -1 HEAD --stat"
git config --global alias.unpushed "log @{push}.."
git config --global alias.undo "reset --soft HEAD^"
git config --global alias.nuke "reset --hard HEAD"
git config --global alias.recent "for-each-ref --sort=-committerdate refs/heads/ --format='%(committerdate:short) %(refname:short)'"

# --- Global gitignore ---
cat > ~/.gitignore_global <<'EOF'
# === vps-setup managed block — do not edit between markers ===
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
*.swp
*.swo
*~
.DS_Store
._*
Thumbs.db
.claude/
.cursor/
.aider*
# === end vps-setup managed block ===
EOF

# --- GitHub SSH key (separate from VPS-login key) ---
ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519_github -N "" -C "github@$(hostname)"

# --- ~/.ssh/config ---
cat >> ~/.ssh/config <<EOF

Host github.com
    HostName github.com
    User git
    IdentityFile ~/.ssh/id_ed25519_github
    IdentitiesOnly yes
EOF
chmod 600 ~/.ssh/config

# --- Manual: copy public key to github.com/settings/ssh/new ---
cat ~/.ssh/id_ed25519_github.pub

# --- Test ---
ssh -T git@github.com   # expect "Hi <username>! You've successfully authenticated..."

# --- gh CLI auth (if installed) ---
gh auth login           # choose GitHub.com → SSH → browser
```

## Why this way

- **Dedicated GitHub key.** If your VPS login key leaks, the attacker doesn't automatically get push access to your repos. Small blast radius > shared-key convenience.
- **`IdentitiesOnly yes`.** Without it, SSH offers every key in `~/.ssh/*` to every server. Large agent keychains have been known to trip GitHub's "too many auth attempts" rate limit and lock you out of your own account for minutes.
- **Managed gitignore block.** The user will want to add things we didn't think of. Overwriting the file on rerun silently loses those additions; markers make it editable from both sides.
- **`ssh -G github.com`** (not a naive `grep IdentityFile`): respects the SSH config parser's actual view of inheritance and per-host blocks. A `grep` would false-positive on a commented-out line or the wrong block.
- **Histogram diff algorithm.** Catches moved code that Myers' default misclassifies as delete+add. Noticeable on any real refactor.
- **`rerere`.** Free: zero cost when not in use, saves you from re-solving the same rebase conflict twice.

## Known gotchas

- **Existing `Host github.com` block with a different key.** The script refuses to edit it and prints the effective IdentityFile. Edit by hand, decide whether to keep the existing block or rewrite it.
- **`gh` auth lives separately** from SSH — it talks to GitHub's REST API, not git. Running `gh auth login` is a separate step and the script handles it only if `gh` is already on PATH (installed by `01-install-dev-tools.sh`).
- **No passphrase on the GitHub key.** Convenient, but if you want one: re-run `ssh-keygen -p -f ~/.ssh/id_ed25519_github` to add one after the fact. You'll need to `ssh-add` once per session, or use `ssh-agent`/keychain.
- **Global gitignore patterns affect ALL your repos.** If you ever want to commit a `.env.example` on a project that has `.env.example` in a subdir, the `!` override in the managed block handles it. For other patterns, you may need a local `.gitignore` with an explicit `!pattern` to un-ignore.
