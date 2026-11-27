# agent-garage: design

Each friend gets a "bay": an isolated NixOS microVM on one host, with Claude
Code, T3 Code and Nix, reachable from a browser at a public URL behind a
login. This page is the design and the reasoning behind it: the goals, the
options that were rejected, the threat model and the acceptance tests.
[security.md](security.md) is the short current state; the
[README](../README.md) is how to run it.

The people involved: the **host admin** runs the host and the Cloudflare
account; a **friend** owns one bay.

## 1. Goal and non-goals

Goal

- 1 to 3 friends at a time log in from a browser, get their own T3 Code, and
  run Claude Code with subagents and Nix, with full root inside their own
  machine.
- Each bay has its own disk, its own CPU and RAM cap, its own secrets.
- A friend can break their bay completely without touching the host admin's
  setup, their home network or another friend.
- Everything is declared in Nix and OpenTofu; adding a friend is one attrset
  in the site file, `garage-cf apply` and `export`, and a `nixos-rebuild`.

Non-goals

- Running agents on the friends' own PCs.
- Sharing one Claude subscription (not allowed, see section 4).
- Billing, self-service sign-up, more bays than the hardware holds.
- Any login code of our own: authentication is Cloudflare Access + the
  identity provider, authorization inside a bay is T3's own pairing.

## 2. Architecture

```text
friend's browser
  |  https://<friend>-garage.<zone>
  v
Cloudflare edge
  Access app per bay, one allow rule: that friend's GitLab user id (OIDC "sub")
  login at GitLab (OIDC)  ->  Cloudflare independent MFA (passkey / security key)
  |
  |  Cloudflare Tunnel (outbound from the host; no inbound port, firewall unchanged)
  v
host (NixOS)
  cloudflared: hostname -> bay IP:3773, checks the Access JWT again (aud + team)
  nftables: bays reach the public internet only; host, LAN, tailnet, other bays dropped
  |
  +-- bay-<friend>  microVM (cloud-hypervisor, own kernel, unprivileged on the host)
  |     t3 serve on the bay's address + Claude Code
  |     own Nix store image (guest closure only) + volume for /home and builds
  +-- bay-<next friend> ...
```

Why each piece

- **microVM (microvm.nix), not a container.** Friends run agents with full
  permissions and root. A container shares the host kernel; a VM does not, so
  a kernel exploit inside a bay stays inside it. microvm.nix declares VMs as
  NixOS config with fixed vCPU/RAM and volume images.
- **Own store image per bay, not the host's /nix/store.** Sharing the host
  store read-only is cheaper on disk but shows a bay every path on the host
  (all of the admin's installed software and config). Each bay instead boots
  from an image of its own closure, plus a writable store on its volume.
- **T3 Code per bay.** T3's server is single-owner (one owner, several paired
  devices; no user accounts). One instance per bay fits that model exactly.
- **Cloudflare Tunnel + Access.** The tunnel dials out, so the host's firewall
  stays closed. Access is free up to 50 users and does the login before any
  packet reaches the host.
- **No extra reverse proxy.** cloudflared routes each hostname straight to its
  bay and validates the Access token itself (`originRequest.access`). One
  component less to patch.
- **One-level hostnames** (`<friend>-garage.<zone>`): Cloudflare's free
  Universal SSL covers only one wildcard level.

## 3. Prior art checked (2026-11)

- **Coder** (coder.com, AGPLv3, v2.39, `services.coder` in nixpkgs): the
  closest off-the-shelf product. Rejected: no VM (libvirt/QEMU) template, no
  per-workspace disk limit, quotas and groups are Premium, per-user Claude
  logins go through its AI Gateway (Premium), Coder Tasks was removed, needs
  4 GB RAM for itself, and friends would not get T3.
- **T3 Code** (MIT): single owner per server, pairing codes and bearer
  sessions, `--base-dir` for separate instances, `T3CODE_HOST`/`T3CODE_PORT`.
  No user accounts, so one instance per bay.
- **microvm.nix** + Michael Stapelberg's "Coding agent VMs on NixOS"
  (2026-02): the base for bays (cloud-hypervisor, volume images, NAT bridge).
- **Containers** (nixos-container, Docker, Incus system containers): rejected
  for untrusted root workloads; they share the host kernel.
- **Tailscale Funnel**: public, but only on `*.ts.net` names and without a
  login in front; Cloudflare Access gives the login gate.
- **Own identity provider** (Pocket ID, Authelia, Kanidm): rejected for now;
  one more public service to patch for 1 to 3 users.

## 4. Credentials: what each friend brings

