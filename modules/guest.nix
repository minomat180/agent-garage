# NixOS configuration of one bay (microVM guest). Built only from this repo:
# nothing of the host is mounted, copied or named here (docs/design.md 7.1). The
# guest receives its own bay attributes (address, MAC, size), never its name.
{
  lib,
  pkgs,
  garage,
  bay,
  ...
}:
let
  inherit (garage) network t3Port vsockPorts;

  t3 = pkgs.callPackage ../pkgs/t3.nix { };

  selftest = pkgs.writeShellApplication {
    name = "bay-selftest";
    runtimeInputs = with pkgs; [
      bash
      coreutils
      gnugrep
      gnused
      gawk
      findutils
      diffutils
      iproute2
      iputils
      getent
      curl
      util-linux
      procps
      nix
      systemd
    ];
    # The script sets its own options (it must keep going after a failed check).
    bashOptions = [ ];
    text = builtins.readFile ../tests/bay-selftest.sh;
  };

  # vsock services answer only the host (CID 2). systemd passes the peer as
  # REMOTE_ADDR="vsock:<cid>:<port>"; anything else (a local process using
  # vsock loopback, a missing address) is refused. Output goes through a pipe:
  # Node (T3) cannot write to an AF_VSOCK socket as stdout directly.
  hostOnly =
    name: cmd:
    pkgs.writeShellScript name ''
      set -o pipefail
      case "''${REMOTE_ADDR:-}" in
        vsock:2:*|vsock:2) ;;
        *) echo "refused: peer ''${REMOTE_ADDR:-unknown} is not the host"; exit 1 ;;
      esac
      ${cmd} 2>&1 | ${pkgs.coreutils}/bin/cat
    '';

  home = "/home/bay";
