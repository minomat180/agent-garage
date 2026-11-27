# Example site: everything that differs between installations. Copy this file
# (not the example outputs.json: `garage-cf export` writes the real one next to
# it) out of the repo, for example to /etc/nixos/agent-garage/site.nix where it
# is versioned with the host configuration, replace every value, and pass it
# to the host module:
#
#   (builtins.getFlake "git+file:///path/to/agent-garage?rev=<commit>").lib.hostModule
#     (import ./agent-garage/site.nix)
#
# `nix flake check` builds this example; it is not a working deployment.
{
  # Cloudflare constants (not secret). The GitLab identity provider is set up
  # in the Zero Trust dashboard (generic OIDC, claims sub) and referenced here
  # by its id; Access is free for up to 50 users.
  cloudflare = {
    accountId = "0123456789abcdef0123456789abcdef";
    zone = "example.com";
    teamName = "your-team"; # login pages at https://<teamName>.cloudflareaccess.com
    identityProviderId = "00000000-0000-4000-8000-000000000000";
    sessionDuration = "12h"; # Access session and MFA re-authentication interval
  };

  # Tunnel id and Access AUD tags (not secret), written next to this file by
  # `infra/cloudflare/garage-cf export` after the first apply. Until then the
  # host refuses to build a public bay.
  cloudflareOutputs =
    if builtins.pathExists ./outputs.json then
      builtins.fromJSON (builtins.readFile ./outputs.json)
    else
      null;

  # One attrset per bay. Adding a bay is one entry here, `garage-cf apply` and
  # `export` for a public bay, then a host rebuild.
  #
  #   name (the key)  ^[a-z][a-z0-9-]{1,30}$; the VM is "bay-<name>" on the host
  #   ipv4            address on the garage bridge, 10.180.0.2 .. 10.180.0.254
  #                   (10.180.0.1 is the host side); the last octet also names
  #                   the tap device (gbay<octet>) and the vsock CID (1000 + octet)
  #   mac             locally administered unicast, 02:xx:xx:xx:xx:xx
  #   vcpu, mem       fixed CPU and RAM cap (mem in MiB)
  #   volumeGiB       sparse volume for /home and the writable Nix store
  #   public          null, or the bay's public URL behind Cloudflare Access:
  #                     hostname    one DNS label; the URL is https://<hostname>.<zone>
  #                     gitlabSubs  numeric GitLab user ids (OIDC "sub") allowed in;
  #                                 never usernames or emails (docs/design.md section 5)
  #                   Apply with infra/cloudflare/garage-cf, then deploy the host.
  #   egress          optional: { wireguardConfig = "/var/lib/agent-garage/egress/<name>.conf"; }
  #                   All of the bay's internet traffic (DNS included) leaves through
  #                   this WireGuard tunnel (wg-quick format, root:root 600, a string,
  #                   never a Nix path), run on the host; if the tunnel is down the
  #                   bay has no internet at all. Without it the bay leaves from the
  #                   uplink (the host's public address).
  #   sleepAfter      optional: idle minutes (15 .. 10080) after which the bay is
  #                   shut down, so it holds no RAM while nobody uses it. In use
  #                   means an open T3 connection or agents working (VM CPU above
  #                   idle). The first request to its URL starts it again (about
  #                   15 s); files on the volume stay, running processes do not.
  #                   Without it the bay runs all the time.
  #
  # There is no other way into a bay: no port on the host's LAN or VPN
  # addresses leads into one.
  bays = {
    alice = {
      ipv4 = "10.180.0.11";
      mac = "02:00:0a:b4:00:0b";
      vcpu = 4;
      mem = 6144;
      volumeGiB = 100;
      public = {
        hostname = "alice-garage";
        gitlabSubs = [ "0" ]; # placeholder: GitLab has no user 0
      };
    };

    # Leaves the internet through a VPN instead of the host's address.
    bob = {
      ipv4 = "10.180.0.12";
      mac = "02:00:0a:b4:00:0c";
      vcpu = 4;
      mem = 6144;
      volumeGiB = 100;
      public = {
        hostname = "bob-garage";
        gitlabSubs = [ "0" ]; # placeholder
      };
      egress.wireguardConfig = "/var/lib/agent-garage/egress/bob.conf";
      # Stopped after an idle hour, started again by the next request.
      sleepAfter = 60;
    };
  };
}