| What | Where it lives | Who sees it |
| --- | --- | --- |
| Model access, the friend's choice: own Claude subscription login, own Anthropic API key, or own third-party provider credential (Bedrock, Vertex, Foundry) | inside their bay only, entered by the friend; subscription sign-in through Anthropic's own flow | only that bay |
| GitHub / GitLab token (fine-grained, expiring, repo-scoped) | inside their bay | only that bay |
| Garage login | their GitLab account at gitlab.com, then MFA at Cloudflare | GitLab and Cloudflare; never the host |

- Anthropic (code.claude.com/docs/en/legal-and-compliance, read 2026-11-23):
  "Each end user must authenticate with their own Anthropic API key, Claude
  subscription plan credentials, or 3P inference provider credential", and
  platforms "may not pay for, resell, or intermediate Claude usage on their end
  users' behalf". The admin's `~/.claude` is never mounted into a bay; bays
  ship the unmodified `claude` binary.
- Nobody hands the admin or the host a password. A friend types their GitLab
  password only on gitlab.com.

## 5. Identity and login

- Identity provider: gitlab.com, added to Cloudflare Access as a generic OIDC
  provider (scopes `openid profile`; no repository scopes).
- Allow rule per bay: OIDC claim `sub` equals the friend's numeric GitLab user
  id. Not the username (it can be renamed and then re-registered by someone
  else) and not the email (GitLab only sends it if the profile email is public).
- Cloudflare independent MFA on every bay app: WebAuthn only (passkey or
  security key; phishing resistant). No TOTP, no email one-time PIN fallback.
- Session: 12 h app session, re-auth after.
- Default deny: the Access organisation has no catch-all allow; an app without
  a rule is unreachable. Hostnames that are not a bay fall through to a 404
  service in cloudflared, never to a bay.
- Inside the bay: T3 accepts only devices paired with a one-time link that the
  admin hands the friend once, out of band (`garage pair <bay>`).
- Each friend's numeric user id is read from the GitLab API (by username) when
  their bay is added; only the id goes into the site file.

## 6. Security baseline

The service faces the internet, so the bar is: current OWASP guidance, least
privilege everywhere, nothing custom where a maintained component exists, and
every component on its current release. Standards used (versions checked
2026-11-23): OWASP Top 10:2025, OWASP Top 10 for Agentic Applications 2026,
OWASP ASVS 5.0.0 (level 2 for the parts that are ours).

### 6.1 Threat model

| Threat | Who | Main control |
| --- | --- | --- |
| Stranger reaches a bay | internet | Access default deny, `sub` rule, WebAuthn MFA, tunnel only |
| Friend's GitLab account stolen | phishing, reused password | WebAuthn MFA at Cloudflare is still required |
| Friend A opens friend B's bay | friend | one Access app and rule per bay; bays cannot route to each other |
| Bay escapes to the host | friend or a hijacked agent with root in the bay | VM boundary, unprivileged hypervisor, seccomp, no shared host paths |
| Bay reaches the host's services, LAN or tailnet | same | nftables drop to host, RFC1918, CGNAT, link-local, ULA |
| Agent goal hijack via web content (prompt injection) | web pages, repos the agent reads | blast radius = that bay; friend's tokens fine-grained and expiring |
| Abuse from the host's public IP (spam, scans) | hijacked agent | SMTP blocked, per-bay connection rate limits, logs, optional VPN egress, kill switch |
| Supply-chain compromise | upstream package | pinned inputs with hashes, reviewed lock bumps, no curl-pipe-sh |
| Cloudflare account takeover | attacker | 2FA on the Cloudflare account; scoped API token |

### 6.2 OWASP Top 10:2025 mapping

- **A01 Broken Access Control**: default deny at Access; per-bay rule on an
  immutable id; cloudflared re-checks the JWT audience per hostname; bays have
  no route to anything internal (also covers SSRF, merged into A01 in 2025).
- **A02 Security Misconfiguration**: everything declarative; no manual
  dashboard state except what OpenTofu cannot do or must not hold (the GitLab
  IdP with its client secret, organisation MFA settings); listening ports
  checked by an acceptance test; guest images minimal.
- **A03 Software Supply Chain Failures**: nixpkgs and microvm.nix pinned by
  revision and hash; T3 pinned by version and hash, updated by reviewed
  commits; no runtime downloads in the host config.
- **A04 Cryptographic Failures**: TLS terminated at Cloudflare; HSTS
  (`max-age=31536000`, no includeSubDomains, no preload) on the bay hostnames
  only, set by a zone response header transform rule in `infra/cloudflare`,
  so a browser refuses click-through on a certificate error (for example
  behind a TLS-inspecting proxy); the tunnel is mTLS to Cloudflare; no secrets
  in the Nix store (world-readable): the tunnel credentials go straight from
  the local OpenTofu state into a root-only file
  (`infra/cloudflare/garage-cf install-credentials`) and reach cloudflared
  through systemd `LoadCredential`. The secret never enters git, so agenix or
  sops-nix would add nothing.
