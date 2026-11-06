# Raspberry Pi 5 EEPROM configuration for NVMe-first boot

The EEPROM settings are declarative: `pi5.eeprom` (`modules/eeprom.nix`) renders
them and a oneshot applies them when they drift from the running bootloader.
Set them on the host *and* on the installer image, because the installer is the
only system that runs before the NVMe can boot:

```nix
eeprom = {
  enable = true;
  settings = {
    BOOT_ORDER = "0xf416"; # NVMe -> SD -> USB -> restart
    PCIE_PROBE = 1;        # non-HAT+ M.2 adapters; harmless otherwise
  };
};
```

`nvme-boot` sets both settings and `enable = true` by default; the installer
needs them explicitly through `lib.mkPi5Installer`'s `eeprom` argument. See the
main README's "Quick start" and "`pi5.eeprom`" sections.

## What the settings do

`nvme-boot` defaults to the first two. The others were part of the 2026-10-30
bring-up and are available as `settings` keys:

| Setting | Why |
|---------|-----|
| `BOOT_ORDER=0xf416` | NVMe → SD → USB → restart. Keeps the installer SD as a recovery fallback; the shipped default (`0xf461`) prefers SD. |
| `PCIE_PROBE=1` | Needed for non-HAT+ M.2 adapters. HAT+ carriers auto-detect and do not need it; it is harmless if you are unsure. |
| `BOOT_UART=1` | Boot firmware messages on the debug UART (115200 8N1, `ttyAMA10` on the Pi 5). |
| `POWER_OFF_ON_HALT=0` | The shipped default; listed by the 2026-10-30 bring-up. |

`pi5.eeprom.package` also selects the bootloader version, because
`rpi-eeprom-config --apply` merges the settings into the newest image in the
package. The flake backports the `-2712` release because the main nixpkgs pin
still ships `-2711`, which has no Pi 5 images.

## Manual escape hatch

When the module is disabled, apply the same settings from the booted installer
or host:

```bash
cat >/tmp/boot.conf <<'EOF'
[all]
BOOT_ORDER=0xf416
PCIE_PROBE=1
EOF

sudo rpi-eeprom-config --apply /tmp/boot.conf
```

`pi5.eeprom.enable = true` puts `rpi-eeprom-config` on the system path (run it
with no arguments to print the running configuration). When the module is
disabled, build the flake's backported package and run the apply from it:

```bash
nix build .#packages.aarch64-linux.raspberrypi-eeprom
sudo result/bin/rpi-eeprom-config --apply /tmp/boot.conf
```

On a Pi 5 `rpi-eeprom-update` defaults to an immediate flashrom write, so the
new settings take effect on the next power cycle. A power cut during the write
leaves `recovery.bin` on the firmware partition, which the bootloader retries.

Applied on 2026-10-30 to a 4 GB board with a non-HAT+ adapter, bootloader
`2026-05-26` (`086b83e3`), which was already current. Record the board and
adapter here when you apply it elsewhere, because `PCIE_PROBE` depends on the
carrier, not on this repository.

Recovery: an invalid EEPROM config needs a bootloader-recovery SD card
(`recovery.bin`); a valid one always falls back to SD.
