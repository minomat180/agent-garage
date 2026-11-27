{
  description = "agent-garage: isolated microVM workspaces for coding agents, behind Cloudflare Access";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    microvm = {
      url = "github:microvm-nix/microvm.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      microvm,
    }:
    let
      system = "x86_64-linux";
      inherit (nixpkgs) lib;
      pkgs = nixpkgs.legacyPackages.${system};

      # Everything built from one site (the bays and the Cloudflare constants,
      # see examples/site/site.nix). The host passes its site in, so nothing
      # site-specific lives in this repo.
      mkGarage =
        site:
        let
          garage = import ./lib/garage.nix {
            inherit lib;
            cloudflare = site.cloudflare or null;
          };
          bays = garage.validate (site.bays or { });

          mkBay =
            bay:
            lib.nixosSystem {
              specialArgs = { inherit garage bay; };
              modules = [
                microvm.nixosModules.microvm
                ./modules/guest.nix
                { nixpkgs.hostPlatform = system; }
              ];
            };

          bayConfigs = lib.mapAttrs' (name: bay: lib.nameValuePair (garage.vmName name) (mkBay bay)) bays;
        in
        {
          inherit garage bays bayConfigs;
          hostModule = import ./modules/host.nix {
            inherit
              self
              garage
              bays
              bayConfigs
              ;
            # Tunnel id and Access AUD tags (`garage-cf export`), or null.
            outputs = site.cloudflareOutputs or null;
            microvmHost = microvm.nixosModules.host;
          };
          tofuVars = garage.tofuVars bays;
        };

      # Used by `nix flake check` and as the documented starting point.
      example = mkGarage (import ./examples/site/site.nix);
      inherit (example) bayConfigs;
    in
    {
      lib = {
        # Host module for a site. In a non-flake /etc/nixos/configuration.nix:
        #   imports = [
        #     ((builtins.getFlake "git+file:///path/to/agent-garage?rev=<commit>").lib.hostModule
        #       (import ./agent-garage/site.nix))
        #   ];
        hostModule = site: (mkGarage site).hostModule;
        # Input of infra/cloudflare for a site (TF_VAR_garage, set by garage-cf).
        tofuVars = site: (mkGarage site).tofuVars;
      };

      # The example site's bays (built by `nix flake check`).
      nixosConfigurations = bayConfigs;

      packages.${system} = {
        t3 = pkgs.callPackage ./pkgs/t3.nix { };
      }
      // lib.mapAttrs' (
        name: c: lib.nameValuePair "${name}-runner" c.config.microvm.declaredRunner
      ) bayConfigs;

      checks.${system} = {
        t3 = self.packages.${system}.t3;
        # Host module evaluates against a minimal host and its helper passes shellcheck.
        host-eval =
          let
            host = lib.nixosSystem {
              modules = [
                example.hostModule
                {
                  nixpkgs.hostPlatform = system;
                  garage = {
                    enable = true;
                    uplinkInterface = "eth0";
                  };
                  boot.loader.grub.enable = false;
                  fileSystems."/" = {
                    device = "none";
                    fsType = "tmpfs";
                  };
                  system.stateVersion = "26.11";
                }
              ];
            };
          in
          pkgs.runCommand "host-eval" { } ''
            echo ${host.config.system.build.etc} > $out
            grep -q garage ${host.config.systemd.units."garage-nftables.service".unit}/garage-nftables.service
            # Public bays get cloudflared with the Access check on every ingress rule.
            grep -q 'LoadCredential=credentials.json:/var/lib/agent-garage/cloudflared/credentials.json' \
              ${host.config.systemd.units."garage-cloudflared.service".unit}/garage-cloudflared.service
            ${pkgs.jq}/bin/jq -e '[.ingress[] | select(.hostname) | .originRequest.access.required] | all and length > 0' \
              ${host.config.garage.public.configFile} >/dev/null
            ${pkgs.jq}/bin/jq -e '.ingress[-1] == {service: "http_status:404"}' ${host.config.garage.public.configFile} >/dev/null
            # VPN egress bays: the WireGuard file is read at run time (never a
            # store path) and nftables holds the kill switch for each of them.
            nftrules=$(grep -o '/nix/store/[^ ]*agent-garage.nft' \
              ${host.config.systemd.units."garage-nftables.service".unit}/garage-nftables.service | head -n1)
            ${lib.concatMapStrings (
              name:
              let
                u = "garage-egress-${name}.service";
              in
              ''
                grep -q 'LoadCredential=wg.conf:/' ${host.config.systemd.units.${u}.unit}/${u}
                if grep -q 'LoadCredential=wg.conf:/nix/store' ${
                  host.config.systemd.units.${u}.unit
                }/${u}; then exit 1; fi
                grep -q 'comment "egress ${name}: not via its tunnel"' "$nftrules"
                grep -q 'comment "egress ${name}: on the uplink"' "$nftrules"
              ''
            ) (lib.attrNames (example.garage.egressBays example.bays))}
          '';
        # infra/cloudflare: formatting and the helper script.
        infra-cloudflare =
          pkgs.runCommand "infra-cloudflare"
            {
              nativeBuildInputs = [
                pkgs.opentofu
                pkgs.shellcheck
              ];
            }
            ''
              tofu -chdir=${./infra/cloudflare} fmt -check -recursive
              shellcheck ${./infra/cloudflare/garage-cf}
              touch $out
            '';
      }
      // lib.mapAttrs' (
        name: c: lib.nameValuePair "${name}-toplevel" c.config.system.build.toplevel
      ) bayConfigs;

      formatter.${system} = pkgs.nixfmt;
    };
}