- **A05 Injection**: no code of ours takes user input; names in the site are
  validated against `^[a-z][a-z0-9-]{1,30}$`.
- **A06 Insecure Design**: this threat model; isolation by VM, not by
  convention; `systemctl stop garage-cloudflared` takes everything offline.
- **A07 Authentication Failures**: no passwords of ours; IdP login plus
  phishing-resistant MFA; short sessions; T3 pairing as second factor of
  device trust. Cloudflare Access is the only way into any bay (no tailnet or
  LAN port; `garage test` checks). No Access binding cookie: a risk to T3's
  websockets for a small gain over HSTS and short sessions.
- **A08 Software or Data Integrity Failures**: only signed/hashed inputs; bays
  cannot write to anything the host executes.
- **A09 Security Logging and Alerting Failures**: Access logs (who, when,
  denied), cloudflared and microvm journald logs, nftables drop counters with
  rate-limited logging. Not built: alerting on repeated denies.
- **A10 Mishandling of Exceptional Conditions**: fail closed: if cloudflared
  cannot validate a token it rejects; a bay that fails to start stays down
  instead of falling back to anything; disk-full in a bay stays in its image.

### 6.3 OWASP Agentic Top 10 (2026), what applies here

- **ASI01 Agent Goal Hijack / ASI02 Tool Misuse**: friends' agents run with full
  permissions by design; containment is the bay, not the agent. The bay's
  `CLAUDE.md` tells agents that web content is data, never instructions.
- **ASI03 Identity and Privilege Abuse**: per-bay secrets only; friends are
  told to use fine-grained, expiring, repo-scoped git tokens.
- **ASI04 Agentic Supply Chain**: MCP servers and skills inside a bay are the
  friend's choice; the base image ships none.

### 6.4 Host and bay hardening

- Host: bays run as an unprivileged `microvm` user; cloud-hypervisor with its
  seccomp filter on; no nested virtualisation for guests; no host path shared
  into a bay.
- cloudflared: systemd sandboxing (`DynamicUser`, `ProtectSystem=strict`,
  `NoNewPrivileges`, `CapabilityBoundingSet=`, `RestrictAddressFamilies`,
  `SystemCallFilter=@system-service`), checked with `systemd-analyze security`.
- Network (nftables, IPv4 only; all IPv6 is dropped): bay -> public internet
  allowed; bay -> host, 10/8, 172.16/12, 192.168/16, 100.64/10, 169.254/16
  and other special ranges, and other bays dropped; outbound TCP 25 dropped; new-connection
  rate limit per bay. Bays get public DNS resolvers, so they need nothing from
  the host.
- Updates: bays use this repo's `flake.lock`, so they are updated by a reviewed
  lock bump and a rebuild, announced to friends (not automatic).
- Data: the host disk is not encrypted and the admin has root, so the admin
  can read bay data. Friends are told this before they get access. No backups
  of bays: friends push their work to their own remotes.
- Repo: gitleaks, `nix flake check`, statix, deadnix and nixfmt run by hand
  before every push.

### 6.5 Rules for all new code in this repo

- Prefer configuration of maintained components over code; every line of our
  own code needs a reason in the PR.
- Nix: flake with locked inputs, no `builtins.fetchGit` without a rev, no
  `--impure` (except where `garage-cf` evaluates the site, which lives outside
  the repo), no secrets in any derivation.
- Shell: `set -euo pipefail`, shellcheck clean, quoted variables, no `eval`,
  inputs validated against an allowlist pattern.
- Every change runs the acceptance tests of section 11 for what it touches.

## 7. Isolation and limits

### 7.1 Hard isolation from the host

The host admin's files, machine and accounts must not exist from inside a bay.
This is enforced by the platform, not by asking agents nicely; the agent rules
in `guest/bay-rules.md` are an extra layer, not the control.

- Nothing of the host is mounted, copied or baked into a bay: no home
  directories, no `~/.claude`, no keyring, no ssh keys, no host `/nix/store`,
  no host `/etc`. The guest image is built only from this repo's guest module.
- No network path to the host side: host addresses, LAN, tailnet and other
  bays are dropped (section 6.4). The host's own services are unreachable.
- Nothing points at the host: the guest has a neutral hostname (`bay`),
  public DNS resolvers, no host entries for the host, no tailnet, and no
  mention of the host's machines, paths or projects in any file it ships,
  including `guest/bay-rules.md`.
- One-way only: the admin may manage bays from the host (build, start, stop,
  read logs) but never mounts a bay volume read-write while the bay runs.
- Tested (section 11): from inside a bay, none of the above is reachable or
  visible.

### 7.2 Limits

- CPU/RAM per bay: fixed `vcpu` and `mem` in the site (section 9).
- Disk: one sparse volume image per bay for `/home` and the writable Nix
  store. A fixed-size image caps the bay by construction; no ext4 quotas
  needed.

