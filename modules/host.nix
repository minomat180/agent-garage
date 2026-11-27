# Host side of agent-garage: microvm.nix host, the garage bridge, isolation
# rules (own nftables tables, loaded by their own unit; the host firewall is
# not touched), sandboxing of the hypervisor, and (modules/public.nix) the
# Cloudflare Tunnel for public bays, the only way into a bay.
#
# Built per site by the flake (`lib.hostModule site`): `bays` and `garage`
# come from the site, `bayConfigs` are the evaluated guests, `outputs` the
# tunnel id and AUD tags written by `garage-cf export` (or null).
{
  self,
  garage,
  bays,
  bayConfigs,
  outputs,
  microvmHost,
}:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.garage;
  inherit (garage) network t3Port;
  inherit (config.microvm) stateDir;

  nft = "${pkgs.nftables}/bin/nft";
  ipBin = "${pkgs.iproute2}/bin/ip";
  bridgeBin = "${pkgs.iproute2}/bin/bridge";

  # Everything a bay may send leaves through the uplink to public addresses.
  blockedV4 = [
    "0.0.0.0/8"
    "10.0.0.0/8"
    "100.64.0.0/10"
    "127.0.0.0/8"
    "169.254.0.0/16"
    "172.16.0.0/12"
    "192.0.0.0/24"
    "192.0.2.0/24"
    "192.168.0.0/16"
    "198.18.0.0/15"
    "198.51.100.0/24"
    "203.0.113.0/24"
    "224.0.0.0/3"
  ];

  # VPN egress bays (the site's `egress`, modules/egress.nix): each may leave
  # only through its own tunnel, and each tunnel carries only its bay.
  egressBays = garage.egressBays bays;
  egressList = lib.mapAttrsToList (name: b: {
    inherit name;
    inherit (b) ipv4;
    tun = garage.tunnelName b;
  }) egressBays;
  forEgress = f: lib.concatMapStrings f egressList;
  uplinks = lib.concatStringsSep ", " (
    [ ''"${cfg.uplinkInterface}"'' ] ++ map (e: ''"${e.tun}"'') egressList
  );
  mss = toString garage.egress.mss;

  rules = pkgs.writeText "agent-garage.nft" ''
    # agent-garage isolation rules. Replaced atomically on every load.
    table inet garage
    delete table inet garage
    table inet garage {
      set bay_newconn {
        type ipv4_addr
        size 1024
        flags dynamic,timeout
        timeout 1m
      }

      # Bays never talk to the host itself, except replies to connections
      # the host opened (cloudflared, garage test).
      chain input {
        type filter hook input priority filter - 10; policy accept;
        iifname "${network.bridge}" ct state established,related accept
        iifname "${network.bridge}" limit rate 6/minute burst 10 packets log prefix "garage-in-drop: " level info
        iifname "${network.bridge}" counter drop comment "bay to host"
        # Nothing from a VPN tunnel to the host itself.
        iifname "gwg*" counter drop comment "tunnel to host"
      }

      chain forward {
        type filter hook forward priority filter - 10; policy accept;
        # WireGuard MTU ${toString garage.egress.mtu}: clamp the TCP MSS both ways.
        oifname "gwg*" tcp flags & (syn | rst) == syn tcp option maxseg size > ${mss} tcp option maxseg size set ${mss}
        iifname "gwg*" tcp flags & (syn | rst) == syn tcp option maxseg size > ${mss} tcp option maxseg size set ${mss}
        iifname "${network.bridge}" jump from_bay
        # A tunnel delivers only replies, and only to its own bay.
        iifname "gwg*" oifname != "${network.bridge}" counter drop comment "tunnel to anything but its bay"
    ${forEgress (e: ''
      iifname "${e.tun}" ip daddr != ${e.ipv4} counter drop comment "egress ${e.name}: tunnel to another bay"
    '')}
        oifname "${network.bridge}" ct state established,related accept
        oifname "${network.bridge}" counter drop comment "new connection into a bay"
      }

      chain from_bay {
        meta nfproto ipv6 counter drop comment "ipv6"
        # Kill switch: an egress bay leaves only through its own tunnel, never
        # the uplink (also when the tunnel is down or its routes are gone).
    ${forEgress (e: ''
      ip saddr ${e.ipv4} oifname != "${e.tun}" counter drop comment "egress ${e.name}: not via its tunnel"
      oifname "${e.tun}" ip saddr != ${e.ipv4} counter drop comment "egress ${e.name}: tunnel of another bay"
    '')}
        oifname != { ${uplinks} } counter drop comment "not the uplink"
        ip daddr { ${lib.concatStringsSep ", " blockedV4} } limit rate 6/minute burst 10 packets log prefix "garage-fwd-drop: " level info
        ip daddr { ${lib.concatStringsSep ", " blockedV4} } counter drop comment "private or special range"
        tcp dport 25 counter drop comment "smtp"
        ct state established,related accept
        ct state new add @bay_newconn { ip saddr limit rate over 50/second burst 200 packets } counter drop comment "rate limit"
        ip saddr ${network.cidr} accept
        counter drop comment "other"
      }

      chain postrouting {
        type nat hook postrouting priority srcnat; policy accept;
        ip saddr ${network.cidr} oifname "${cfg.uplinkInterface}" masquerade
    ${forEgress (e: ''
      ip saddr ${e.ipv4} oifname "${e.tun}" masquerade
    '')}
      }

      # Last check before NAT, and the counters `garage test` reads: an egress
      # bay's packet on the uplink is dropped here too; its DNS is counted on
      # the tunnel.
      chain egress {
        type filter hook postrouting priority filter; policy accept;
    ${forEgress (e: ''
      ip saddr ${e.ipv4} oifname "${cfg.uplinkInterface}" counter drop comment "egress ${e.name}: on the uplink"
      ip saddr ${e.ipv4} oifname "${e.tun}" meta l4proto { tcp, udp } th dport 53 counter comment "egress ${e.name}: dns via tunnel"
    '')}
      }
    }

    # Layer 2: each bay port may only use its own MAC and address, IPv4 and ARP only.
    table bridge garage
    delete table bridge garage
    table bridge garage {
      chain prerouting {
        type filter hook prerouting priority -200; policy accept;
    ${lib.concatStrings (
      lib.mapAttrsToList (_: b: ''
        iifname "${garage.tapName b}" ether saddr != ${b.mac} counter drop
        iifname "${garage.tapName b}" ether type ip ip saddr != ${b.ipv4} counter drop
        iifname "${garage.tapName b}" ether type arp arp saddr ip != ${b.ipv4} counter drop
      '') bays
    )}
        iifname "gbay*" ether type != { ip, arp } counter drop
      }
    }
  '';

  # Common systemd sandboxing for root oneshots that only change networking.
  netAdminSandbox = {
    CapabilityBoundingSet = [ "CAP_NET_ADMIN" ];
    AmbientCapabilities = [ ];
    NoNewPrivileges = true;
    ProtectSystem = "strict";
    ProtectHome = true;
    PrivateTmp = true;
    PrivateDevices = true;
    ProtectKernelModules = true;
    ProtectKernelLogs = true;
    ProtectControlGroups = true;
    ProtectClock = true;
    ProtectHostname = true;
    ProtectProc = "invisible";
    RestrictNamespaces = true;
    RestrictRealtime = true;
    RestrictSUIDSGID = true;
    LockPersonality = true;
    MemoryDenyWriteExecute = true;
    RestrictAddressFamilies = [
      "AF_NETLINK"
      "AF_UNIX"
    ];
    SystemCallArchitectures = "native";
    SystemCallFilter = [
      "@system-service"
      "~@privileged @resources"
    ];
    IPAddressDeny = "any";
    UMask = "0077";
  };

  attachTap =
    b:
    let
      tap = garage.tapName b;
    in
    pkgs.writeShellScript "garage-attach-${tap}" ''
      set -euo pipefail
      echo 1 > /proc/sys/net/ipv6/conf/${tap}/disable_ipv6
      ${ipBin} link set dev ${tap} master ${network.bridge}
      # Isolated ports cannot exchange frames with each other, only with the host side.
      ${bridgeBin} link set dev ${tap} isolated on
      ${ipBin} link set dev ${tap} up
    '';

  toolConfig = pkgs.writeText "garage.json" (
    builtins.toJSON {
      inherit network t3Port stateDir;
      inherit (garage) vsockPorts;
      uplink = cfg.uplinkInterface;
      public = {
        inherit (config.garage.public) enable credentialsFile configFile;
        unit = "garage-cloudflared.service";
        authDomain = "${garage.cloudflare.teamName}.cloudflareaccess.com";
      };
      bays = lib.mapAttrs (name: b: {
        vm = garage.vmName name;
        tap = garage.tapName b;
        inherit (b) ipv4;
        publicUrl =
          if config.garage.public.enable && (b.public or null) != null then
            "https://${garage.publicHostname b}"
          else
            null;
        # GitLab user ids in the bay's Access policy (not secret; checked by `garage test`).
        gitlabSubs = if (b.public or null) != null then b.public.gitlabSubs else [ ];
        # VPN egress (modules/egress.nix), or null: the bay leaves from the uplink.
        egress =
          if (b.egress or null) != null then
            {
              tunnel = garage.tunnelName b;
              table = garage.egressTable b;
              rulePriority = garage.egressRulePriority b;
              inherit (b.egress) wireguardConfig;
              unit = "garage-egress-${name}.service";
              inherit (garage.egress) mtu mss;
            }
          else
            null;
      }) bays;
    }
  );

  garageTool = pkgs.writeShellApplication {
    name = "garage";
    runtimeInputs = with pkgs; [
      bash
      coreutils
      gnugrep
      gnused
      gawk
      findutils
      iproute2
      nftables
      socat
      curl
      jq
      procps
      systemd
      wireguard-tools
      config.services.tailscale.package
      config.garage.public.package
    ];
    text = ''
      GARAGE_CONFIG=${toolConfig}
    ''
    + builtins.readFile ../tests/garage-host.sh;
  };

  perBay =
    name: b:
    let
      vm = garage.vmName name;
    in
    {
      "microvm-tap-interfaces@${vm}" = {
        requires = [ "garage-bridge.service" ];
        after = [ "garage-bridge.service" ];
        serviceConfig.ExecStartPost = [ "${attachTap b}" ];
      };

      "microvm@${vm}" = {
        # Fail closed: no bridge or no isolation rules, no bay.
        requires = [
          "garage-bridge.service"
          "garage-nftables.service"
        ];
        after = [
          "garage-bridge.service"
          "garage-nftables.service"
        ];
        serviceConfig = {
          # microvm.nix forwards systemd notifications from the guest over the
          # vsock when a CID is set. The vsock is used only host -> bay here,
          # so the guest gets no channel into a host unit.
          Type = lib.mkForce "simple";
          NotifyAccess = lib.mkForce "none";

          # The hypervisor runs as the unprivileged microvm user (microvm.nix);
          # on top of that it sees no home directories and no writable path
          # except its own state directory.
          ProtectHome = true;
          ProtectSystem = "strict";
          ReadWritePaths = [ "${stateDir}/${vm}" ];
          PrivateTmp = true;
          NoNewPrivileges = true;
          CapabilityBoundingSet = [ "" ];
          AmbientCapabilities = [ "" ];
          DevicePolicy = "closed";
          DeviceAllow = [
            "/dev/kvm rw"
            "/dev/net/tun rw"
            "/dev/vhost-net rw"
          ];
          ProtectKernelTunables = true;
          ProtectKernelModules = true;
          ProtectKernelLogs = true;
          ProtectControlGroups = true;
          ProtectClock = true;
          ProtectHostname = true;
          ProtectProc = "invisible";
          RestrictNamespaces = true;
          RestrictRealtime = true;
          RestrictSUIDSGID = true;
          LockPersonality = true;
          RestrictAddressFamilies = [
            "AF_UNIX"
            "AF_INET"
            "AF_INET6"
            "AF_NETLINK"
            "AF_VSOCK"
          ];
          SystemCallArchitectures = "native";
          IPAddressDeny = "any";
          # RAM cap including hypervisor overhead; the host's own work wins CPU/IO contention.
          MemoryMax = "${toString (b.mem + 1024)}M";
          CPUWeight = 50;
          IOWeight = 50;
        };
      };
    };
