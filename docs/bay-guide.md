# Your bay: a short guide

A bay is your own Linux machine (a NixOS virtual machine) on a server run by
your host admin, with Claude Code, T3 Code, git and Nix installed. You use it from a
browser at your own address, which the admin sends you (`https://<you>-garage.<domain>`).
Only your own GitLab account can open it.

## First login (about 5 minutes)

1. Open your bay's address and sign in with GitLab.
2. Right away, register a passkey or security key at
   `https://<team>.cloudflareaccess.com/AddMfaDevice`; the admin sends you the exact
   link (`<team>` is the name in the address bar during the Cloudflare login).
   Use Touch ID, Windows Hello, a phone passkey or a YubiKey. The first device
   needs no second factor, so do this at once, before anyone else could.
   Adding more devices later needs one you already have. Every login after
   that is GitLab plus the passkey; a login lasts 12 hours.
3. The admin sends you a one-time T3 pairing link. It is valid for 15 minutes and
   works once. Open it in the same browser after step 1. If it expired, ask
   for a new one.
4. Turn on two-factor authentication on your GitLab account too, and use a
   password you use nowhere else.

## Inside the bay

- You are user `bay` with `sudo` (no password). The T3 terminal is your shell.
- `/home` is your own 100 GB disk. Nothing else is shared with anyone.
- Installed: `claude`, `git`, `gh`, `glab`, `node`, `tmux`, `nix` (flakes on).
  For more tools, use a flake in your project (`nix develop`, `nix shell`).
- The bay can be restarted for updates (announced in advance). Running
  processes stop; files in `/home` stay.

## Accounts and keys: always your own

- Log in to Claude Code (`claude`, then `/login`) or any other model provider
  with your **own** subscription or API key. Never use the admin's account or
  anyone else's: Anthropic's terms do not allow sharing an account, and it
  would be billed to them.
- Bring your own GitHub or GitLab tokens. Make them narrow: fine-grained,
  only the repositories you need, with an expiry date.
- Your agents can read every file in the bay. Do not keep secrets in plain
  files you do not need, and never paste them into a chat with an agent.

## Your work: push it

The bay disk is **not a backup**. Push everything you care about to your own
git remote (GitHub, GitLab) often. If the bay breaks, it is rebuilt empty.

## Privacy

The bay runs on the admin's hardware. The admin can technically see
everything in the bay: files, processes, network traffic. Treat it like a
shared server, not like your own laptop. Login events (who, when) are logged
by Cloudflare; the server keeps normal system logs.

## Network rules

Your traffic leaves from the admin's internet connection, so anything done
from the bay looks like it came from them. Some bays leave through a VPN
instead: sites then see the VPN's address, the bay has no internet at all
while the VPN is down, and the VPN provider can see where your traffic goes,
so the same rules apply.

- Allowed: normal internet use (websites, APIs, git, package downloads).
- Not allowed: scanning or attacking any system, sending mail, spam, load
  tests against services you do not own, anything illegal.
- Blocked by design: outgoing mail (port 25), the admin's home network, the server
  itself and other people's bays. Do not try to get around this, and do not
  let your agents try.
- If something you need is blocked, ask instead of working around it.

## Help

Ask the admin directly (the way you usually reach them). Useful to include: your
bay address, what you did, what you expected, and the exact error text.
Lost your passkey? The admin can reset it; then you register a new one as in
step 2. To stop using the bay, tell the admin; the disk is deleted.
