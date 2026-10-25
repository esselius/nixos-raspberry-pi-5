{
  config,
  lib,
  options,
  ...
}:
let
  cfg = config.pi5.sdBoot;
in
{
  options.pi5.sdBoot = {
    device = lib.mkOption {
      type = lib.types.str;
      default = "/dev/mmcblk0";
      description = ''
        microSD card device. The Pi 5's built-in slot is `mmcblk0` on Linux.
      '';
    };

    bootMount = lib.mkOption {
      type = lib.types.str;
      default = "/boot";
      description = ''
        Mount point of the ext4 partition that holds extlinux.conf, kernels,
        and initrds. This is the partition U-Boot reads.

        NixOS' generic-extlinux-compatible bootloader expects `/boot`; change
        this only if you also move the bootloader's mount point.
      '';
    };

    firmwareMount = lib.mkOption {
      type = lib.types.str;
      default = "/boot/firmware";
      description = ''
        Mount point of the FAT firmware partition (GPU boot code, DTBs,
        overlays, config.txt, u-boot.bin). Matches the layout produced by
        nixpkgs' sd-image-aarch64.nix.
      '';
    };
  };

  config = lib.mkMerge [
    {
      disko.devices.disk.pi5-sd = {
        type = "disk";
        device = cfg.device;

        # This disk is declared so disko (and therefore nixos-anywhere) can mount
        # the existing SD partitions during a soft reset, and so the bootloader
        # install step has /boot and /boot/firmware mounted in the same run.
        #
        # Do not rely on the create stage to preserve it. disko's default and
        # format modes run the nested filesystem `_create` steps, which may mkfs
        # the partitions (the current disko probes blkid first, but that is an
        # implementation detail), and `destroy = false` only excludes this disk
        # from the destroy stage. Use `--disko-mode mount` for soft resets. A
        # deliberate hard reset may touch or rewrite the SD; it is a disposable
        # installer medium, so reflash it if the install is interrupted.
        destroy = false;

        content = {
          # The SD card is MBR/msdos, not GPT. disko's newer `gpt` type addresses
          # partitions by GPT partlabel and cannot describe it, so this necessarily
          # uses the legacy `table` type. Evaluating the flake prints disko's
          # "legacy table is outdated" warning; it is harmless in mount mode and
          # there is currently no way to silence it (nix-community/disko#812).
          type = "table";
          format = "msdos";
          partitions = [
            {
              name = "firmware";
              fs-type = "fat32";
              content = {
                type = "filesystem";
                format = "vfat";
                mountpoint = cfg.firmwareMount;
                mountOptions = [ "nofail" ];
              };
            }
            {
              name = "nixos_boot";
              fs-type = "ext4";
              content = {
                type = "filesystem";
                format = "ext4";
                mountpoint = cfg.bootMount;
                mountOptions = [ "noatime" ];
              };
            }
          ];
        };
      };
    }
    (lib.mkIf (lib.hasAttrByPath [ "hardware" "raspberry-pi" "firmware" "path" ] options) {
      hardware.raspberry-pi.firmware.path = lib.mkDefault cfg.firmwareMount;
    })
  ];
}
