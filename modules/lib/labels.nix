# Storage constants shared by the installer image, the SD boot description, and
# the NVMe layouts.
#
# This is a plain attribute set, not a NixOS module. It exists so the partition
# labels and the SD geometry are stated once instead of being restated as
# defaults in four modules and as prose in the README. Import it as
# `import ./lib/labels.nix` from `modules/`, or `import ../lib/labels.nix` from
# `modules/boot/`.
{
  # FAT firmware partition. The installer image, the SD card, and the NVMe-only
  # layout all use this label and this geometry. They are never mounted in the
  # same configuration, so one value covers all three.
  firmwareLabel = "FIRMWARE";
  firmwareSizeMiB = 256;
  firmwareStart = "8MiB";
  firmwareEnd = "264MiB";

  # ext4 boot partition on the installer SD card. `pi5.sdBoot` mounts that same
  # partition as /boot, so the image and the SD-boot host must agree on it.
  sdBootLabel = "NIXOS_BOOT";

  # ext4 /boot partition on the NVMe. Deliberately not NIXOS_BOOT: that label
  # already names the installer SD's ext4 partition, and an inserted installer
  # SD would make by-label lookups ambiguous during recovery.
  nvmeBootLabel = "NVME_BOOT";

  # btrfs root partition on the NVMe.
  nvmeRootLabel = "NVME_ROOT";
}
