# Shared constants and the validation of a site (bays and Cloudflare
# constants, see examples/site/site.nix). Used by the flake (guest
# configurations, OpenTofu inputs) and by the host module (assertions).
{ lib, cloudflare }:
let
  ipPrefix = "10.180.0";
in
rec {
  network = {
    bridge = "garagebr";
    cidr = "${ipPrefix}.0/24";
    prefixLength = 24;
    gateway = "${ipPrefix}.1";
    nameservers = [
      "1.1.1.1"
      "9.9.9.9"
    ];
  };

  # T3 inside every bay listens on the bay address on this port.
  t3Port = 3773;

  # Public access: the site's Cloudflare constants (account, zone, Access team,
  # GitLab identity provider id, session length). Not secret. The identity
  # provider is configured in the dashboard (its client secret stays out of
  # the OpenTofu state) and only referenced here by id.
  inherit cloudflare;

  cloudflareOk =
    builtins.isAttrs cloudflare
    &&
      lib.attrNames cloudflare == [
        "accountId"
        "identityProviderId"
        "sessionDuration"
        "teamName"
        "zone"
      ]
    && builtins.match "[0-9a-f]{32}" cloudflare.accountId != null
    && builtins.match "([a-z0-9-]+\\.)+[a-z]{2,}" cloudflare.zone != null
    && builtins.match "[a-z0-9][a-z0-9-]{0,62}" cloudflare.teamName != null
    &&
      builtins.match "[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}" cloudflare.identityProviderId
      != null
    && builtins.match "[0-9]{1,3}h" cloudflare.sessionDuration != null;

  publicBays = lib.filterAttrs (_: b: (b.public or null) != null);
  publicHostname = bay: "${bay.public.hostname}.${cloudflare.zone}";

  # Input of infra/cloudflare (TF_VAR_garage), built from the same bays.
  tofuVars = bays: {
    account_id = cloudflare.accountId;
    inherit (cloudflare) zone;
    team_name = cloudflare.teamName;
    identity_provider_id = cloudflare.identityProviderId;
    session_duration = cloudflare.sessionDuration;
    bays = lib.mapAttrs (_: b: {
      hostname = publicHostname b;
      gitlab_subs = b.public.gitlabSubs;
    }) (publicBays bays);
  };

  # VPN egress (bays with `egress`): a WireGuard tunnel on the host per bay,
  # chosen by policy routing on the bay's source address. Interface gwg<octet>,
  # routing table 1000 + octet, ip rule priority 4000 + octet (ahead of
  # Tailscale's rules at 5210 .. 5270; the host's own traffic is untouched).
  egress = {
    mtu = 1420;
    # TCP MSS clamped on the tunnel: MTU minus 20 (IPv4) and 20 (TCP) bytes.
    mss = 1380;
  };
  egressBays = lib.filterAttrs (_: b: (b.egress or null) != null);
  tunnelName = bay: "gwg${toString (lastOctet bay)}";
  egressTable = bay: 1000 + lastOctet bay;
  egressRulePriority = bay: 4000 + lastOctet bay;

  # Sleep mode (bays with `sleepAfter`, modules/sleep.nix): the VM is stopped
  # after that many idle minutes and started again by the first request to
  # its wake address, a loopback address of the host (127.180.0.<octet>).
  sleep = {
    # Port of the wake addresses. Not the T3 port: a T3 server running on the
    # host itself listens on every address, loopback ones included.
    wakePort = 13773;
    # The relay to T3 exits after this long without an open connection.
    relayIdle = "10min";
    # How often the idle check runs.
    checkMinutes = 5;
    # VM CPU (percent of one core, averaged between two checks) from which a
    # bay counts as busy; an idle bay sits at about 1.
    busyCpuPercent = 5;
  };
  sleepBays = lib.filterAttrs (_: b: (b.sleepAfter or null) != null);
  sleeps = bay: (bay.sleepAfter or null) != null;
  wakeAddress = bay: "127.180.0.${toString (lastOctet bay)}";
  wakeUnitName = name: "garage-wake-${name}";
  sleepUnitName = name: "garage-sleep-${name}";
  # Where cloudflared sends a bay's requests: the bay, or its wake address.
  originAddress = bay: if sleeps bay then wakeAddress bay else bay.ipv4;
  origin =
    bay: "http://${originAddress bay}:${toString (if sleeps bay then sleep.wakePort else t3Port)}";

  # vsock ports served inside a bay, reachable only from the host (CID 2).
  vsockPorts = {
    pair = 7001;
    selftest = 7002;
  };

  lastOctet = bay: lib.toInt (lib.last (lib.splitString "." bay.ipv4));
  tapName = bay: "gbay${toString (lastOctet bay)}";
  vsockCid = bay: 1000 + lastOctet bay;
  vmName = name: "bay-${name}";

  nameOk = name: builtins.match "[a-z][a-z0-9-]{1,30}" name != null;

  ipOk =
    bay:
    let
      m = builtins.match "10\\.180\\.0\\.([0-9]{1,3})" bay.ipv4;
      o = lib.toInt (builtins.head m);
    in
    m != null && o >= 2 && o <= 254;

  macOk = bay: builtins.match "02(:[0-9a-f]{2}){5}" bay.mac != null;

  # public = null, or { hostname = "<label>"; gitlabSubs = [ "<numeric id>" ... ]; }
  publicOk =
    bay:
    let
      p = bay.public or null;
    in
    p == null
    || (
      builtins.isAttrs p
      &&
        lib.attrNames p == [
          "gitlabSubs"
          "hostname"
        ]
      && builtins.isString p.hostname
      && builtins.match "[a-z][a-z0-9-]{1,30}" p.hostname != null
      && builtins.isList p.gitlabSubs
      && p.gitlabSubs != [ ]
      && lib.all (s: builtins.isString s && builtins.match "[0-9]{1,12}" s != null) p.gitlabSubs
    );

  # egress = null, or { wireguardConfig = "<absolute path, root-only, outside the store>"; }
  # The path is a string on purpose: a Nix path literal would copy the key
  # into the world-readable store.
  egressOk =
    bay:
    let
      e = bay.egress or null;
    in
    e == null
    || (
      builtins.isAttrs e
      && lib.attrNames e == [ "wireguardConfig" ]
      && builtins.isString e.wireguardConfig
      && builtins.match "/[A-Za-z0-9._/-]+" e.wireguardConfig != null
      && !lib.hasPrefix "/nix/" e.wireguardConfig
      && !lib.hasInfix "/../" e.wireguardConfig
    );

  intIn =
    lo: hi: v:
    builtins.isInt v && v >= lo && v <= hi;

  unique = xs: lib.length xs == lib.length (lib.unique xs);

  # List of { assertion, message } in the NixOS assertions format.
  checks =
    bays:
    let
      names = lib.attrNames bays;
      vals = lib.attrValues bays;
      hostnames = map (b: b.public.hostname) (lib.filter (b: (b.public or null) != null) vals);
      perBay = lib.concatMap (
        name:
        let
          b = bays.${name};
        in
        [
          {
            assertion = nameOk name;
            message = "agent-garage: bay name '${name}' does not match ^[a-z][a-z0-9-]{1,30}$";
          }
          {
            assertion = b ? ipv4 && ipOk b;
            message = "agent-garage: bay '${name}': ipv4 must be 10.180.0.2 .. 10.180.0.254";
          }
          {
            assertion = b ? mac && macOk b;
            message = "agent-garage: bay '${name}': mac must be lowercase 02:xx:xx:xx:xx:xx";
          }
          {
            assertion = intIn 1 8 (b.vcpu or null);
            message = "agent-garage: bay '${name}': vcpu must be 1 .. 8";
          }
          {
            assertion = intIn 1024 16384 (b.mem or null);
            message = "agent-garage: bay '${name}': mem must be 1024 .. 16384 MiB";
          }
          {
            assertion = intIn 10 200 (b.volumeGiB or null);
            message = "agent-garage: bay '${name}': volumeGiB must be 10 .. 200";
          }
          {
            assertion = publicOk b;
            message = "agent-garage: bay '${name}': public must be null or { hostname = \"<label>\"; gitlabSubs = [ \"<numeric GitLab user id>\" ]; }";
          }
          {
            assertion = egressOk b;
            message = "agent-garage: bay '${name}': egress must be null or { wireguardConfig = \"/absolute/path/outside/the/store.conf\"; } (a string, not a Nix path)";
          }
          {
            assertion = (b.sleepAfter or null) == null || intIn 15 10080 b.sleepAfter;
            message = "agent-garage: bay '${name}': sleepAfter must be null or 15 .. 10080 (idle minutes before the bay is stopped)";
          }
          {
            assertion = lib.all (lib.flip lib.elem [
              "ipv4"
              "mac"
              "vcpu"
              "mem"
              "volumeGiB"
              "public"
              "egress"
              "sleepAfter"
            ]) (lib.attrNames b);
            message = "agent-garage: bay '${name}' has unknown attributes";
          }
        ]
      ) names;
    in
    perBay
    ++ [
      {
        assertion = cloudflareOk;
        message = "agent-garage: site cloudflare must be { accountId (32 hex); zone; teamName; identityProviderId (uuid); sessionDuration = \"<n>h\"; }";
      }
      {
        assertion = unique (map (b: b.ipv4) vals);
        message = "agent-garage: bay ipv4 addresses must be unique";
      }
      {
        assertion = unique (map (b: b.mac) vals);
        message = "agent-garage: bay MAC addresses must be unique";
      }
      {
        assertion = unique hostnames;
        message = "agent-garage: public hostnames must be unique";
      }
    ];

  # Returns bays unchanged, or throws with every failed check.
  validate =
    bays:
    let
      failed = lib.filter (c: !c.assertion) (checks bays);
    in
    if failed == [ ] then bays else throw (lib.concatMapStringsSep "\n" (c: c.message) failed);
}
