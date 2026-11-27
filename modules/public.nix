# Public access: cloudflared connects the bays that have a `public`
# entry in the site to Cloudflare. Access (login at GitLab + passkey MFA) runs
# at the edge; cloudflared checks the Access JWT again for every request
# (originRequest.access: team + the bay app's AUD tag), so a request that
# skips Access never reaches a bay. Hostnames that are not a bay get 404.
#
# The tunnel id and AUD tags are not secret and come from the site's
# `cloudflareOutputs` (outputs.json next to site.nix, written by
# `infra/cloudflare/garage-cf export`). The tunnel credentials are a root-only
# file outside the store (`garage-cf install-credentials`), handed to the unit
# with LoadCredential.
{
  garage,
  bays,
  outputs,
}:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.garage.public;
  inherit (garage) cloudflare;

  # Fail closed: if a wake address could not be bound, something else on the
  # host might answer there, so the tunnel does not run at all.
  wakeSockets = lib.mapAttrsToList (name: _: "${garage.wakeUnitName name}.socket") (
    garage.sleepBays publicBays
  );

  publicBays = garage.publicBays bays;

  tunnelId = if outputs == null then null else outputs.tunnel_id or null;
  audOf = name: if outputs == null then null else outputs.bays.${name}.aud or null;

  unit = "garage-cloudflared";

  tunnelConfig = {
    tunnel = tunnelId;
    credentials-file = "/run/credentials/${unit}.service/credentials.json";
    ingress =
      lib.mapAttrsToList (name: b: {
        hostname = garage.publicHostname b;
        # A bay with sleep mode is reached through its wake address on the
        # host (modules/sleep.nix), which starts it when needed.
        service = garage.origin b;
        originRequest = {
          connectTimeout = "10s";
          # Reject anything without a valid Access JWT for this bay's app.
          access = {
            required = true;
            inherit (cloudflare) teamName;
            audTag = [ (audOf name) ];
          };
        };
      }) publicBays
      ++ [ { service = "http_status:404"; } ];
  };

  configFile = pkgs.writeText "garage-cloudflared.json" (builtins.toJSON tunnelConfig);

  # Addresses cloudflared may reach besides the public internet: the public
  # bays (for a bay with sleep mode only its wake address, one loopback
  # address) and the host's DNS resolvers. Everything private is denied.
  allowAddrs =
    map (b: "${garage.originAddress b}/32") (lib.attrValues publicBays)
    ++ config.networking.nameservers
    ++ lib.optionals config.services.tailscale.enable [
      # MagicDNS resolver (resolv.conf points here when tailscale manages DNS).
      "100.100.100.100/32"
      "fd7a:115c:a1e0::53/128"
    ];
in
{
  options.garage.public = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = publicBays != { };
      defaultText = lib.literalExpression "true if a bay in the site has `public` set";
      description = ''
        Run cloudflared for the public bays. Setting this to false (or
        `systemctl stop garage-cloudflared`) takes every bay off the internet.
      '';
    };
    credentialsFile = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/agent-garage/cloudflared/credentials.json";
      description = "Root-only tunnel credentials JSON (written by infra/cloudflare/garage-cf install-credentials). Never a store path.";
    };
    package = lib.mkPackageOption pkgs "cloudflared" { };
    configFile = lib.mkOption {
      type = lib.types.path;
      readOnly = true;
      internal = true;
      default = configFile;
      description = "Generated cloudflared configuration (no secrets); used by `garage test`.";
    };
  };

  config = lib.mkIf (config.garage.enable && cfg.enable) {
    assertions = [
      {
        assertion = builtins.isString tunnelId && builtins.match "[0-9a-f-]{36}" tunnelId != null;
        message = "agent-garage: no tunnel id in the site's cloudflareOutputs (run infra/cloudflare/garage-cf apply and export)";
      }
      {
        assertion = lib.all (n: audOf n != null && builtins.match "[0-9a-f]{64}" (audOf n) != null) (
          lib.attrNames publicBays
        );
        message = "agent-garage: a public bay has no Access AUD tag in the site's cloudflareOutputs (run garage-cf apply and export)";
      }
      {
        assertion = !lib.hasPrefix "/nix/store" cfg.credentialsFile;
        message = "garage.public.credentialsFile must not be in the Nix store";
      }
    ];

    systemd.services.${unit} = {
      description = "agent-garage: Cloudflare Tunnel to the public bays";
      wantedBy = [ "multi-user.target" ];
      wants = [ "network-online.target" ];
      requires = wakeSockets;
      after = [
        "network-online.target"
        "garage-nftables.service"
      ]
      ++ wakeSockets;
      unitConfig.ConditionPathExists = cfg.credentialsFile;
      serviceConfig = {
        ExecStart = lib.concatStringsSep " " [
          "${lib.getExe cfg.package} tunnel"
          "--no-autoupdate"
          "--management-diagnostics=false"
          "--edge-ip-version auto"
          "--config ${configFile}"
          "run"
        ];
        LoadCredential = [ "credentials.json:${cfg.credentialsFile}" ];
        Restart = "on-failure";
        RestartSec = 5;

        DynamicUser = true;
        PrivateUsers = true;
        PrivateTmp = true;
        PrivateDevices = true;
        PrivateIPC = true;
        DevicePolicy = "closed";
        ProtectSystem = "strict";
        ProtectHome = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectKernelLogs = true;
        ProtectControlGroups = true;
        ProtectClock = true;
        ProtectHostname = true;
        ProtectProc = "invisible";
        ProcSubset = "pid";
        NoNewPrivileges = true;
        CapabilityBoundingSet = [ "" ];
        AmbientCapabilities = [ "" ];
        RestrictNamespaces = true;
        RestrictRealtime = true;
        RestrictSUIDSGID = true;
        RemoveIPC = true;
        KeyringMode = "private";
        LockPersonality = true;
        MemoryDenyWriteExecute = true;
        RestrictAddressFamilies = [
          "AF_INET"
          "AF_INET6"
          "AF_UNIX"
          "AF_NETLINK"
        ];
        SystemCallArchitectures = "native";
        SystemCallFilter = [
          "@system-service"
          "~@privileged @resources"
        ];
        SystemCallErrorNumber = "EPERM";
        # Public internet (Cloudflare edge, Access certificates), DNS and the
        # public bays only: no LAN, tailnet, loopback or other bays.
        IPAddressAllow = allowAddrs;
        IPAddressDeny = [
          "localhost"
          "link-local"
          "multicast"
          "0.0.0.0/8"
          "10.0.0.0/8"
          "100.64.0.0/10"
          "172.16.0.0/12"
          "192.168.0.0/16"
          "fc00::/7"
        ];
        UMask = "0077";
        MemoryMax = "512M";
        TasksMax = 256;
      };
    };
  };
}
