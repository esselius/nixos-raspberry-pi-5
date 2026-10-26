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

    firmwareLabel = lib.mkOption {
      type = lib.types.str;
      default = "FIRMWARE";
      description = ''
        Filesystem label of the FAT firmware partition. Must match the label
        produced by the bootstrap image (`sdImage.firmwarePartitionName`,
        which defaults to `FIRMWARE`).
      '';
    };

    rootLabel = lib.mkOption {
      type = lib.types.str;
      default = "NIXOS_BOOT";
      description = ''
        Filesystem label of the ext4 `/boot` partition. Must match
        {option}`pi5.installer.rootVolumeLabel`.
      '';
    };
  };

  config = lib.mkMerge [
    {
      disko.devices.disk.pi5-sd = {
        type = "disk";
        device = cfg.device;

        # This disk is described so disko (and therefore nixos-anywhere) can
        # mount the existing SD partitions, and so the bootloader install step
        # has /boot and /boot/firmware mounted in the same run.
        #
        # Hard resets run disko's create stage for every declared disk. The
        # preCreateHook below turns that into a no-op for a valid installer SD:
        # it refuses to create a partition table or filesystem on anything that
        # does not already look like the bootstrap image. A damaged or blank SD
        # must be reflashed, not silently re-partitioned.
        destroy = false;

        preCreateHook = ''
          dev=${lib.escapeShellArg cfg.device}
          ptype=$(lsblk -dno PTTYPE "$dev" 2>/dev/null || true)
          case "$ptype" in
            dos | msdos) ;;
            *)
              echo "pi5.sdBoot: $dev is not an existing MBR (dos) SD card; reflash the installer image instead of creating a partition table" >&2
              exit 1
              ;;
          esac
          # disko's table _create uses this exact probe to decide whether to
          # run `parted mklabel`. If it would fail, disko would repartition the
          # card; refuse before that happens.
          if ! blkid "$dev" >/dev/null 2>&1; then
            echo "pi5.sdBoot: blkid does not recognize $dev; refusing to let disko repartition it; reflash the installer image" >&2
            exit 1
          fi

          count=0
          p1=
          p2=
          for part in $(lsblk -ln -o PATH "$dev"); do
            count=$((count + 1))
            case "$count" in
              1) ;;
              2) p1=$part ;;
              3) p2=$part ;;
            esac
          done
          if [ "$count" -ne 3 ] || [ -z "$p1" ] || [ -z "$p2" ]; then
            echo "pi5.sdBoot: $dev must have exactly two partitions (firmware + boot); reflash the installer image" >&2
            exit 1
          fi

          p1_type=$(blkid -s TYPE -o value "$p1" 2>/dev/null || true)
          p2_type=$(blkid -s TYPE -o value "$p2" 2>/dev/null || true)
          p1_label=$(blkid -s LABEL -o value "$p1" 2>/dev/null || true)
          p2_label=$(blkid -s LABEL -o value "$p2" 2>/dev/null || true)
          if [ "$p1_type" != "vfat" ] || [ "$p1_label" != ${lib.escapeShellArg cfg.firmwareLabel} ]; then
            echo "pi5.sdBoot: $p1 must be vfat labelled ${cfg.firmwareLabel}; reflash the installer image" >&2
            exit 1
          fi
          if [ "$p2_type" != "ext4" ] || [ "$p2_label" != ${lib.escapeShellArg cfg.rootLabel} ]; then
            echo "pi5.sdBoot: $p2 must be ext4 labelled ${cfg.rootLabel}; reflash the installer image" >&2
            exit 1
          fi
        '';

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
              # Match the stock sd-image layout: 8 MiB gap, 256 MiB firmware.
              start = "8MiB";
              end = "264MiB";
              content = {
                type = "filesystem";
                format = "vfat";
                # Mount by label so a changed device enumeration cannot pick the
                # wrong partition.
                device = "/dev/disk/by-label/${cfg.firmwareLabel}";
                mountpoint = "/boot/firmware";
                mountOptions = [ "nofail" ];
              };
            }
            {
              name = "nixos_boot";
              fs-type = "ext4";
              start = "264MiB";
              end = "100%";
              bootable = true;
              content = {
                type = "filesystem";
                format = "ext4";
                device = "/dev/disk/by-label/${cfg.rootLabel}";
                mountpoint = "/boot";
                mountOptions = [ "noatime" ];
              };
            }
          ];
        };
      };
    }

    {
      assertions =
        lib.optionals (options.pi5 ? nvme) [
          {
            assertion = cfg.device != config.pi5.nvme.device;
            message = ''
              pi5.sdBoot.device and pi5.nvme.device must be different disks;
              disko otherwise has two definitions for the same device.
            '';
          }
        ]
        ++ lib.optionals (lib.hasAttrByPath [ "hardware" "raspberry-pi" "firmware" "path" ] options) [
          {
            assertion = config.hardware.raspberry-pi.firmware.path == "/boot/firmware";
            message = ''
              pi5.sdBoot expects the firmware at /boot/firmware (the stock
              sd-image layout). The firmware activation path must match.
            '';
          }
        ];
    }
  ];
}
