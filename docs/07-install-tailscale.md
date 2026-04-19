# `07-install-tailscale.sh` — Join the VPS to your tailnet

**Run as:** regular user with `sudo` on the VPS. Requires a browser session on another device (to click the Tailscale auth URL).
**Goal:** make the VPS reachable by tailnet IP/name from any authorized device, and optionally close its public SSH port entirely.

## What it does in detail

Posture note: this VPS is a **server** — inbound tailnet connections should succeed; it is not a client reaching out to route through others. That's the opposite of Curtis's laptop, which runs Tailscale with `--shields-up` because it's a client. The whole script is tuned for server posture.

1. **Refuses root.** Tailscale client needs to run as root via the daemon, but `tailscale up`/`set` are fine (and safer) via `sudo` from a normal user.
2. **Installs from the official apt repo.** Not snap, not `curl | sh`. Reason: we want security updates to flow through `unattended-upgrades` (configured by 00), which means signed apt packages. Steps: detect distro (`ubuntu` or `debian`) and codename from `/etc/os-release`, pull `{codename}.noarmor.gpg` to `/usr/share/keyrings/tailscale-archive-keyring.gpg`, pull `{codename}.tailscale-keyring.list` to `/etc/apt/sources.list.d/tailscale.list`, `apt update && apt install tailscale`.
3. **Enables the daemon.** `sudo systemctl enable --now tailscaled`.
4. **Prompts for optional Tailscale SSH.** Lets you SSH using tailnet identity instead of SSH keys — convenient on new devices, but changes your auth model (lose Tailscale access = lose SSH). Opt-in only. The prompt answer sets a `TS_SSH_FLAG` used later.
5. **Brings Tailscale up.** Two code paths:
   - **First run or logged out:** runs `sudo tailscale up --shields-up=false --accept-dns=true --accept-routes=false [--ssh]`. Shields are explicitly off (we're the destination). `--accept-dns=true` means MagicDNS works (ssh by `<hostname>.tail<slug>.ts.net` instead of by IP). `--accept-routes=false` refuses subnet routes advertised by other tailnet devices; we don't want to become a transit box for anyone.
   - **Already logged in (rerun):** doesn't re-run `tailscale up`, but does apply the current settings: `sudo tailscale set --shields-up=false` (idempotent) and `sudo tailscale set --ssh=true|false` based on the prompt answer. Previously this path skipped the `--ssh` flag, which meant toggling the prompt answer between runs had no effect on an already-up box. Fixed.
6. **Shows tailnet details.** Prints the IPv4 (via `tailscale ip -4`) and MagicDNS name (by parsing `tailscale status --json`'s `Self.DNSName`).
7. **Optional public-SSH lockdown.** Prompts whether to restrict SSH to tailnet only. If yes:
   - Reads the SSH port from `/etc/ssh/sshd_config` (set by 00).
   - `sudo ufw allow from 100.64.0.0/10 to any port <port> proto tcp` — the Tailscale CGNAT range covers every tailnet IP.
   - `sudo ufw delete allow <port>/tcp` — removes the 00-era wide-open rule. (UFW is forgiving here: if the rule isn't shaped exactly as expected, the delete no-ops and the script warns.)
   - `sudo ufw reload`.
   - Prints a prominent WARN reminding the user to verify tailnet SSH works from another device before closing the terminal.
8. **Summary** with tailnet IPv4, MagicDNS name, example SSH commands, and suggested `~/.ssh/config` block pointing at the MagicDNS name (so connections survive a public-IP change).

## Replicate manually (no script)

```bash
# --- Install ---
. /etc/os-release
curl -fsSL "https://pkgs.tailscale.com/stable/${ID}/${VERSION_CODENAME}.noarmor.gpg" \
    | sudo tee /usr/share/keyrings/tailscale-archive-keyring.gpg > /dev/null
curl -fsSL "https://pkgs.tailscale.com/stable/${ID}/${VERSION_CODENAME}.tailscale-keyring.list" \
    | sudo tee /etc/apt/sources.list.d/tailscale.list > /dev/null
sudo apt-get update
sudo apt-get install -y tailscale
sudo systemctl enable --now tailscaled

# --- Bring it up (server posture) ---
# Opt-in --ssh if you want tailnet-identity SSH
sudo tailscale up \
    --shields-up=false \
    --accept-dns=true \
    --accept-routes=false
# Follow the auth URL on another device.

# --- See tailnet details ---
tailscale ip -4
tailscale status --json | python3 -c 'import json,sys;print(json.load(sys.stdin)["Self"]["DNSName"])'

# --- Optional: lock SSH to tailnet only ---
SSH_PORT=$(sudo grep -E '^Port\s+' /etc/ssh/sshd_config | awk '{print $2}')
SSH_PORT=${SSH_PORT:-22}
sudo ufw allow from 100.64.0.0/10 to any port "$SSH_PORT" proto tcp comment 'SSH via Tailscale'
sudo ufw delete allow "$SSH_PORT/tcp"
sudo ufw reload

# --- Toggling Tailscale SSH on an already-up node ---
sudo tailscale set --ssh=true     # enable
sudo tailscale set --ssh=false    # disable
```

## Laptop-side ~/.ssh/config

After Tailscale is up, swap your SSH config on the laptop from public IP to MagicDNS:

```
Host my-vps
    HostName <vps-hostname>.tail<slug>.ts.net
    User curtis
    IdentityFile ~/.ssh/id_ed25519
    ServerAliveInterval 60
    ServerAliveCountMax 10
```

That way `ssh my-vps` works even if the VPS's public IP changes.

## Why this way

- **apt, not `curl | sh`.** We went to the trouble of setting up unattended-upgrades in 00. Installing Tailscale via apt means security updates flow through the same channel, which means you actually get them. The `curl | sh` path updates only when you manually re-run the installer.
- **Server posture (`--shields-up=false`).** `--shields-up=true` blocks inbound tailnet connections, which is right for laptops (they don't host anything) and wrong for a VPS (its whole reason for being on tailnet is to accept inbound SSH and dashboard traffic). Explicit is better than default; the comment block in the script labors this point.
- **`--accept-routes=false`.** If some other tailnet device decides to advertise itself as a subnet router, we don't want our kernel to honor those routes. On a server that hosts agent workloads, that's an unnecessary attack/misrouting surface.
- **Tailscale SSH opt-in.** It's a different auth model, not a strict improvement. If your tailnet account is compromised, Tailscale SSH gives the attacker immediate VPS shell access without needing your SSH key. For some users the convenience (SSH from a new phone without copying keys) is worth it; for others it isn't. We ask.
- **Apply `--ssh` on rerun path.** The first version of this script skipped the setting-application when Tailscale was already up, which meant changing your mind (`Y` to `N` or vice versa) on the prompt silently had no effect. The current code always calls `tailscale set --ssh=true|false` based on the prompt answer.
- **CGNAT range for UFW rule.** `100.64.0.0/10` is the fixed IP space Tailscale assigns to every tailnet node everywhere. Using a specific `100.x.y.z/32` would work for your laptop but break for your phone/another laptop/etc. The CGNAT range catches all of them.
- **Public SSH lockdown is optional.** If Tailscale ever breaks (service outage, account revoked, kernel module issue after apt upgrade), public SSH is your last way in. Leaving public SSH open trades a bit of attack surface for a working recovery path. Worth keeping until you have solid alternate recovery (VNC console creds handy, etc.).

## Known gotchas

- **Don't lock public SSH before testing tailnet SSH from another device.** The warn block is loud on purpose; if you paste `y` without verifying, you may end up using Contabo's VNC console to fix yourself.
- **MagicDNS names are global within your tailnet** (not specific to the VPS). The `.tail<slug>.ts.net` slug is unique to your account. Don't share that hostname publicly.
- **`--advertise-routes` is deliberately not set.** This VPS has nothing on its local LAN worth exposing to the tailnet. If you later want it to serve as a bastion to some internal network, that's a separate decision with different security implications — not handled here.
- **Tailscale updates can occasionally break auth flow**, which would leave you unable to re-up. The public-SSH-open fallback is why we don't force the lockdown.
- **MagicDNS requires both sides to have `--accept-dns=true`.** Most clients (laptop) default to it, but some headless installs disable DNS. Verify with `tailscale status` showing expected names.
