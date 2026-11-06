{
  description = "NixOS on Raspberry Pi 5 with an NVMe root: reusable modules plus a throwaway SD-card installer";

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
        "aarch64-linux"
        "x86_64-linux"
      ];

      perSystem = f: nixpkgs.lib.genAttrs systems (system: f system nixpkgs.legacyPackages.${system});

      # U-Boot 2026.10 with Torsten Duwe's NVMe series and the boot_targets
      # removal follow-up. The patches and their provenance are documented in
      # pkgs/uboot-nvme/README.md.
      ubootNvme = nixpkgs-uboot.legacyPackages.aarch64-linux.callPackage ./pkgs/uboot-nvme { };

      # The main nixpkgs pin ships the -2711 EEPROM release, which has no Pi 5
      # (BCM2712) bootloader images. Rebuild the -2712 release with the local
      # package recipe until the pin catches up; the recipe is identical, only
      # version and source differ. Drop the override and the `package` default
      # when the main pin ships the -2712 release.
      eepromPackage = nixpkgs.legacyPackages.aarch64-linux.raspberrypi-eeprom.overrideAttrs (_old: rec {
        version = "2026.09.25-2712";
        src = nixpkgs.legacyPackages.aarch64-linux.fetchFromGitHub {
          owner = "raspberrypi";
          repo = "rpi-eeprom";
          tag = "v${version}";
          hash = "sha256-OBl122T7wcKLFoMqxF31vee3Y8oiapTIBYI42OBVQ4U=";
        };
      });
    in
    {
      # Modules are grouped by concern, but the flake wrappers close over the
      # flake inputs. Consumers therefore never have to pass `inputs` through
      # `specialArgs` or import disko/impermanence/nixos-hardware themselves.
      #
      # There is no default boot medium. `sd-boot` and `nvme-boot` are the two
      # full stacks and are named after the choice they make. Everything else
      # is a part of a stack; `base` is the stack with the boot medium removed.
      nixosModules = {
        # Full stacks. Import exactly one.
        sd-boot =
          { ... }:
          {
            imports = [
              self.nixosModules.base
              self.nixosModules.boot-sd
            ];
          };

        nvme-boot =
          { ... }:
          {
            imports = [
              self.nixosModules.base
              self.nixosModules.boot-nvme
            ];

            # The NVMe-first boot order is what this stack means. The settings
            # are defaults so a host can change them (for example drop
            # PCIE_PROBE on a HAT+ carrier). `enable` only converges an
            # installed host: the installer image that performs the first
            # install needs the same options (see lib.mkPi5Installer's `eeprom`
            # argument).
            pi5.eeprom = {
              enable = nixpkgs.lib.mkDefault true;
              settings = {
                BOOT_ORDER = nixpkgs.lib.mkDefault "0xf416";
                PCIE_PROBE = nixpkgs.lib.mkDefault 1;
              };
            };
          };

        # Everything except a boot medium. Only useful when composing yourself.
        # The three parts are the granular wrappers, so a change to one of them
        # cannot leave the base stack behind.
        base =
          { ... }:
          {
            imports = [
              self.nixosModules.hardware
              self.nixosModules.storage
              self.nixosModules.impermanence
              ./modules/require-boot-medium.nix
            ];
          };

        # Parts.
        boot-sd =
          { ... }:
          {
            imports = [
              disko.nixosModules.disko
              ./modules/boot/sd.nix
            ];
          };

        # Needs the hardware and storage modules; the `nvme-boot` stack wires
        # all three together and sets the patched U-Boot.
        boot-nvme =
          { ... }:
          {
            imports = [
              disko.nixosModules.disko
              ./modules/boot/nvme.nix
            ];
            pi5.nvmeBoot.ubootPackage = nixpkgs.lib.mkDefault ubootNvme;
          };

        hardware =
          { ... }:
          {
            imports = [
              nixos-hardware.nixosModules.raspberry-pi-5
              ./modules/raspberry-pi-5.nix
              ./modules/eeprom.nix
            ];

            # Always provide a package with BCM2712 bootloader images, even when
            # the consumer's nixpkgs predates them.
            pi5.eeprom.package = nixpkgs.lib.mkDefault eepromPackage;
          };

        storage =
          { ... }:
          {
            imports = [
              disko.nixosModules.disko
              ./modules/storage.nix
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

        # Turns a configuration into the throwaway bootstrap SD image. This is
        # a role, not a stack: use `lib.mkPi5Installer` rather than importing it
        # directly.
        installer =
          { ... }:
          {
            imports = [
              self.nixosModules.hardware
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
          eeprom ? { },
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
              # The installer runs before the target exists, so it is the only
              # place that can set the EEPROM for the first NVMe boot. Pass the
              # same settings the target host uses; see README "Quick start".
              pi5.eeprom = nixpkgs.lib.mkDefault eeprom;
              system.stateVersion = nixpkgs.lib.mkDefault stateVersion;
            }
          ]
          ++ extraModules;
        };

      # There are deliberately no host or installer configurations here: they
      # belong in the consuming flake, where the SSH keys are real. Build one
      # with `lib.mkPi5Installer` and point `images.<name>` at its `sdImage`.

      packages = nixpkgs.lib.genAttrs systems (
        system:
        nixpkgs.lib.optionalAttrs (system == "aarch64-linux") {
          # The patched U-Boot used by nixosModules.nvme-boot. Exposed for
          # inspection (`strings .../u-boot.bin`) and manual testing.
          uboot-nvme = ubootNvme;

          # The backported -2712 bootloader tool and images used by
          # pi5.eeprom. Exposed for the manual path: `nix build` it, then run
          # `sudo result/bin/rpi-eeprom-config --apply ...`.
          raspberrypi-eeprom = eepromPackage;
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
          lib = nixpkgs.lib;

          # A stack configuration with a minimal host. These are the only
          # full-stack configurations that exist in this repo: the hosts live in
          # the consuming flake, so a host here would be an example by another
          # name.
          mkStackConfig =
            modules: extra:
            lib.nixosSystem {
              system = "aarch64-linux";
              modules = modules ++ [
                {
                  networking.hostName = "stack-check";
                  system.stateVersion = "26.05";
                }
                extra
              ];
            };

          goodSd = mkStackConfig [ self.nixosModules.sd-boot ] { };
          goodNvme = mkStackConfig [ self.nixosModules.nvme-boot ] { };

          # The installer image is evaluated here rather than exported as a
          # flake output, because a real image needs real SSH keys. The key
          # below is deliberately not a usable one; the installer only asserts
          # that the root key list is non-empty.
          installerConfig = self.lib.mkPi5Installer {
            sshAuthorizedKeys = [ "check-only-not-a-key" ];
          };

          # Failed assertion messages, or null if evaluation itself threw (an
          # unknown option, a type error). Matching messages is what makes these
          # tests test the assertion: a tryEval on `drvPath` accepts any error,
          # so renaming an option would keep every case green.
          failedMessages =
            cfg:
            let
              messages = map (a: a.message) (builtins.filter (a: !a.assertion) cfg.config.assertions);
              result = builtins.tryEval (builtins.deepSeq messages messages);
            in
            if result.success then result.value else null;

          # Assertion messages are multi-line; collapse the formatting before
          # matching so a case does not depend on where the line breaks fall.
          normalize =
            message:
            lib.concatStringsSep " " (
              builtins.filter (word: word != "") (
                lib.splitString " " (builtins.replaceStrings [ "\n" "\t" ] [ " " " " ] message)
              )
            );

          # `expect = null` means "this configuration must raise no assertion".
          casePasses =
            { config, expect, ... }:
            let
              messages = failedMessages config;
            in
            if messages == null then
              false
            else if expect == null then
              messages == [ ]
            else
              lib.any (message: lib.hasInfix expect (normalize message)) messages;

          cases = [
            {
              name = "good sd-boot stack evaluates";
              config = goodSd;
              expect = null;
            }
            {
              name = "good nvme-boot stack evaluates";
              config = goodNvme;
              expect = null;
            }
            {
              name = "base alone has no boot medium";
              config = mkStackConfig [ self.nixosModules.base ] { };
              expect = "does not select a boot medium";
            }
            {
              name = "both boot media are rejected";
              config = mkStackConfig [
                self.nixosModules.sd-boot
                self.nixosModules.boot-nvme
              ] { };
              expect = "describe different /boot media";
            }
            {
              name = "SD device cannot be the NVMe device";
              config = mkStackConfig [ self.nixosModules.sd-boot ] {
                pi5.sdBoot.device = "/dev/nvme0n1";
              };
              expect = "must be different disks";
            }
            {
              name = "missing @nix is rejected while the root is reset";
              config = mkStackConfig [ self.nixosModules.sd-boot ] {
                pi5.nvme.subvolumes = {
                  "@root" = "/";
                  "@persist" = "/persist";
                  "@snapshots" = "/snapshots";
                };
              };
              expect = ''must map "@nix" to "/nix"'';
            }
            {
              name = "two subvolumes cannot mount at /";
              config = mkStackConfig [ self.nixosModules.sd-boot ] {
                pi5.nvme.subvolumes = {
                  "@root" = "/";
                  "@other" = "/";
                  "@nix" = "/nix";
                  "@persist" = "/persist";
                };
              };
              expect = "Exactly one pi5.nvme.subvolumes entry must mount at";
            }
            {
              name = "persist path must be a btrfs filesystem";
              config = mkStackConfig [ self.nixosModules.sd-boot ] {
                # A declared non-btrfs filesystem, so the case reaches the
                # assertion instead of throwing while nixpkgs computes the
                # initrd's supported filesystems.
                fileSystems."/not-btrfs" = {
                  device = "tmpfs";
                  fsType = "tmpfs";
                };
                pi5.impermanence.persistPath = "/not-btrfs";
              };
              expect = "must be a declared btrfs filesystem";
            }
            {
              name = "NVMe firmware and boot labels must differ";
              config = mkStackConfig [ self.nixosModules.nvme-boot ] {
                pi5.nvmeBoot.bootLabel = "FIRMWARE";
              };
              expect = "must differ";
            }
            {
              name = "NVMe boot needs patched U-Boot 2026.10";
              config = mkStackConfig [ self.nixosModules.nvme-boot ] {
                pi5.nvmeBoot.ubootPackage = nixpkgs.legacyPackages.aarch64-linux.ubootRaspberryPiAarch64;
              };
              expect = "requires U-Boot 2026.10";
            }
            {
              name = "enabled EEPROM configuration needs settings";
              config = mkStackConfig [ self.nixosModules.nvme-boot ] {
                pi5.eeprom.settings = lib.mkForce { };
              };
              expect = "pi5.eeprom.settings is empty";
            }
            {
              name = "EEPROM setting names are bootloader keys";
              config = mkStackConfig [ self.nixosModules.nvme-boot ] {
                pi5.eeprom.settings."boot_order" = "0xf416";
              };
              expect = "must be bootloader configuration names";
            }
            {
              name = "installer needs a root SSH key";
              config = self.lib.mkPi5Installer { };
              expect = "needs at least one root SSH key";
            }
          ];

          failedCases = builtins.filter (case: !(casePasses case)) cases;

          # Force the full closures, not just the assertions. The stacks above
          # cover the eval that the old example hosts used to cover.
          drvs = [
            installerConfig.config.system.build.toplevel
            installerConfig.config.system.build.sdImage
            goodSd.config.system.build.toplevel
            goodNvme.config.system.build.toplevel
          ];
        in
        {
          # Negative tests for the assertions that prevent data loss.
          assertions = pkgs.runCommand "assertions" { } (
            if failedCases == [ ] then
              "touch $out"
            else
              ''
                echo "pi5 assertion checks failed:" >&2
                ${lib.concatMapStringsSep "\n" (
                  case: "echo ${lib.escapeShellArg ("  - " + case.name)} >&2"
                ) failedCases}
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
                shellcheck modules/*.sh
                touch $out
              '';
        }
        // nixpkgs.lib.optionalAttrs (system == "aarch64-linux") {
          # The EEPROM derivation is built for aarch64-linux, so this check only
          # runs where that is the native system (the CI arm64 Linux runner).
          eeprom =
            pkgs.runCommand "eeprom-check"
              {
                nativeBuildInputs = [
                  pkgs.coreutils
                  pkgs.gnugrep
                ];
              }
              ''
                grep -qxF '[all]' ${goodNvme.config.pi5.eeprom.configFile}
                grep -qxF 'BOOT_ORDER=0xf416' ${goodNvme.config.pi5.eeprom.configFile}
                grep -qxF 'PCIE_PROBE=1' ${goodNvme.config.pi5.eeprom.configFile}
                touch $out
              '';

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
