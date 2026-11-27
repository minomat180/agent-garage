# Sleep mode: a bay with `sleepAfter` in the site does not run while nobody
# uses it. Stopped means stopped: no hypervisor process, no RAM, no CPU; the
# volume (home, writable store) stays on disk. The first request wakes it.
#
#   garage-wake-<name>.socket    listens on the bay's wake address, a loopback
#                                address of the host (127.180.0.<octet>, port
#                                13773). cloudflared sends the bay's hostname
#                                there instead of to the bay; the Access check
#                                in cloudflared is unchanged and comes first.
#                                cloudflared requires this socket: if it cannot
#                                be bound, the tunnel does not start.
#   garage-wake-<name>.service   started by the first connection: starts
#                                microvm@bay-<name>, waits until T3 answers,
#                                then relays (systemd-socket-proxyd). Exits
#                                when no connection has been open for a while.
#   garage-sleep-<name>.timer    every few minutes: the bay counts as in use
#                                while the relay runs (an open T3 tab holds a
#                                connection) or the VM uses more CPU than an
#                                idle one (agents working with the browser
#                                closed). Idle for `sleepAfter` minutes: the
#                                VM is shut down cleanly.
#
# The wake address is loopback only, so it is no new way into a bay: nothing
# outside the host can reach it, and a bay cannot reach the host at all.
{
  garage,
  bays,
}:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  inherit (garage) t3Port;
  sleepBays = garage.sleepBays bays;
  port = toString t3Port;

  wakeUnit =
    name: b:
    let
      vm = garage.vmName name;
      wake = garage.wakeUnitName name;
      idle = garage.sleepUnitName name;
      addr = garage.wakeAddress b;
      state = "/run/${idle}/state";

      # T3 accepts connections before it serves pages (503 while it starts):
      # wait for a real answer, so the first request does not get an error.
      waitForT3 = pkgs.writeShellScript "${wake}-wait" ''
        for _ in $(${pkgs.coreutils}/bin/seq 1 200); do
          if ${pkgs.curl}/bin/curl -fsS -o /dev/null --max-time 3 http://${b.ipv4}:${port}/ 2>/dev/null; then exit 0; fi
          ${pkgs.coreutils}/bin/sleep 0.5
        done
        echo "T3 in ${vm} did not answer on ${b.ipv4}:${port}" >&2
        exit 1
      '';

      idleCheck = pkgs.writeShellScript "${idle}-check" ''
        set -euo pipefail
        PATH=${
          lib.makeBinPath [
            pkgs.coreutils
            config.systemd.package
          ]
        }
        vmUnit=microvm@${vm}.service
        if ! systemctl is-active --quiet "$vmUnit"; then
          rm -f ${state}
          exit 0
        fi
        now=$(date +%s)
        cpu=$(systemctl show -p CPUUsageNSec --value "$vmUnit")
        case $cpu in '''|*[!0-9]*) cpu=0 ;; esac
        prevT=0 prevCpu=0 idleSince=$now
        if [ -r ${state} ]; then read -r prevT prevCpu idleSince <${state} || true; fi

        busy=""
        # A connection was open within the relay's idle time.
        if systemctl is-active --quiet ${wake}.service; then busy="connection"; fi
        # CPU since the last check, in percent of one core. No earlier sample
        # (just started) counts as busy.
        if [ "$prevT" -le 0 ] || [ "$now" -le "$prevT" ] || [ "$cpu" -lt "$prevCpu" ]; then
          busy=''${busy:-started}
        elif [ $(((cpu - prevCpu) / (now - prevT) / 10000000)) -ge ${toString garage.sleep.busyCpuPercent} ]; then
          busy=''${busy:-cpu}
        fi
        [ -z "$busy" ] || idleSince=$now
        echo "$now $cpu $idleSince" >${state}

        if [ $((now - idleSince)) -ge ${toString (b.sleepAfter * 60)} ]; then
          echo "${vm}: idle for $(((now - idleSince) / 60)) min, going to sleep"
          rm -f ${state}
          systemctl stop "$vmUnit"
        fi
      '';
    in
    {
      sockets.${wake} = {
        description = "agent-garage: wake address of ${vm}";
        wantedBy = [ "sockets.target" ];
        socketConfig = {
          ListenStream = "${addr}:${toString garage.sleep.wakePort}";
          # The relay is the only thing started from here, however fast
          # requests come in while the bay boots.
          TriggerLimitIntervalSec = 0;
        };
      };

      services = {
        ${wake} = {
          description = "agent-garage: wake ${vm} and relay to its T3";
          requires = [
            "microvm@${vm}.service"
            "${wake}.socket"
          ];
          after = [
            "microvm@${vm}.service"
            "${wake}.socket"
          ];
          serviceConfig = {
            ExecStartPre = waitForT3;
            ExecStart = "${config.systemd.package}/lib/systemd/systemd-socket-proxyd --exit-idle-time=${garage.sleep.relayIdle} ${b.ipv4}:${port}";
            TimeoutStartSec = 120;

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
              "AF_UNIX"
            ];
            SystemCallArchitectures = "native";
            SystemCallFilter = [
              "@system-service"
              "~@privileged @resources"
            ];
            # Its own bay and its own wake address, nothing else.
            IPAddressAllow = [
              "${b.ipv4}/32"
              "${addr}/32"
            ];
            IPAddressDeny = "any";
            UMask = "0077";
            MemoryMax = "128M";
            TasksMax = 64;
          };
        };

        ${idle} = {
          description = "agent-garage: put ${vm} to sleep when idle";
          serviceConfig = {
            Type = "oneshot";
            ExecStart = idleCheck;
            RuntimeDirectory = idle;
            RuntimeDirectoryPreserve = true;

            # Root, to ask systemd to stop the VM; nothing else.
            CapabilityBoundingSet = [ "" ];
            AmbientCapabilities = [ "" ];
            NoNewPrivileges = true;
            ProtectSystem = "strict";
            ProtectHome = true;
            PrivateTmp = true;
            PrivateDevices = true;
            PrivateNetwork = true;
            ProtectKernelTunables = true;
            ProtectKernelModules = true;
            ProtectKernelLogs = true;
            ProtectControlGroups = true;
            ProtectClock = true;
            ProtectHostname = true;
            RestrictNamespaces = true;
            RestrictRealtime = true;
            RestrictSUIDSGID = true;
            LockPersonality = true;
            MemoryDenyWriteExecute = true;
            RestrictAddressFamilies = [ "AF_UNIX" ];
            SystemCallArchitectures = "native";
            SystemCallFilter = [
              "@system-service"
              "~@privileged @resources"
            ];
            IPAddressDeny = "any";
            UMask = "0077";
          };
        };
      };

      timers.${idle} = {
        description = "agent-garage: idle check of ${vm}";
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnBootSec = "${toString garage.sleep.checkMinutes}min";
          OnUnitActiveSec = "${toString garage.sleep.checkMinutes}min";
          AccuracySec = "30s";
        };
      };
    };
in
{
  config = lib.mkIf (config.garage.enable && sleepBays != { }) {
    systemd = lib.mkMerge (lib.mapAttrsToList wakeUnit sleepBays);
  };
}