in
{
  imports = [
    microvmHost
    (import ./public.nix { inherit garage bays outputs; })
    (import ./egress.nix { inherit garage bays netAdminSandbox; })
  ];

  options.garage = {
    enable = lib.mkEnableOption "agent-garage bays";
    uplinkInterface = lib.mkOption {
      type = lib.types.str;
      example = "eth0";
      description = "Interface that bay traffic is masqueraded out of (the wired uplink). Bays can reach nothing else.";
    };
  };

  config = lib.mkMerge [
    # The microvm.nix host module is on by default once imported; tie it to garage.enable.
    { microvm.host.enable = cfg.enable; }

    (lib.mkIf cfg.enable {
      assertions = garage.checks bays ++ [
        {
          assertion = builtins.match "[a-zA-Z0-9._-]{1,15}" cfg.uplinkInterface != null;
          message = "garage.uplinkInterface must be an interface name";
        }
      ];

      microvm.vms = lib.mapAttrs' (
        name: _:
        lib.nameValuePair (garage.vmName name) {
          evaluatedConfig = bayConfigs.${garage.vmName name};
          restartIfChanged = true;
          autostart = true;
        }
      ) bays;

      # No memory deduplication between VMs (cross-VM side channels).
      hardware.ksm.enable = lib.mkForce false;
      # microvm.nix installs qemu-bridge-helper (cap_net_admin) with "allow all";
      # bays use cloud-hypervisor taps, so the helper may use no bridge at all.
      environment.etc."qemu/bridge.conf".text = lib.mkForce "deny all\n";

      boot.kernel.sysctl."net.ipv4.ip_forward" = lib.mkDefault 1;

      systemd.services = lib.mkMerge (
        [
          {
            garage-bridge = {
              description = "agent-garage: bay bridge ${network.bridge}";
              wantedBy = [ "multi-user.target" ];
              after = [ "systemd-modules-load.service" ];
              # Kept up across restarts of this unit: no ExecStop.
              serviceConfig = netAdminSandbox // {
                Type = "oneshot";
                RemainAfterExit = true;
                # Writes /proc/sys/net/ipv6/conf/<bridge>/disable_ipv6.
                ProtectKernelTunables = false;
                ExecStart = pkgs.writeShellScript "garage-bridge-up" ''
                  set -euo pipefail
                  if ! ${ipBin} link show dev ${network.bridge} >/dev/null 2>&1; then
                    ${ipBin} link add ${network.bridge} type bridge
                  fi
                  echo 1 > /proc/sys/net/ipv6/conf/${network.bridge}/disable_ipv6
                  ${ipBin} link set dev ${network.bridge} type bridge stp_state 0 mcast_snooping 0
                  ${ipBin} addr replace ${network.gateway}/${toString network.prefixLength} dev ${network.bridge}
                  ${ipBin} link set dev ${network.bridge} up
                '';
              };
            };

            garage-nftables = {
              description = "agent-garage: bay isolation rules";
              wantedBy = [ "multi-user.target" ];
              before = [ "network-pre.target" ];
              wants = [ "network-pre.target" ];
              # Loading replaces the tables atomically. There is no ExecStop on
              # purpose: stopping the unit never removes the isolation.
              reloadIfChanged = true;
              serviceConfig = netAdminSandbox // {
                Type = "oneshot";
                RemainAfterExit = true;
                ProtectKernelTunables = true;
                ExecStart = "${nft} -f ${rules}";
                ExecReload = "${nft} -f ${rules}";
              };
            };
          }
        ]
        ++ lib.mapAttrsToList perBay bays
      );

      environment.systemPackages = [ garageTool ];

      # Keep the pinned agent-garage source alive as long as this generation exists.
      system.extraDependencies = [ self.outPath ];
    })
  ];
}
