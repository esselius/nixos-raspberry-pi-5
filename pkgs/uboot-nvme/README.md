# U-Boot Raspberry Pi 5 NVMe patches

`default.nix` builds U-Boot 2026.10 from the `nixpkgs-uboot` pin with the
patches in this directory. `torsten/` is Torsten Duwe's upstream series; the
file at the top level is a local follow-up. Provenance for each is below.

These patches enable NVMe boot on the Raspberry Pi 5 with U-Boot 2026.10. They
are a temporary bridge until the fixes reach the U-Boot release used by the
pinned nixpkgs. Do not present them as original work.

Provenance, as of 2026-10-31:

- `torsten/0001-core-skip-parent-device-nodes.patch` — Torsten Duwe's
  `[PATCH 1/8] core: skip parent device nodes without a DT reference when
  looking for dma-ranges` from “Almost complete Raspberry Pi 5 support”
  (Patchwork series 525225, 2026-09-25). The approach carries
  `Suggested-by: Neil Armstrong`. The patch is marked accepted on Patchwork but
  is not in U-Boot `master`, `next`, or `v2027.01-rc1` as of 2026-10-30.
- `torsten/0002-test-dma-ranges-ut.patch` — the sandbox test from the same
  series (patch 2/8).
- `torsten/0003-configs-enable-nvme.patch` — `rpi_arm64_defconfig` changes from
  the same series (patch 3/8): `CONFIG_NVME_PCI=y` and `nvme scan` in
  `CONFIG_PREBOOT`.
- `0003-rpi-env-drop-boot-targets.patch` — follow-up by Peter Esselius:
  delete `boot_targets` from `board/raspberrypi/rpi/rpi.env` so bootstd uses
  its standard bootdev priority order. This is the v2 shape suggested by Simon
  Glass on the U-Boot list.

The exact four-patch build was tested on a Raspberry Pi 5 (4 GB) with the SD
card removed:

- EEPROM `BOOT_ORDER=0xf416`, `PCIE_PROBE=1`
- firmware loaded U-Boot 2026.10 from the NVMe FAT partition
- U-Boot booted `nvme#0.blk#1.bootdev.part_2` with extlinux
- root on the NVMe btrfs partition, no failed units
- with the installer SD inserted, U-Boot still booted the SD first (recovery)

The source of that test is the `2026-10-30-rpi5-bootloader` repository. When
U-Boot ships the DMA-ranges fix and enables NVMe in `rpi_arm64_defconfig`,
delete these patches and the `nixpkgs-uboot` input, then remove the
`pi5.nvmeBoot.ubootPackage` default from the flake wrapper.
