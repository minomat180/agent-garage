# VPN egress: a bay with `egress` in the site sends all of its internet
# traffic (DNS included) through a WireGuard tunnel that runs on the host, not
# in the bay (the bay's user has sudo). Policy routing on the bay's source
# address picks the tunnel; the host's own routes, Tailscale and the other
# bays are untouched.
#
#   garage-egress-<name>.service   creates gwg<octet> from the wg-quick file
#                                  (read at run time through LoadCredential, so
#                                  the private key never enters the store),
#                                  routing table 1000 + octet, ip rule
#                                  "from <bay> lookup <table>" at 4000 + octet.
#
# Kill switch, three layers: the table falls back to "unreachable" when the
# tunnel is gone (the rule and that route stay when the unit stops); the
# nftables rules (modules/host.nix, loaded independently of this unit) drop
# any packet of the bay that would leave through anything but its own tunnel;
# and a postrouting rule drops it on the uplink once more.
{
  garage,
  bays,
  netAdminSandbox,
}:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  inherit (garage) network;
  egressBays = garage.egressBays bays;

  ipBin = "${pkgs.iproute2}/bin/ip";
  wgBin = "${pkgs.wireguard-tools}/bin/wg";
  awkBin = "${pkgs.gawk}/bin/awk";
  grepBin = "${pkgs.gnugrep}/bin/grep";

  # Keys `wg setconf` takes from a wg-quick file; Address, DNS, MTU and the
  # wg-quick hooks are dropped (no PreUp/PostUp ever runs). AllowedIPs is
  # forced to IPv4: bays have no IPv6.
  wgFilter = pkgs.writeText "garage-wg-filter.awk" ''
    /^[[:space:]]*(#|$)/ { next }
    /^[[:space:]]*\[(Interface|Peer)\][[:space:]]*$/ { print; next }
    {
      k = $0
      sub(/[[:space:]]*=.*/, "", k)
      gsub(/[[:space:]]/, "", k)
      k = tolower(k)
      if (k == "privatekey" || k == "publickey" || k == "presharedkey" || k == "persistentkeepalive") print
      else if (k == "endpoint") print
      else if (k == "allowedips") print "AllowedIPs = 0.0.0.0/0"
    }
  '';

  unitName = name: "garage-egress-${name}";

  egressUnit =
    name: b:
    let
      tun = garage.tunnelName b;
      table = toString (garage.egressTable b);
      prio = toString (garage.egressRulePriority b);
      vm = garage.vmName name;
    in
    {
      ${unitName name} = {
        description = "agent-garage: VPN egress of ${vm} (WireGuard ${tun})";
        wantedBy = [ "multi-user.target" ];
        requires = [
          "garage-bridge.service"
          "garage-nftables.service"
        ];
        after = [
          "systemd-modules-load.service"
          "garage-bridge.service"
          "garage-nftables.service"
        ];
        before = [ "microvm@${vm}.service" ];
        serviceConfig = netAdminSandbox // {
          Type = "oneshot";
          RemainAfterExit = true;
          # Writes /proc/sys/net/ipv6/conf/<tunnel>/disable_ipv6.
          ProtectKernelTunables = false;
          LoadCredential = [ "wg.conf:${b.egress.wireguardConfig}" ];
          ExecStart = pkgs.writeShellScript "${unitName name}-up" ''
            set -euo pipefail
            conf="$CREDENTIALS_DIRECTORY/wg.conf"
            # Non-secret fields, checked before anything is created. Values are
            # never echoed (the file holds the private key).
            addr=$(${awkBin} 'tolower($0) ~ /^[[:space:]]*address[[:space:]]*=/ { sub(/^[^=]*=/, ""); print }' "$conf" |
              tr ',' '\n' | tr -d ' \t\r' | ${grepBin} -E -m1 '^([0-9]{1,3}\.){3}[0-9]{1,3}/32$' || true)
            [ -n "$addr" ] || { echo "no IPv4 /32 Address in ${b.egress.wireguardConfig}" >&2; exit 1; }
            ${awkBin} 'tolower($0) ~ /^[[:space:]]*endpoint[[:space:]]*=/ { sub(/^[^=]*=/, ""); gsub(/[[:space:]]/, ""); print }' "$conf" |
              ${grepBin} -q -x -E '([0-9]{1,3}\.){3}[0-9]{1,3}:[0-9]{1,5}' ||
              { echo "Endpoint in ${b.egress.wireguardConfig} must be IPv4:port" >&2; exit 1; }

            ${ipBin} link del dev ${tun} 2>/dev/null || true
            ${ipBin} link add dev ${tun} type wireguard
            echo 1 > /proc/sys/net/ipv6/conf/${tun}/disable_ipv6
            ${wgBin} setconf ${tun} <(${awkBin} -f ${wgFilter} "$conf")
            ${ipBin} addr add "$addr" dev ${tun}
            ${ipBin} link set dev ${tun} mtu ${toString garage.egress.mtu} up

            # Table for the bay: its tunnel, the bridge (replies to the host,
            # e.g. cloudflared), and "unreachable" once the tunnel is gone.
            ${ipBin} route replace ${network.cidr} dev ${network.bridge} table ${table}
            ${ipBin} route replace default dev ${tun} table ${table}
            ${ipBin} route replace unreachable default metric 4096 table ${table}
            while ${ipBin} rule del priority ${prio} 2>/dev/null; do :; done
            ${ipBin} rule add priority ${prio} from ${b.ipv4}/32 lookup ${table}
          '';
          # Only the tunnel goes away: the rule and the unreachable route stay,
          # so the bay is cut off, not routed out of the uplink.
          ExecStop = "-${ipBin} link del dev ${tun}";
        };
      };

      "microvm@${vm}" = {
        wants = [ "${unitName name}.service" ];
        after = [ "${unitName name}.service" ];
      };
    };
in
{
  config = lib.mkIf (config.garage.enable && egressBays != { }) {
    assertions = lib.mapAttrsToList (name: b: {
      assertion = !lib.hasPrefix "/nix/store" b.egress.wireguardConfig;
      message = "agent-garage: bay '${name}': egress.wireguardConfig must not be in the Nix store";
    }) egressBays;

    # Loaded at boot: the unit itself may not load kernel modules. The tunnel
    # is not listed as unmanaged for NetworkManager (that would restart it on
    # deploy); NetworkManager leaves externally created devices alone, like
    # the bridge and the taps.
    boot.kernelModules = [ "wireguard" ];

    systemd.services = lib.mkMerge (lib.mapAttrsToList egressUnit egressBays);
  };
}
