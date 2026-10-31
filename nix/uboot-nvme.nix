# U-Boot with the Raspberry Pi 5 NVMe support that shipped after 2026.07.
#
# Build this from a newer nixpkgs than the flake's main pin (see
# `nixpkgs-uboot` in flake.nix). U-Boot 2026.07 lacks the NVMe inbound
# address-translation fix, and its rpi_arm64_defconfig still has no NVMe
# config. The patches are documented in ./patches/uboot/README.md.
{ ubootRaspberryPiAarch64 }:
ubootRaspberryPiAarch64.override {
  extraPatches = [
    ./patches/uboot/torsten/0001-core-skip-parent-device-nodes.patch
    ./patches/uboot/torsten/0002-test-dma-ranges-ut.patch
    ./patches/uboot/torsten/0003-configs-enable-nvme.patch
    ./patches/uboot/0003-rpi-env-drop-boot-targets.patch
  ];
}