in
{
  system.stateVersion = "26.11";

  # ---------------------------------------------------------------- microVM
  microvm = {
    hypervisor = "cloud-hypervisor";
    inherit (bay) vcpu mem;
    # No host paths at all: no virtiofs/9p shares, so the guest boots from its
    # own read-only store image (its closure only), not the host's /nix/store.
    shares = lib.mkForce [ ];
    storeOnDisk = true;
    storeDiskType = "erofs";
    # Writable store (builds inside the bay) on the bay's own volume.
    writableStoreOverlay = "/data/nix/rw-store";
    volumes = [
      {
        image = "data.img";
        label = "bay-data";
        mountPoint = "/data";
        size = bay.volumeGiB * 1024;
        fsType = "ext4";
      }
    ];
    interfaces = [
      {
        type = "tap";
        id = garage.tapName bay;
        inherit (bay) mac;
      }
    ];
    # Host <-> bay control channel (pairing links, acceptance tests). The host
    # module turns off the systemd notify forwarding that microvm.nix would
    # attach to this vsock, so the guest cannot send anything to the host.
    vsock.cid = garage.vsockCid bay;
  };

  fileSystems."/data".neededForBoot = true;
  # /home lives on the volume. /data/home is created before the bind mount.
  fileSystems."/home" = {
    device = "/data/home";
    fsType = "none";
    options = [ "bind" ];
    depends = [ "/data" ];
  };
  systemd.services.bay-data-dirs = {
    description = "Create directories on the bay volume";
    unitConfig = {
      DefaultDependencies = false;
      RequiresMountsFor = [ "/data" ];
    };
    before = [ "home.mount" ];
    requiredBy = [ "home.mount" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = "${pkgs.coreutils}/bin/mkdir -p -m 0755 /data/home /data/nix-build";
    };
  };

  # --------------------------------------------------------------- network
  networking = {
    hostName = "bay";
    useDHCP = false;
    useNetworkd = true;
    enableIPv6 = false;
    inherit (network) nameservers;
    nftables.enable = true;
    firewall = {
      enable = true;
      allowPing = false;
      # T3 only, and only from the host end of the bridge.
      extraInputRules = ''
        ip saddr ${network.gateway} tcp dport ${toString t3Port} accept
      '';
    };
  };
  systemd.network.networks."10-garage" = {
    matchConfig.MACAddress = bay.mac;
    address = [ "${bay.ipv4}/${toString network.prefixLength}" ];
    routes = [ { Gateway = network.gateway; } ];
    networkConfig = {
      LinkLocalAddressing = "no";
      IPv6AcceptRA = false;
    };
    linkConfig.RequiredForOnline = "routable";
  };
  services.resolved.enable = false;
  # No console logins: nobody has a password, and the serial line only feeds the host log.
  systemd.services."serial-getty@ttyS0".enable = false;
  systemd.services."serial-getty@hvc0".enable = false;
  systemd.services."getty@tty1".enable = false;
  systemd.services."autovt@".enable = false;
  services.openssh.enable = false;

  # ----------------------------------------------------------------- users
  users = {
    mutableUsers = false;
    # No passwords anywhere: T3's terminal is the shell, sudo needs none.
    allowNoPasswordLogin = true;
    users.root.hashedPassword = "!";
    users.bay = {
      isNormalUser = true;
      inherit home;
      extraGroups = [ "wheel" ];
      hashedPassword = "!";
      linger = true;
    };
  };
  security.sudo.wheelNeedsPassword = false;

  systemd.tmpfiles.settings."10-bay" = {
    ${home}.d = {
      user = "bay";
      group = "users";
      mode = "0700";
    };
    "${home}/.claude".d = {
      user = "bay";
      group = "users";
      mode = "0700";
    };
    # Rules every agent in the bay loads (scope: this machine only).
    "${home}/.claude/CLAUDE.md"."L+".argument = "${../guest/bay-rules.md}";
  };

  # -------------------------------------------------------------- software
  nixpkgs.config.allowUnfreePredicate = pkg: builtins.elem (lib.getName pkg) [ "claude-code" ];

  environment.systemPackages = with pkgs; [
    claude-code
    t3
    nodejs
    git
    gh
    glab
    tmux
    curl
    jq
    ripgrep
    fd
    vim
    htop
    file
    unzip
    which
  ];

  # T3 ships prebuilt binaries (official release, unmodified); nix-ld provides
  # the standard dynamic loader path for them.
  programs.nix-ld.enable = true;

  nix.settings = {
    experimental-features = [
      "nix-command"
      "flakes"
    ];
    auto-optimise-store = false;
    # Builds go to the volume, not the RAM-backed root.
    build-dir = "/data/nix-build";
  };
  nix.channel.enable = false;
  documentation.nixos.enable = false;

  # ------------------------------------------------------------------- T3
  systemd.user.services.t3code = {
    description = "T3 Code server";
    wantedBy = [ "default.target" ];
    unitConfig.ConditionUser = "bay";
    environment = {
      T3CODE_HOME = "${home}/.t3";
      SHELL = "/run/current-system/sw/bin/bash";
      PATH = lib.mkForce "${home}/.local/bin:${home}/.nix-profile/bin:/etc/profiles/per-user/bay/bin:/run/wrappers/bin:/run/current-system/sw/bin";
    };
    serviceConfig = {
      WorkingDirectory = home;
      ExecStart = "${lib.getExe t3} serve --host ${bay.ipv4} --port ${toString t3Port} --base-dir ${home}/.t3 --no-browser ${home}";
      Restart = "always";
      RestartSec = 3;
    };
  };

  # ------------------------------------------------- host control (vsock)
  # Pairing: prints a fresh one-time T3 pairing link (15 min) for the host.
  systemd.sockets.bay-pair = {
    wantedBy = [ "sockets.target" ];
    socketConfig = {
      ListenStream = "vsock::${toString vsockPorts.pair}";
      Accept = true;
      MaxConnections = 2;
    };
  };
  systemd.services."bay-pair@" = {
    description = "Mint a T3 pairing link for the host";
    serviceConfig = {
      User = "bay";
      Group = "users";
      StandardInput = "socket";
      StandardOutput = "socket";
      StandardError = "socket";
      RuntimeMaxSec = 60;
      Environment = [ "T3CODE_HOME=${home}/.t3" ];
      ExecStart = hostOnly "bay-pair" "${lib.getExe t3} pair --base-dir ${home}/.t3 --ttl 15m --label host-pairing-link";
    };
  };

  # Acceptance tests (tests/bay-selftest.sh), targets supplied by the host.
  systemd.sockets.bay-selftest = {
    wantedBy = [ "sockets.target" ];
    socketConfig = {
      ListenStream = "vsock::${toString vsockPorts.selftest}";
      Accept = true;
      MaxConnections = 1;
    };
  };
  systemd.services."bay-selftest@" = {
    description = "agent-garage acceptance tests";
    serviceConfig = {
      StandardInput = "socket";
      StandardOutput = "socket";
      StandardError = "journal";
      RuntimeMaxSec = 600;
      ExecStart = hostOnly "bay-selftest" (lib.getExe selftest);
    };
  };
}
