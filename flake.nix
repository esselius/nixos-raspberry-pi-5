{
  description = "NixOS on Raspberry Pi 5 with an NVMe root: reusable modules plus an imaging/provisioning CLI";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    nixos-hardware = {
      url = "github:NixOS/nixos-hardware";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    impermanence = {
      url = "github:nix-community/impermanence";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      nixos-hardware,
      disko,
      impermanence,
    }:
    let
      systems = [
        "aarch64-darwin"
        "x86_64-darwin"
        "aarch64-linux"
        "x86_64-linux"
      ];

      perSystem = f: nixpkgs.lib.genAttrs systems (system: f system nixpkgs.legacyPackages.${system});

      # Public key used by the example host and the demo bootstrap image. This is
      # the author's key, copied from the project this was extracted from;
      # replace it with your own in your flake.
      exampleSshKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFMdasDSm/XlOpv15asMENnQ/E9W9rXExBcUAVd/G6Mo";

      bootstrap = self.lib.mkPi5Installer {
        sshAuthorizedKeys = [ exampleSshKey ];
      };

      exampleHost = nixpkgs.lib.nixosSystem {
        system = "aarch64-linux";
        modules = [
          self.nixosModules.default
          ./examples/host.nix
        ];
      };
    in
    {
      # Modules are grouped by concern, but the flake wrappers close over the
      # flake inputs. Consumers therefore never have to pass `inputs` through
      # `specialArgs` or import disko/impermanence/nixos-hardware themselves.
      nixosModules = {
        default =
          { ... }:
          {
            imports = [
              nixos-hardware.nixosModules.raspberry-pi-5
              disko.nixosModules.disko
              impermanence.nixosModules.impermanence
              ./modules/default.nix
            ];
          };

        raspberry-pi-5 =
          { ... }:
          {
            imports = [
              nixos-hardware.nixosModules.raspberry-pi-5
              ./modules/raspberry-pi-5.nix
            ];
          };

        nvme-root =
          { ... }:
          {
            imports = [
              disko.nixosModules.disko
              ./modules/nvme-root.nix
            ];
          };

        sd-boot =
          { ... }:
          {
            imports = [
              disko.nixosModules.disko
              ./modules/sd-boot.nix
            ];
          };

        impermanence =
          { ... }:
          {
            imports = [
              impermanence.nixosModules.impermanence
              ./modules/impermanence.nix
            ];
          };

        installer =
          { ... }:
          {
            imports = [
              nixos-hardware.nixosModules.raspberry-pi-5
              ./modules/raspberry-pi-5.nix
              ./modules/installer.nix
            ];
          };
      };

      lib.mkPi5Installer =
        {
          system ? "aarch64-linux",
          hostName ? "pi5-bootstrap",
          stateVersion ? "26.05",
          sshAuthorizedKeys ? [ ],
          extraModules ? [ ],
          specialArgs ? { },
        }:
        nixpkgs.lib.nixosSystem {
          inherit system specialArgs;
          modules = [
            self.nixosModules.installer
            {
              pi5.installer = {
                hostName = nixpkgs.lib.mkDefault hostName;
                sshAuthorizedKeys = nixpkgs.lib.mkDefault sshAuthorizedKeys;
              };
              system.stateVersion = nixpkgs.lib.mkDefault stateVersion;
            }
          ]
          ++ extraModules;
        };

      nixosConfigurations = {
        # A throwaway installer image. It is a normal nixosConfiguration so the
        # CLI can address it as `.#pi5-bootstrap`.
        pi5-bootstrap = bootstrap;

        # Evaluation example for the full host stack. It is not meant to be a
        # real machine; see examples/host.nix.
        pi5-example = exampleHost;
      };

      images.pi5-bootstrap = bootstrap.config.system.build.sdImage;

      packages = perSystem (
        system: pkgs:
        let
          pi5-image = pkgs.callPackage ./nix/pi5-image.nix { };
        in
        {
          inherit pi5-image;
          # Re-export the pinned installer so consumers can use this flake as
          # their only source of nixos-anywhere.
          nixos-anywhere = pkgs.nixos-anywhere;
          default = pi5-image;
        }
      );

      apps = perSystem (
        system: _: {
          pi5-image = {
            type = "app";
            program = "${self.packages.${system}.pi5-image}/bin/pi5-image";
            meta.description = "Build, flash, and install NixOS on a Raspberry Pi 5 with an NVMe root";
          };
          default = self.apps.${system}.pi5-image;
        }
      );

      devShells = perSystem (
        _: pkgs: {
          default = pkgs.mkShell {
            packages = [
              pkgs.nixos-anywhere
              pkgs.zstd
              pkgs.shellcheck
              pkgs.nixfmt
              pkgs.fd
            ];
          };
        }
      );

      formatter = perSystem (
        _: pkgs:
        pkgs.writeShellApplication {
          name = "fmt-nixos-raspberry-pi-5";
          runtimeInputs = [
            pkgs.fd
            pkgs.nixfmt
          ];
          text = ''
            if [ "$#" -eq 0 ]; then
              fd --extension nix --exec nixfmt {}
            elif [ "$1" = "--check" ]; then
              fd --extension nix --exec nixfmt --check {}
            else
              nixfmt "$@"
            fi
          '';
        }
      );

      checks = perSystem (
        system: pkgs:
        let
          # Force evaluation of every host closure. This catches broken module
          # wiring without building an aarch64-linux system on a Mac.
          drvs = map (c: c.config.system.build.toplevel) (builtins.attrValues self.nixosConfigurations) ++ [
            bootstrap.config.system.build.sdImage
          ];
        in
        {
          # Cross-system check that the CLI wrapper still builds (and passes
          # shellcheck) on this platform.
          pi5-image = self.packages.${system}.pi5-image;

          eval-all = builtins.deepSeq (map (d: d.drvPath) drvs) (
            pkgs.runCommand "eval-all" { } ''
              touch $out
            ''
          );

          fmt =
            pkgs.runCommand "fmt-check"
              {
                nativeBuildInputs = [
                  pkgs.fd
                  pkgs.nixfmt
                ];
                src = self;
              }
              ''
                cd "$src"
                fd --extension nix --exec nixfmt --check {}
                touch $out
              '';

          shellcheck =
            pkgs.runCommand "shellcheck"
              {
                nativeBuildInputs = [ pkgs.shellcheck ];
                src = self;
              }
              ''
                cd "$src"
                shellcheck scripts/*.sh
                touch $out
              '';
        }
      );
    };
}
