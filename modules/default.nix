{ ... }:
{
  # The opinionated, ready-to-run stack. Import this when you want the same
  # layout the reference hosts run: vendor-kernel Raspberry Pi 5 support, an
  # ephemeral btrfs root on NVMe, the SD card carrying the bootloader, and
  # impermanence.
  #
  # Snapper is deliberately not enabled here: snapshots are a site policy, not
  # a hardware requirement. Set pi5.impermanence.snapshots.enable = true in the
  # host/project layer if you want them.
  imports = [
    ./raspberry-pi-5.nix
    ./nvme-root.nix
    ./sd-boot.nix
    ./impermanence.nix
  ];
}
