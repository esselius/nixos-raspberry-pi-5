{
  config,
  lib,
  options,
  ...
}:
let
  cfg = config.pi5.impermanence;

  hasNvme = options.pi5 ? nvme;
  nvme = config.pi5.nvme or { };

  snapshotsMount =
    if !cfg.snapshots.enable then
      null
    else if cfg.snapshots.mountPath != null then
      cfg.snapshots.mountPath
    else if hasNvme then
      lib.attrByPath [ cfg.snapshots.subvolume ] null nvme.subvolumes
    else
      null;
in
{
  options.pi5.impermanence = {
    persistPath = lib.mkOption {
      type = lib.types.str;
      default = "/persist";
      description = ''
        Mount point of the persisted btrfs subvolume. Everything under
        `environment.persistence` survives the per-boot root reset; everything
        outside it does not.
      '';
    };

    rootDevice = lib.mkOption {
      type = lib.types.str;
      default =
        if hasNvme then
          "/dev/disk/by-partlabel/${nvme.partitionLabel}"
        else
          "/dev/disk/by-partlabel/NVME_ROOT";
      defaultText = lib.literalExpression ''
        "/dev/disk/by-partlabel/''${config.pi5.nvme.partitionLabel}"
      '';
      description = ''
        Device that holds the btrfs top level, used by the initrd root reset.
        Defaults to the partition label from `pi5.nvme`. Override this when
        using the impermanence module without the nvme-root module.
      '';
    };

    rootSubvolume = lib.mkOption {
      type = lib.types.strMatching "[A-Za-z0-9@._+-]+";
      default = "@root";
      description = ''
        Btrfs subvolume that backs `/`. It is deleted and recreated empty in
        the initrd on every boot. Spaces and slashes are not allowed: the
        initrd parser reads `btrfs subvolume list` output one line at a time.
      '';
    };

    resetRoot = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Reset the root subvolume on every boot. Disable this only if you
        deliberately want a mutable root and understand that `@root` will then
        accumulate state.
      '';
    };

    directories = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        "/var/lib/nixos"
        "/var/log"
      ];
      description = ''
        Directories persisted verbatim under {option}`pi5.impermanence.persistPath`.
        `/var/lib/nixos` holds UID/GID mappings and must survive, otherwise
        file ownership can drift after a reboot.

        Setting this option replaces the default list. Use
        {option}`pi5.impermanence.extraDirectories` to add service state
        without repeating the defaults; a forgotten entry fails silently by
        losing state on reboot.
      '';
    };

    extraDirectories = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [
        "/var/lib/incus"
        "/var/lib/unbound"
      ];
      description = ''
        Extra directories appended after {option}`pi5.impermanence.directories`.
        This is the intended way for a project module to add service state.
      '';
    };

    files = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        "/etc/machine-id"
        "/etc/ssh/ssh_host_ed25519_key"
        "/etc/ssh/ssh_host_ed25519_key.pub"
        "/etc/ssh/ssh_host_rsa_key"
        "/etc/ssh/ssh_host_rsa_key.pub"
      ];
      description = ''
        Individual files persisted verbatim under
        {option}`pi5.impermanence.persistPath`. The machine-id and SSH host
        keys must survive a root reset or every reboot presents a new identity.

        Setting this option replaces the default list. Use
        {option}`pi5.impermanence.extraFiles` to add files without repeating
        the defaults.
      '';
    };

    extraFiles = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = ''
        Extra files appended after {option}`pi5.impermanence.files`.
      '';
    };

    snapshots = {
      enable = lib.mkEnableOption ''
        snapper's nightly timeline snapshots of the persisted state.

        The `@root` subvolume is ephemeral, so snapshotting it is pointless;
        snapshots of `@persist` catch accidental changes and deletions that
        survive the reboot. The `snapshots.subvolume` mount must be declared
        in `pi5.nvme.subvolumes`, or `snapshots.mountPath` must be set
        explicitly.
      '';

      subvolume = lib.mkOption {
        type = lib.types.strMatching "[A-Za-z0-9@._+-]+";
        default = "@snapshots";
        description = ''
          Btrfs subvolume used as snapper's snapshot store for
          {option}`pi5.impermanence.persistPath`. It is bind-mounted at
          `<persistPath>/.snapshots`, the path snapper requires.
        '';
      };

      mountPath = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = ''
          Mount point of the snapshot subvolume. Defaults to the mount point
          declared for {option}`pi5.impermanence.snapshots.subvolume` in
          `pi5.nvme.subvolumes`. Set this explicitly when using the
          impermanence module without the nvme-root module.
        '';
      };

      timeline = {
        hourly = lib.mkOption {
          type = lib.types.ints.positive;
          default = 8;
          description = "Number of hourly snapshots to keep.";
        };
        daily = lib.mkOption {
          type = lib.types.ints.positive;
          default = 7;
          description = "Number of daily snapshots to keep.";
        };
        monthly = lib.mkOption {
          type = lib.types.ints.positive;
          default = 3;
          description = "Number of monthly snapshots to keep.";
        };
      };
    };
  };

  config = lib.mkMerge (
    [
      {
        # These two are needed before the impermanence bind mounts at boot.
        fileSystems."/".neededForBoot = true;

        environment.persistence.${cfg.persistPath} = {
          hideMounts = true;
          directories = cfg.directories ++ cfg.extraDirectories;
          files = cfg.files ++ cfg.extraFiles;
        };
      }

      # The disko layout owns the persist mount. Checking the nvme options (not
      # config.fileSystems) avoids a recursion: this definition itself contributes
      # to fileSystems. Standalone users with a non-disko persist filesystem
      # should set neededForBoot on it themselves.
      (lib.mkIf (hasNvme && lib.hasAttr "@persist" nvme.subvolumes) {
        fileSystems.${cfg.persistPath}.neededForBoot = true;
      })

      (lib.mkIf cfg.resetRoot {
        # Reset @root before systemd mounts it as the real root.
        #
        # Non-obvious requirements, learned the hard way on real hardware:
        #  * RemainAfterExit is required. Without it systemd starts this unit
        #    twice per boot; two concurrent mount/delete/create sequences against
        #    the same btrfs device hang the boot with no further output.
        #  * systemd auto-creates nested subvolumes under / on first boot
        #    (srv, var/lib/portables, var/lib/machines, tmp, var/tmp). They must
        #    be deleted before @root itself, or btrfs reports "Directory not
        #    empty".
        #  * The initrd shell has no awk and does not reliably support bash
        #    arrays or process substitution. Parse `btrfs subvolume list` with a
        #    POSIX while-read loop, exactly as below.
        #  * Do not mark /boot or /boot/firmware `neededForBoot`. U-Boot has
        #    already loaded the kernel and initrd before Linux starts; forcing
        #    initrd to probe SD/MMC concurrently with NVMe enumeration is a
        #    source of early-boot hangs.
        boot.initrd.systemd.services.root-wipe = {
          description = "Reset the btrfs root subvolume to a pristine empty state";
          wantedBy = [ "sysroot.mount" ];
          before = [ "sysroot.mount" ];
          unitConfig.DefaultDependencies = false;
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            TimeoutStartSec = "30s";
          };
          script = ''
            set -x
            for _ in $(seq 1 200); do
              [ -e ${lib.escapeShellArg cfg.rootDevice} ] && break
              sleep 0.05
            done
            udevadm settle --timeout=10 || true

            mkdir -p /btrfs_tmp
            mount -o nodiscard ${lib.escapeShellArg cfg.rootDevice} /btrfs_tmp

            target=${lib.escapeShellArg "/btrfs_tmp/${cfg.rootSubvolume}"}
            if [ -e "$target" ]; then
              btrfs property set "$target" ro false 2>/dev/null || true

              btrfs subvolume list -o "$target" > /btrfs_tmp/children.txt
              while read -r line; do
                subvolume="''${line##* }"
                btrfs property set "/btrfs_tmp/$subvolume" ro false 2>/dev/null || true
                btrfs subvolume delete "/btrfs_tmp/$subvolume"
              done < /btrfs_tmp/children.txt

              btrfs subvolume delete "$target"
            fi
            btrfs subvolume create "$target"

            umount /btrfs_tmp
            rmdir /btrfs_tmp
          '';
        };
      })

      (lib.mkIf (cfg.snapshots.enable && snapshotsMount != null) {
        services.snapper.configs.persist = {
          SUBVOLUME = cfg.persistPath;
          TIMELINE_CREATE = true;
          TIMELINE_CLEANUP = true;
          TIMELINE_LIMIT_HOURLY = toString cfg.snapshots.timeline.hourly;
          TIMELINE_LIMIT_DAILY = toString cfg.snapshots.timeline.daily;
          TIMELINE_LIMIT_MONTHLY = toString cfg.snapshots.timeline.monthly;
        };

        # snapper always stores snapshots in <SUBVOLUME>/.snapshots and requires
        # that path to be a subvolume. Bind the dedicated @snapshots subvolume
        # there so /snapshots can stay a clean top-level path and snapshots do
        # not nest inside @persist. Without this, snapper-timeline fails on a
        # fresh install with "open failed path:/persist/.snapshots".
        fileSystems."${cfg.persistPath}/.snapshots" = {
          device = snapshotsMount;
          fsType = "none";
          options = [
            "bind"
            "x-systemd.requires-mounts-for=${cfg.persistPath}"
            "x-systemd.requires-mounts-for=${snapshotsMount}"
          ];
        };
      })
    ]
    ++ [
      {
        assertions =
          lib.optional (options ? boot.initrd.systemd.enable) {
            assertion = config.boot.initrd.systemd.enable;
            message = ''
              pi5.impermanence resets the root subvolume from a systemd initrd unit;
              boot.initrd.systemd.enable must be true.
            '';
          }
          ++ lib.optionals hasNvme [
            {
              assertion = lib.hasAttr cfg.rootSubvolume nvme.subvolumes;
              message = ''
                pi5.impermanence.rootSubvolume "${cfg.rootSubvolume}" is not present
                in pi5.nvme.subvolumes.
              '';
            }
            {
              assertion = lib.attrByPath [ cfg.rootSubvolume ] null nvme.subvolumes == "/";
              message = ''
                pi5.nvme.subvolumes."${cfg.rootSubvolume}" must be mounted at "/";
                pi5.impermanence resets that subvolume and expects it to be the root.
              '';
            }
            {
              assertion =
                !(lib.hasAttr "@persist" nvme.subvolumes) || nvme.subvolumes."@persist" == cfg.persistPath;
              message = ''
                pi5.nvme.subvolumes."@persist" must equal pi5.impermanence.persistPath
                ("${cfg.persistPath}"), or be removed if you manage persistence
                elsewhere.
              '';
            }
          ]
          ++ lib.optional cfg.snapshots.enable {
            assertion = snapshotsMount != null;
            message = ''
              pi5.impermanence.snapshots is enabled but pi5.nvme.subvolumes has no
              "${cfg.snapshots.subvolume}" entry. Add the subvolume, set
              pi5.impermanence.snapshots.mountPath, or disable snapshots.
            '';
          };
      }
    ]
  );
}
