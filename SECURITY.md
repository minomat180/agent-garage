# Security policy

Report vulnerabilities privately through
[GitHub Security Advisories](https://github.com/minomat180/agent-garage/security/advisories/new),
not in a public issue.

## What is at stake

agent-garage lets other people run coding agents, with root inside their own
VM, on the host admin's hardware and internet connection. The security model is in
[docs/security.md](docs/security.md); the short version of the trust
boundary:

What the platform enforces:

- Each bay is a separate microVM (cloud-hypervisor, own kernel) that boots
  from an image of its own closure. No host path is shared into it: not the
  host's `/nix/store`, not a home directory, not a socket.
- A bay can reach the public internet and nothing else: nftables on the host
  drops traffic to the host, private and special ranges (LAN, tailnet,
  link-local, CGNAT), the other bays, outgoing TCP 25 and all IPv6. Bridge
  ports are isolated and pinned to one MAC and one address per bay.
- The only way in is Cloudflare Access (GitLab login, then a passkey or
  security key), and cloudflared checks the Access token again before a
  request reaches the bay. There is no SSH server and no tailnet or LAN port.
- `sudo garage test <bay>` checks most of the above on the running host;
  [docs/security.md](docs/security.md#known-gaps) lists what is verified only
  by configuration.

What it does not protect against:

- **The host admin.** Whoever has root on the host can read every file,
  process and packet of every bay; the module does not encrypt bay disks. Friends are told
  this before they get access ([docs/bay-guide.md](docs/bay-guide.md)).
- **A hypervisor or kernel escape.** The VM boundary is the main control. The
  hypervisor runs unprivileged and sandboxed by systemd, which limits but does
  not rule out damage after an escape.
- **What an agent does on the internet.** Agents inside a bay run with full
  permissions by design. Prompt injection, leaked tokens and abuse of
  third-party services stay inside that bay's accounts, but traffic from a bay
  without VPN egress leaves from the host's public IP.
- **Cloudflare and GitLab.** Both sit in the login path; a compromise of
  either, or of the admin's Cloudflare account, affects who can reach a bay.

Issues of particular interest: any way from inside a bay to reach the host, the
LAN, the tailnet or another bay; any request that reaches a bay without a valid
Access token for that bay; anything that makes a VPN bay send traffic out of
the uplink.
