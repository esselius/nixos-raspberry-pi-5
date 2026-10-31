# Example NVMe-only host. The SD card is only used to boot the installer.
#
# The boot chain is:
#   EEPROM -> firmware + U-Boot on NVMe p1 -> extlinux on NVMe p2 -> btrfs root
#
# See ../../README.md ("NVMe-only boot") and the sibling README.md for the
# EEPROM configuration and the hardware bring-up caveats.
{
  networking.hostName = "pi5-nvme-example";
  system.stateVersion = "26.05";

  # Non-HAT+ M.2 adapters need the PCIe controller enabled in the base DTB.
  # The matching EEPROM setting is PCIE_PROBE=1. Remove both for an official
  # M.2 HAT+.
  hardware.raspberry-pi.configtxt.settings.pi5.dtparam = [ "pciex1" ];

  # The Pi 5 debug UART is ttyAMA10, not ttyAMA0. Keeping the console here
  # makes boot failures visible over the Debug Probe.
  boot.kernelParams = [ "console=ttyAMA10,115200n8" ];

  # Minimal remote access for the example. On an impermanent system, users are
  # declarative and /etc/passwd is rebuilt at boot; mutableUsers = false keeps
  # runtime useradd/passwd changes from appearing to work until the next boot.
  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
      PermitRootLogin = "no";
    };
  };

  security.sudo.wheelNeedsPassword = false;
  users.mutableUsers = false;

  users.users.admin = {
    isNormalUser = true;
    description = "admin";
    extraGroups = [ "wheel" ];
    openssh.authorizedKeys.keys = [
      # Test-only key; the private half was discarded, so this example host is
      # intentionally unreachable. Replace it with your own public key.
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPVIgmsKXn3UwSmCQ7r0GnIKQ9rxh14VzYm4gtUHhaWi pi5-demo-test-only-no-private-key-retained"
    ];
  };

  # The 2026-10-30 NVMe-only hardware proof ran with the per-boot @root reset
  # disabled. The root wipe only touches the btrfs partition, so it should be
  # independent of where /boot lives, but that combination has not been
  # verified on hardware yet. Flip this to true after a first bring-up and
  # confirm that /boot, /nix, and /persist survive a reboot.
  pi5.impermanence.resetRoot = false;
}
