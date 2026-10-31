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

    # U-Boot 2026.10 lives here. The main nixpkgs pin still ships U-Boot
    # 2026.07, which lacks the NVMe inbound address-translation fix, and it must
    # not float: newer nixos-unstable removed boot.initrd.systemd.enable, which
    # pi5.impermanence still uses. This input is only used for the Raspberry Pi
    # 5 U-Boot package.
    nixpkgs-uboot.url = "github:NixOS/nixpkgs/31ecbaca1bdefa45dffc409f0250bd8039ea0010";
  };

  outputs =
    {
      self,
      nixpkgs,
      nixos-hardware,
      disko,
      impermanence,
      nixpkgs-uboot,
    }:
    let
      systems = [
        "aarch64-darwin"
        "x86_64-darwin"
        "aarch64-linux"
        "x86_64-linux"
      ];

      perSystem = f: nixpkgs.lib.genAttrs systems (system: f system nixpkgs.legacyPackages.${system});

      # Public key used only by the demo host and demo bootstrap output. The
      # private half was discarded; nobody can log in with this image. Replace
      # it with your own key in your flake. Real installer configs should pass
      # their own sshAuthorizedKeys (or import an SSH module).
      exampleSshKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPVIgmsKXn3UwSmCQ7r0GnIKQ9rxh14VzYm4gtUHhaWi pi5-demo-test-only-no-private-key-retained";

      # U-Boot 2026.10 with Torsten Duwe's NVMe series and the boot_targets
      # removal follow-up. The patches and their provenance are documented in
      # nix/patches/uboot/README.md.
      ubootNvme = nixpkgs-uboot.legacyPackages.aarch64-linux.callPackage ./nix/uboot-nvme.nix { };

      bootstrap = self.lib.mkPi5Installer {
        sshAuthorizedKeys = [ exampleSshKey ];
      };

      exampleSdHost = nixpkgs.lib.nixosSystem {
        system = "aarch64-linux";
        modules = [
          self.nixosModules.default-sd-boot
          ./examples/host.nix
        ];
      };

      exampleNvmeHost = nixpkgs.lib.nixosSystem {
        system = "aarch64-linux";
        modules = [
          self.nixosModules.default-nvme-boot
          ./examples/nvme-boot/host.nix
        ];
      };
    in
    {
      # Modules are grouped by concern, but the flake wrappers close over the
      # flake inputs. Consumers therefore never have to pass `inputs` through
      # `specialArgs` or import disko/impermanence/nixos-hardware themselves.
      nixosModules = {
        # The stack without a boot medium. Choose one explicitly with
        # `sd-boot` or `nvme-boot`, or use one of the full-stack wrappers below.
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

        # Full stacks for the two supported boot media. Both are explicit
        # opt-ins; `default` alone is not bootable.
        default-sd-boot =
          { ... }:
          {
            imports = [
              self.nixosModules.default
              self.nixosModules.sd-boot
            ];
          };

        default-nvme-boot =
          { ... }:
          {
            imports = [
              self.nixosModules.default
              self.nixosModules.nvme-boot
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

        # NVMe-only boot: firmware + U-Boot + /boot live on the NVMe, so the SD
        # card is only the installer medium. This module needs the hardware and
        # nvme-root modules; `default-nvme-boot` wires all three together.
        nvme-boot =
          { ... }:
          {
            imports = [
              disko.nixosModules.disko
              ./modules/nvme-boot.nix
            ];
            pi5.nvmeBoot.ubootPackage = nixpkgs.lib.mkDefault ubootNvme;
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

        # Evaluation examples for the full host stacks. They are not meant to
        # be real machines; see examples/.
        pi5-example = exampleSdHost;
        pi5-nvme-example = exampleNvmeHost;
      };

      images.pi5-bootstrap = bootstrap.config.system.build.sdImage;

      packages = nixpkgs.lib.genAttrs systems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          pi5-image = pkgs.callPackage ./nix/pi5-image.nix { };
        in
        {
          inherit pi5-image;
          # Re-export the pinned installer so consumers can use this flake as
          # their only source of nixos-anywhere.
          nixos-anywhere = pkgs.nixos-anywhere;
          default = pi5-image;
        }
        // nixpkgs.lib.optionalAttrs (system == "aarch64-linux") {
          # The patched U-Boot used by nixosModules.nvme-boot. Exposed for
          # inspection (`strings .../u-boot.bin`) and manual testing.
          uboot-nvme = ubootNvme;
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

          mkAssertionConfig =
            extra:
            nixpkgs.lib.nixosSystem {
              system = "aarch64-linux";
              modules = [
                self.nixosModules.default-sd-boot
                {
                  networking.hostName = "assertion-test";
                  system.stateVersion = "26.05";
                }
                extra
              ];
            };

          mkNvmeConfig =
            extra:
            nixpkgs.lib.nixosSystem {
              system = "aarch64-linux";
              modules = [
                self.nixosModules.default-nvme-boot
                {
                  networking.hostName = "nvme-assertion-test";
                  system.stateVersion = "26.05";
                }
                extra
              ];
            };

          # `default` deliberately has no boot medium; importing it alone must
          # fail with the "choose sd-boot or nvme-boot" assertion.
          bareConfig = nixpkgs.lib.nixosSystem {
            system = "aarch64-linux";
            modules = [
              self.nixosModules.default
              {
                networking.hostName = "bare-assertion-test";
                system.stateVersion = "26.05";
              }
            ];
          };

          # Both boot media claim /boot; they must not be combined.
          bothBootConfig = nixpkgs.lib.nixosSystem {
            system = "aarch64-linux";
            modules = [
              self.nixosModules.default-sd-boot
              self.nixosModules.nvme-boot
              {
                networking.hostName = "both-boot-assertion-test";
                system.stateVersion = "26.05";
              }
            ];
          };

          fails = config: !(builtins.tryEval config.config.system.build.toplevel.drvPath).success;
          assertionsOk =
            fails (mkAssertionConfig {
              pi5.nvme.subvolumes = {
                "@root" = "/";
                "@persist" = "/persist";
                "@snapshots" = "/snapshots";
              };
            })
            && fails (mkAssertionConfig {
              pi5.sdBoot.device = "/dev/nvme0n1";
            })
            && fails (mkAssertionConfig {
              pi5.impermanence.persistPath = "/not-a-fs";
            })
            && fails bareConfig
            && fails bothBootConfig
            && fails (mkNvmeConfig {
              pi5.nvmeBoot.firmwareLabel = "NIXOS_BOOT";
            })
            && fails (mkNvmeConfig {
              pi5.nvmeBoot.ubootPackage = nixpkgs.legacyPackages.aarch64-linux.ubootRaspberryPiAarch64;
            })
            && !(fails (mkAssertionConfig { }))
            && !(fails (mkNvmeConfig { }));
        in
        {
          # Cross-system check that the CLI wrapper still builds (and passes
          # shellcheck) on this platform.
          pi5-image = self.packages.${system}.pi5-image;

          # Negative tests for the assertions that prevent data loss.
          assertions = pkgs.runCommand "assertions" { } (
            if assertionsOk then
              "touch $out"
            else
              ''
                echo "pi5 assertion checks failed: a known-bad config evaluated or the good config did not" >&2
                exit 1
              ''
          );

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
                shellcheck modules/scripts/*.sh scripts/*.sh
                touch $out
              '';
        }
        // nixpkgs.lib.optionalAttrs (system == "aarch64-linux") {
          # U-Boot is an aarch64-linux derivation; run the binary check only
          # where it can build natively (the CI arm64 Linux runner).
          uboot-nvme =
            pkgs.runCommand "uboot-nvme-check"
              {
                nativeBuildInputs = [ pkgs.gnugrep ];
              }
              ''
                grep -aq 'preboot=pci enum; usb start; nvme scan;' ${ubootNvme}/u-boot.bin
                grep -aq 'U-Boot 2026.10' ${ubootNvme}/u-boot.bin
                if grep -aq '^boot_targets=' ${ubootNvme}/u-boot.bin; then
                  echo "uboot-nvme: u-boot.bin still sets boot_targets; the v2 patch did not apply" >&2
                  exit 1
                fi
                touch $out
              '';
        }
      );
    };
}
