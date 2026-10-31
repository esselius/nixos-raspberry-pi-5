# NVMe-only boot example

This directory accompanies the `pi5.nvmeBoot` module. The SD card is only the
installer medium; after `nixos-anywhere` finishes, remove it and the board boots
from NVMe.

## Boot order

The Pi 5 EEPROM is not managed by NixOS, so apply this once from the installer
(or any running NixOS on the board):

```bash
sudo rpi-eeprom-config --apply boot.conf
```

`boot.conf` sets:

```ini
[all]
BOOT_UART=1
POWER_OFF_ON_HALT=0
BOOT_ORDER=0xf416
PCIE_PROBE=1
```

- `BOOT_ORDER=0xf416`: NVMe → SD → USB → restart. This keeps the SD installer as
  a recovery fallback. Use `0xf46` (NVMe → USB → restart) only if you are sure
  you never want the SD fallback.
- `PCIE_PROBE=1`: required for non-HAT+ M.2 adapters. Remove it for an official
  M.2 HAT+.
- `BOOT_UART=1`: firmware output on the debug UART. Keep it while bringing a
  board up.

The matching host setting is:

```nix
hardware.raspberry-pi.configtxt.settings.pi5.dtparam = [ "pciex1" ];
```

Remove that line for a HAT+ carrier whose EEPROM already describes the PCIe
link.

## Install

Build and flash the normal bootstrap SD image, boot it, then install the
NVMe-only host in wipe mode:

```bash
nix run .#pi5-image -- eeprom --eeprom-config examples/nvme-boot/boot.conf root@<installer-ip>
nix run .#pi5-image -- install --flake . --host pi5-nvme-example --mode wipe root@<installer-ip>
```

`provision` can do the EEPROM step in the same run:

```bash
nix run .#pi5-image -- provision \
  --flake . --installer pi5-bootstrap --host pi5-nvme-example \
  --eeprom-config examples/nvme-boot/boot.conf \
  /dev/rdiskN root@<installer-ip>
```

After the install, power off, remove the SD card, and power on. The firmware
should report `Boot mode: NVME (06)`; U-Boot then boots
`nvme#0.blk#1.bootdev.part_2` with extlinux.

## Layout

| Partition | Size | FS | Label | Mount |
|---|---|---|---|---|
| p1 | 256 MiB | FAT32 | `FIRMWARE` | `/boot/firmware` |
| p2 | 2 GiB | ext4 | `NIXOS_BOOT` | `/boot` |
| p3 | rest | btrfs | `NVME_ROOT` | `/` + subvolumes |

The sizes are `pi5.nvmeBoot.firmwareSize` and `pi5.nvmeBoot.bootSize`.

## Recovery

- Keep the SD installer around. With `BOOT_ORDER=0xf416`, insert it and power on;
  U-Boot's standard boot order scans MMC before NVMe, so the installer boots.
- If the NVMe firmware partition is damaged, the EEPROM falls back to SD/USB.
- `nixos-anywhere --mode mount` is not useful for a first install on a blank
  NVMe; use `--mode wipe`.

## Caveats

- The NVMe-only path needs U-Boot 2026.10 plus patches that are not upstream
  yet. The flake pins a separate `nixpkgs-uboot` input for this; do not bump the
  main nixpkgs pin to get it (newer unstable removed
  `boot.initrd.systemd.enable`).
- The 2026-10-30 hardware proof used the vendor `linux-rpi` kernel and had
  `pi5.impermanence.resetRoot = false`. Re-enable the root wipe deliberately and
  verify that `/boot`, `/nix`, and `/persist` survive.
- The proof was on a 4 GB board with a non-HAT+ adapter and a BIWIN
  512 GB NVMe. The 8 GB production board has not been migrated.
