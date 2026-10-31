{
  config,
  lib,
  options,
  ...
}:
let
  cfg = config.pi5.nvmeBoot;
  labels = import ../lib/labels.nix;

  hasNvme = options.pi5 ? nvme;
  hasFirmware = lib.hasAttrByPath [ "hardware" "raspberry-pi" "firmware" "uboot" ] options;

  # The btrfs root subvolume mount options belong to pi5.nvme (storage.nix).
  subvolume = mountpoint: {
    inherit mountpoint;
    mountOptions = config.pi5.nvme.mountOptions;
  };
in
{
  options.pi5.nvmeBoot = {
    ubootPackage = lib.mkOption {
      type = lib.types.package;
      description = ''
        U-Boot package with Raspberry Pi 5 NVMe support. This must be U-Boot
        2026.10 or newer, built with the DMA-ranges parent-walk fix and NVMe
        enabled in `rpi_arm64_defconfig`.

        The flake's `nixosModules.nvme-boot` wrapper sets this to the patched
        build from the `nixpkgs-uboot` input. Set it explicitly when importing
        `modules/boot/nvme.nix` directly.
      '';
    };

    firmwareSize = lib.mkOption {
      type = lib.types.ints.positive;
      default = 256;
      description = ''
        Size of the FAT firmware partition on the NVMe, in MiB. It holds the GPU
        boot code, device trees, `config.txt`, and `u-boot.bin`.
      '';
    };

    bootSize = lib.mkOption {
      type = lib.types.str;
      default = "2G";
      description = ''
        Size of the ext4 `/boot` partition on the NVMe. It holds
        `extlinux.conf`, the kernel, and one initrd per generation. Keep it
        large enough for {option}`pi5.nvmeBoot.configurationLimit` generations.
      '';
    };

    firmwareLabel = lib.mkOption {
      type = lib.types.str;
      default = labels.firmwareLabel;
      description = "GPT partition label and FAT filesystem label of the firmware partition.";
    };

    bootLabel = lib.mkOption {
      type = lib.types.str;
      default = labels.nvmeBootLabel;
      description = "GPT partition label and ext4 filesystem label of the `/boot` partition.";
    };

    configurationLimit = lib.mkOption {
      type = lib.types.ints.positive;
      default = 8;
      description = ''
        Number of extlinux generations kept on the NVMe `/boot` partition. This
        is applied to `boot.loader.generic-extlinux-compatible.configurationLimit`.
      '';
    };
  };

  config = lib.mkMerge [
    {
      boot.loader.generic-extlinux-compatible = {
        enable = lib.mkDefault true;
        configurationLimit = lib.mkDefault cfg.configurationLimit;
      };
    }

    (lib.mkIf (hasNvme && hasFirmware && !(options.pi5 ? sdBoot)) {
      # Replace the storage module's single btrfs partition with the NVMe-only
      # boot layout:
      #
      #   p1 256 MiB FAT32 FIRMWARE   -> /boot/firmware (GPU firmware + U-Boot)
      #   p2 2 GiB   ext4  NVME_BOOT  -> /boot (extlinux + kernel + initrd)
      #   p3 rest    btrfs NVME_ROOT  -> / and subvolumes
      #
      # No SD card is described here. The bootstrap image is only the installer
      # medium; after the install the SD can be removed.
      disko.devices.disk.pi5-nvme.content = lib.mkForce {
        type = "gpt";
        partitions = {
          firmware = {
            type = "EF00";
            start = "8M";
            size = "${toString cfg.firmwareSize}M";
            # Create the firmware partition before /boot. /boot uses "next
            # available" and would otherwise swallow the 8M..264M range.
            priority = 100;
            label = cfg.firmwareLabel;
            content = {
              type = "filesystem";
              format = "vfat";
              mountpoint = "/boot/firmware";
              extraArgs = [
                "-n"
                cfg.firmwareLabel
              ];
            };
          };

          boot = {
            type = "8300";
            size = cfg.bootSize;
            priority = 200;
            label = cfg.bootLabel;
            # GPT attribute bit 2: Legacy BIOS Bootable. U-Boot's extlinux
            # bootflow expects a bootable partition.
            attributes = [ 2 ];
            content = {
              type = "filesystem";
              format = "ext4";
              mountpoint = "/boot";
              extraArgs = [
                "-L"
                cfg.bootLabel
              ];
              mountOptions = [ "noatime" ];
            };
          };

          root = {
            type = "8300";
            size = "100%";
            priority = 9001;
            label = config.pi5.nvme.partitionLabel;
            content = {
              type = "btrfs";
              extraArgs = [ "-f" ];
              subvolumes = lib.mapAttrs (_name: subvolume) config.pi5.nvme.subvolumes;
            };
          };
        };
      };

      hardware.raspberry-pi.firmware = {
        enable = lib.mkDefault true;
        path = lib.mkDefault "/boot/firmware";
        uboot = {
          enable = lib.mkDefault true;
          package = lib.mkDefault cfg.ubootPackage;
        };
      };
    })

    {
      assertions = [
        {
          assertion = hasNvme;
          message = ''
            pi5.nvmeBoot needs the NVMe layout options from pi5.nvme.
            Import nixosModules.storage (or use the nixosModules.nvme-boot
            stack) before nixosModules.boot-nvme.
          '';
        }
        {
          assertion = hasFirmware;
          message = ''
            pi5.nvmeBoot needs the Raspberry Pi firmware options. Import
            nixosModules.hardware (or use the nixosModules.nvme-boot stack)
            before nixosModules.boot-nvme.
          '';
        }
        {
          assertion = !(options.pi5 ? sdBoot);
          message = ''
            pi5.sdBoot and pi5.nvmeBoot describe different /boot media and
            both claim /boot and /boot/firmware. Choose exactly one boot
            module: nixosModules.boot-sd or nixosModules.boot-nvme.
          '';
        }
        {
          assertion = lib.versionAtLeast cfg.ubootPackage.version "2026.10";
          message = ''
            pi5.nvmeBoot requires U-Boot 2026.10 or newer: 2026.07 lacks the
            NVMe inbound address-translation fix, and its rpi_arm64_defconfig
            has no NVMe support. Use the flake's nixosModules.nvme-boot
            wrapper, or set pi5.nvmeBoot.ubootPackage to a patched 2026.10+
            build.
          '';
        }
        {
          assertion = cfg.firmwareLabel != cfg.bootLabel;
          message = ''
            pi5.nvmeBoot.firmwareLabel and pi5.nvmeBoot.bootLabel must differ;
            duplicate GPT partition labels make by-partlabel lookups ambiguous.
          '';
        }
      ]
      ++ lib.optional (lib.hasAttrByPath [ "hardware" "raspberry-pi" "firmware" "path" ] options) {
        assertion = config.hardware.raspberry-pi.firmware.path == "/boot/firmware";
        message = ''
          pi5.nvmeBoot mounts the NVMe FAT partition at /boot/firmware, matching
          the stock Raspberry Pi layout. The firmware activation path must
          match, or U-Boot will be staged somewhere the GPU does not read.
        '';
      };
    }
  ];
}
