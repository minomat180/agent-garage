# Contributing

I run agent-garage for a few friends on my own hardware. It is published so
others can run or adapt it, not maintained as a general project.
Issues are welcome, especially about the isolation; pull requests may sit for a
while, and I will turn down changes that add a service of our own in front of
the bays (a login page, a reverse proxy, a control panel).

If you change behaviour, run `nix flake check` and, on a host that runs it,
`sudo garage test <bay>` for each bay (one at a time: two runs interfere), and
say in the PR what you ran.

If you adapt it, the parts you will replace:

- **The site.** Copy `examples/site/site.nix` out of the repo (not
  `outputs.json`: `garage-cf export` writes the real one next to it), fill in
  your bays, GitLab user ids and Cloudflare ids, and pass it to `lib.hostModule`
  ([README](README.md#quick-start)).
- **Login.** Access trusts GitLab through a generic OIDC identity provider that
  is created by hand in the Zero Trust dashboard. Only GitLab has been tried;
  the Access policy matches the OIDC `sub` claim.
- **Uplink and addresses.** `garage.uplinkInterface` is the host's wired
  interface; the bay network 10.180.0.0/24 is fixed in `lib/garage.nix`.
- **Credentials.** The Cloudflare API token, the tunnel credentials and any
  WireGuard config are files on the host outside the repo and the Nix store;
  the paths are in the README.
