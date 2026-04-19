# Per-script documentation

Deep-dive docs for each script in this repo. Each page covers:

1. **What it does in detail** — step-by-step prose walkthrough of the script.
2. **Replicate manually** — the equivalent commands to run by hand if you don't want to use the script.
3. **Why this way** — design rationale for the non-obvious choices.
4. **Known gotchas** — failure modes and things that have bitten people.

## Index

| Script | Doc | One-liner |
|---|---|---|
| `00-harden.sh` | [00-harden.md](00-harden.md) | Create sudo user, lock down SSH, firewall, fail2ban, sysctl, swap |
| `01-install-dev-tools.sh` | [01-install-dev-tools.md](01-install-dev-tools.md) | Node, Python, Go, CLI tools, Docker, Claude Code, Codex, Atuin, gt+bd |
| `02-setup-git.sh` | [02-setup-git.md](02-setup-git.md) | Git config, aliases, managed global gitignore, dedicated GitHub key |
| `03-install-dolt.sh` | [03-install-dolt.md](03-install-dolt.md) | Dolt ≥ 1.82.4 + identity + optional tmpfs for hot data |
| `04-contabo-diagnostics.sh` | [04-contabo-diagnostics.md](04-contabo-diagnostics.md) | CPU steal, 4k random IOPS, memory, network — noisy-neighbor check |
| `05-export-from-laptop.sh` | [05-export-from-laptop.md](05-export-from-laptop.md) | Tarball `~/gt/.dolt-data` + `~/.claude` with sha256 manifest |
| `06-migrate-gastown.sh` | [06-migrate-gastown.md](06-migrate-gastown.md) | Clone `~/gt`, verify + extract tarballs, build gt/bd from source, start daemon |
| `07-install-tailscale.sh` | [07-install-tailscale.md](07-install-tailscale.md) | Join VPS to tailnet as server, optionally lock SSH to tailnet-only |

## Recommended reading order

- **Fresh install:** 00 → 01 → 02 → 03 → 07 → (laptop: 05) → (VPS: 06). Run 04 periodically to spot-check Contabo.
- **Understanding a specific piece:** jump straight to that script's doc — they're self-contained.
- **Doing it all by hand:** each doc's "Replicate manually" section gives you the commands in order.
