# Security model

How agent-garage keeps bays apart from the host, from the network around it and
from each other, and where that stops. The full design and its reasoning are in
[design.md](design.md) (sections 6 and 7); this page is the current state.

## Threat model

| Threat | Main control | Checked by |
| --- | --- | --- |
| A stranger reaches a bay | Cloudflare Access in front of every hostname: default deny, one Allow rule per bay on the numeric GitLab user id, WebAuthn-only MFA; cloudflared rejects requests without a valid Access JWT for that bay's AUD; unknown hostnames get 404 | `garage test`: forged cookie, forged header, forged websocket, plain HTTP and no-login probes against the public URL; ingress rules read back from cloudflared |
| A friend's GitLab account is stolen | the passkey or security key at Cloudflare is still required | Access app settings in OpenTofu (`allowed_authenticators = ["biometrics", "security_key"]`) |
| Friend A opens friend B's bay | one Access app and policy per bay; the same GitLab id may not appear in two bays | `garage test` (`access-subs`); `garage-cf plan` without drift |
| A bay reaches the host, the LAN, the tailnet or another bay | nftables on the host (own tables, loaded before any bay starts): drop to the host, RFC 1918, CGNAT, link-local and other special ranges, other bays, TCP 25, IPv6; isolated bridge ports with MAC and address pinning | `garage test`: from inside the bay, TCP and ping to every host address, the LAN gateway, MagicDNS, the metadata address, 14 ports and ping on every other bay, a stand-in bay on the bridge |
| A bay sees the host's files | no shared paths at all; the bay boots from an erofs image of its own closure, its writable store is on its own volume | `garage test`: no virtiofs/9p mounts, the read-only store holds only the bay's closure, whole-filesystem search for the host's name, user, tailnet name and addresses |
| A bay escapes the VM | cloud-hypervisor with its seccomp filter, running as the unprivileged `microvm` user under systemd sandboxing (no capabilities, read-only system, no home directories, only `/dev/kvm`, `/dev/net/tun`, `/dev/vhost-net`); no KSM between VMs | `systemd-analyze security` on every garage unit (cloudflared must rate OK or better) |
| Abuse from the home IP | outgoing TCP 25 dropped, new connections rate-limited per bay, optional VPN egress per bay | `garage test` (`smtp-rule`, `public-ip`) |
| A VPN bay leaks onto the uplink | WireGuard runs on the host, not in the bay; the bay's routing table falls back to `unreachable`; nftables drops any packet of that bay that is not on its own tunnel, in forward and again in postrouting | `garage test`: stops the tunnel, then also deletes the policy rule, and checks that nothing reached the uplink |
| A secret ends up in the Nix store or git | tunnel credentials and WireGuard configs are root-only files read through systemd `LoadCredential`; the site has no secrets; the Cloudflare API token is passed only to `tofu` | `nix flake check` (no `/nix/store` credential paths), `garage test` (file modes), gitleaks |

## OWASP mappings

The design uses [OWASP Top 10:2025](https://owasp.org/Top10/2025/) and the
[OWASP Top 10 for Agentic Applications 2026](https://genai.owasp.org/) as its
checklist. This table lists the items the design maps and what is actually
implemented for each; "planned" means not built yet.

| Item | Implemented | Not done |
| --- | --- | --- |
| A01 Broken Access Control | default deny at Access, per-bay rule on an immutable id, JWT audience checked again per hostname, no route from a bay to anything internal (SSRF) | |
| A02 Security Misconfiguration | host, bays, tunnel, Access apps, DNS and the HSTS rule are declared in this repo; listening ports inside a bay checked by a test | the GitLab identity provider and the Access organisation's MFA settings are set by hand in the dashboard |
| A03 Software Supply Chain Failures | nixpkgs and microvm.nix locked in `flake.lock`; T3 pinned by version and sha256; OpenTofu providers pinned with hashes | planned: CI and Dependabot; T3 fetches npm packages at run time inside the bay |
| A04 Cryptographic Failures | TLS at Cloudflare, HSTS (`max-age=31536000`) on the bay hostnames, tunnel credentials outside the store | |
| A05 Injection | no code of ours takes user input; names in the site are validated (`^[a-z][a-z0-9-]{1,30}$`) before they reach a unit name or a shell script | |
| A06 Insecure Design | isolation by VM and by the network, not by agent instructions; `systemctl stop garage-cloudflared` takes every bay offline | |
| A07 Authentication Failures | no passwords of ours; GitLab login plus WebAuthn; 12 h sessions; T3 device pairing inside the bay; Access is the only way in | no Access binding cookie (decided against: risk to T3's websockets) |
| A08 Software or Data Integrity Failures | only locked and hashed inputs; nothing a bay writes is executed by the host | |
| A09 Security Logging and Alerting Failures | Access logs at Cloudflare, journald for cloudflared and the VMs, rate-limited nftables drop logs | planned: alerting on repeated denies |
| A10 Mishandling of Exceptional Conditions | fail closed: no bridge or no nftables rules, no bay; no tunnel, no internet for a VPN bay; an invalid site does not evaluate | |
| ASI01/ASI02 Goal hijack, tool misuse | the bay is the containment, agents inside run with full permissions; the bay's `CLAUDE.md` ([guest/bay-rules.md](../guest/bay-rules.md)) tells agents that web content is data | |
| ASI03 Identity and privilege abuse | each bay holds only its own user's credentials; nothing of the host's accounts is mounted | |
| ASI04 Agentic supply chain | the image ships no MCP servers or skills; what a friend installs is their choice | |

The design also names OWASP ASVS 5.0.0 level 2 as the bar for code of our own.
There has been no requirement-by-requirement ASVS review; this repo contains
no application code beyond the shell helpers.

## Known gaps

- **The host admin can see everything in a bay.** Root on the host, no disk
  encryption. Friends are told so.
- **T3's logs keep the Host header of every request** in the bay: its public
  hostname, or any other address the bay was ever opened through.
- **Hairpin traffic is not filtered.** A bay without VPN egress can connect
  to the home's own public IP; the router's port forwards decide what that
  reaches.
- **Anti-spoofing is checked by configuration.** `garage test` verifies the
  bridge rules exist; it does not try to send spoofed frames.
- **cloudflared's own JWT check is verified by configuration.** A forged token
  cannot be sent from outside because the Cloudflare edge stops it first.
- **Cross-login is checked by configuration.** One friend's login on another
  friend's URL is denied by that app's policy (checked against the site by `garage test`; `garage-cf plan` without changes confirms the live policies match), not by
  a live login.
- **The first passkey is trust on first use.** Until a friend registers a
  passkey, the GitLab login alone is enough to register one. The bay guide
  tells friends to enroll right after their first login.
- **Updates are manual.** Bays use this repo's `flake.lock`; the host's own
  upgrades do not update them.
