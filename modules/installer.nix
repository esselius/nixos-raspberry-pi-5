{
  config,
  lib,
  modulesPath,
  pkgs,
  ...
}:
let
  cfg = config.pi5.installer;
in
{
  imports = [
    # Import by module path so the sd-image module comes from the consumer's
    # own nixpkgs, not from this flake's locked nixpkgs.
    (modulesPath + "/installer/sd-card/sd-image-aarch64.nix")
  ];

  options.pi5.installer = {
    hostName = lib.mkOption {
      type = lib.types.str;
      default = "pi5-bootstrap";
      description = "Hostname of the throwaway installer image.";
    };

    sshAuthorizedKeys = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = ''
        SSH public keys authorized for root and the admin user. nixos-anywhere
        requires root SSH on installer-variant targets: it copies the invoking
        user's authorized_keys to /root and then connects as root. An image
        without a key is unreachable, so evaluation fails if the effective
        root key list is empty.
      '';
    };

    adminUser = lib.mkOption {
      type = lib.types.str;
      default = "admin";
      description = "Unprivileged user with passwordless sudo and SSH access.";
    };

    consoleAutologin = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Log the admin user in automatically on the local console.";
    };

    permitRootLogin = lib.mkOption {
      type = lib.types.str;
      default = "prohibit-password";
      description = ''
        sshd PermitRootLogin setting. Keep this at "prohibit-password":
        nixos-anywhere hardcodes root SSH access for targets whose
        system.nixos.variant_id is "installer".
      '';
    };

    firmwareSize = lib.mkOption {
      type = lib.types.ints.positive;
      default = 256;
      description = "Size of the FAT firmware partition, in MiB.";
    };

    rootVolumeLabel = lib.mkOption {
      type = lib.types.str;
      default = "NIXOS_BOOT";
      description = ''
        Filesystem label of the ext4 boot/root partition on the SD card. The
        sd-boot module does not depend on the label (it mounts the partitions
        by layout), but U-Boot's extlinux lookup uses this partition.
      '';
    };

    rootFilesystemSize = lib.mkOption {
      type = lib.types.str;
      default = "4G";
      description = ''
        Minimum ext4 root filesystem size on the SD card. The image is built
        from a minimal sd-image root, which is too small to hold the target
        closure during nixos-anywhere; resizing it up front avoids install
        failures.
      '';
    };

    extraPackages = lib.mkOption {
      type = lib.types.listOf lib.types.package;
      default = [ ];
      description = "Extra packages available in the installer environment.";
    };
  };

  config = {
    assertions = [
      {
        assertion = config.users.users.root.openssh.authorizedKeys.keys != [ ];
        message = ''
          pi5.installer needs at least one root SSH key (pi5.installer.sshAuthorizedKeys
          or users.users.root.openssh.authorizedKeys.keys). nixos-anywhere
          connects to installer images as root.
        '';
      }
    ];

    # nixos-anywhere's runKexec() early-returns for installer variants. That is
    # intentional on the Pi 5: kexec is flaky there, and an SD-image boot is
    # the supported path.
    system.nixos.variant_id = lib.mkDefault "installer";

    networking.hostName = cfg.hostName;

    sdImage = {
      firmwareSize = cfg.firmwareSize;
      rootVolumeLabel = cfg.rootVolumeLabel;
      preBuildCommands = lib.mkDefault ''
        chmod u+w "$root_fs" || true
        resize2fs "$root_fs" ${cfg.rootFilesystemSize}
      '';
    };

    # sd-image-aarch64 imports nixos/profiles/base.nix, which enables ZFS.
    # zfs-kernel needs the kernel's `dev` output; that is not in the binary
    # caches, so leaving it on forces a full linux-rpi build for every image.
    # The installer only ever mounts btrfs, ext4, and the FAT ESP.
    boot.supportedFilesystems.zfs = false;

    services.openssh = {
      enable = true;
      settings = {
        PasswordAuthentication = false;
        KbdInteractiveAuthentication = false;
        PermitRootLogin = cfg.permitRootLogin;
      };
    };

    security.sudo.wheelNeedsPassword = false;
    users.mutableUsers = false;

    users.users.root.openssh.authorizedKeys.keys = cfg.sshAuthorizedKeys;

    users.users.${cfg.adminUser} = {
      isNormalUser = lib.mkDefault true;
      description = lib.mkDefault "NixOS installer admin";
      extraGroups = [ "wheel" ];
      openssh.authorizedKeys.keys = cfg.sshAuthorizedKeys;
    };

    services.getty.autologinUser = lib.mkIf cfg.consoleAutologin cfg.adminUser;

    nix.settings = {
      experimental-features = [
        "nix-command"
        "flakes"
      ];
      trusted-users = [ "@wheel" ];
    };

    environment.systemPackages = [ pkgs.vim ] ++ cfg.extraPackages;
  };
}