### 7.3 VPN egress

Without it a bay leaves from the host's public IP. With
`egress.wireguardConfig` in the site (a root-only wg-quick file),
`modules/egress.nix` runs the WireGuard tunnel on the host (never in the bay,
whose user has sudo) and routes the bay by its source address into it: own
routing table, `ip rule` at 4000 + octet, ahead of Tailscale's rules; the
host, Tailscale and other bays are untouched. DNS goes to the bay's public
resolvers through the tunnel. Kill switch: without the tunnel the table
answers "unreachable", and nftables drops every packet of the bay that would
leave through anything but its own tunnel (forward and postrouting), so it is
never routed out of the host's IP. All isolation rules above apply unchanged
on the tunnel path. Free VPN tiers often allow one connection per account, so
no other client may use the same config.

## 8. What is inside a bay (NixOS guest module)

- Claude Code (unmodified), T3 Code (`t3 serve` bound to the bay address),
  node, git, gh, glab, tmux, Nix with flakes.
- `guest/bay-rules.md` installed as the bay's user-level `~/.claude/CLAUDE.md`
  (named so it does not load for agents working on this repo): the rules every
  agent in a bay loads (scope = this machine only).
- No SSH server and no login console; T3's terminal is the shell.

## 9. Hardware budget

Measured on the reference host (i7-9750H, 6 cores / 12 threads, 31 GiB RAM,
1 TB SSD):

| Resource | Per bay | 3 bays |
| --- | --- | --- |
| CPU | 4 vCPU (shared, overcommitted) | 12 vCPU |
| RAM | 6 GiB guest, unit capped at 7 GiB | 21 GiB |
| Disk | 100 GiB sparse volume + about 1.5 GB store image | about 305 GB max |

- vCPUs are a cap, not a reservation; a long local build on the host makes
  bays slow while it runs.
- Keep RAM for the host's own use. On the reference host 3 bays is the
  ceiling; more friends means rotating bays (stopped bays cost disk only) or
  more hardware.

Host facts that shaped the module:

- The host's `/etc/nixos` may not be a flake. This repo is a flake that
  exports `lib.hostModule site`; a non-flake host imports it with
  `builtins.getFlake` pinned to a commit. Bays are evaluated from this repo's
  own lock, independent of the host's channel.
- The NixOS firewall drops input from unknown interfaces, so the bridge
  cannot reach host services by default; forwarding to the LAN and tailnet
  needs the explicit drops above.

## 10. Decisions

- **No tailnet port.** An early version also exposed a bay on the host's
  tailnet address. It was removed: Cloudflare Access is the only way in, and
  `garage test` checks that no socket proxy or NAT rule leads into a bay.
- **HSTS on the bay hostnames only**, not the whole zone, so other sites on
  the zone are not affected.
- **No Access binding cookie** (see A07).
- **VPN egress per bay, on the host.** A bay's user has root, so a tunnel
  inside the bay could be turned off by its agents; on the host it cannot.
- **Site file outside the repo.** Bays, GitLab ids and Cloudflare ids differ
  per installation and live next to the host configuration
  (`examples/site/site.nix` shows the format), so the repo holds no
  installation data.

## 11. Acceptance tests

`sudo garage test <bay>` runs these on the live host:

- From inside a bay: connections to the host's LAN and tailnet addresses on
  common ports (22, 53, 80, 443, 3773, 8384, 9222), the LAN gateway on 53, 80
  and 443, any port of another bay (sampled across the range) and TCP 25 anywhere all fail;
  HTTPS and DNS to the internet work; no IPv6.
- From the host: no socket proxy and no dnat rule into the bay network; the
  admin's own way in (sshd, Tailscale) stays active when it is enabled.
- `ls /nix/store` inside a bay shows only the bay's closure and its own builds.
- Inside a bay, a search of the whole filesystem for the host's name, the
  admin's user name, `.ts.net`, the tailnet name and the host's addresses
  finds nothing outside the friend's own files.
- Without an Access login the bay URL shows Cloudflare's login; forged
  cookies, headers and websockets and plain HTTP are redirected, never
  answered by T3; an unknown hostname gets 404. Each bay's Access policy holds
  only its owner's GitLab id, and the same id may not appear in two bays.
- For a VPN bay: the public address differs from the host's, DNS is counted
  on the tunnel only, and with the tunnel stopped (and the policy rule
  removed) nothing leaves through the uplink.
- `systemd-analyze security` rates cloudflared "OK" or better.

Checked by configuration only, not live: a friend's login on another friend's
URL (the per-app policy, checked against the site; `garage-cf plan` without changes confirms the live policies match), cloudflared's own JWT check
(the edge stops a forged token first), and the bridge anti-spoof rules (no
spoofed frames are sent).
