{ config, lib, ... }:
let
  cfg = config.pi5.nvme;
  persistMount = lib.attrByPath [ "@persist" ] null cfg.subvolumes;

  subvolume = mountpoint: {
    inherit mountpoint;
    mountOptions = cfg.mountOptions;
  };
in
{
  options.pi5.nvme = {
    device = lib.mkOption {
      type = lib.types.str;
      default = "/dev/nvme0n1";
      description = ''
        Block device that holds the NixOS root. The whole disk is used; disko
        creates one GPT partition and a btrfs filesystem on it.

        A stable path such as `/dev/disk/by-id/nvme-...` is also accepted and
        is a good idea on a machine with more than one NVMe.
      '';
    };

    partitionLabel = lib.mkOption {
      type = lib.types.str;
      default = "NVME_ROOT";
      description = ''
        GPT partition label for the btrfs partition. The label (not the kernel
        device name) is what `pi5.impermanence` uses to find the filesystem in
        the initrd, before `/dev/nvme0n1` is guaranteed to exist.
      '';
    };

    mountOptions = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        "noatime"
        "compress=zstd"
        "nodiscard"
      ];
      description = ''
        Mount options applied to every btrfs subvolume. `nodiscard` is
        deliberate: `services.fstrim` batches discards instead of issuing one
        per freed block, which is much kinder to consumer NVMe.
      '';
    };

    subvolumes = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = {
        "@root" = "/";
        "@nix" = "/nix";
        "@persist" = "/persist";
        "@snapshots" = "/snapshots";
      };
      description = ''
        Btrfs subvolume name to mount point. `@root` is reset to an empty
        subvolume on every boot by `pi5.impermanence`; `@persist` is the only
        state that survives a reboot. Keep both if you use the default
        impermanence module. `@snapshots` is used by snapper when enabled.
      '';
    };
  };

  config = {
    disko.devices.disk.pi5-nvme = {
      type = "disk";
      device = cfg.device;
      content = {
        type = "gpt";
        partitions.nvme = {
          type = "8300";
          size = "100%";
          label = cfg.partitionLabel;
          content = {
            type = "btrfs";
            extraArgs = [ "-f" ];
            subvolumes = lib.mapAttrs (_name: subvolume) cfg.subvolumes;
          };
        };
      };
    };

    # Keep the NVMe healthy without adding write amplification at mount time.
    services.fstrim.enable = true;

    services.btrfs.autoScrub = lib.mkIf (persistMount != null) {
      enable = true;
      # @root is ephemeral and /nix is reproducible, so scrubbing the persisted
      # state is the useful check. Add mounts here if your trust model differs.
      fileSystems = [ persistMount ];
    };
  };
}
