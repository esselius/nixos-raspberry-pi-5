# Raspberry Pi 5 EEPROM configuration for NVMe-first boot

The Pi 5 bootloader is not declarative: there is no NixOS option for it, and
`rpi-eeprom-update` keeps the existing config. Apply this file once per board:

```bash
sudo rpi-eeprom-config --apply boot.conf
```

Remotely, from the workstation that can reach the installer:

```bash
scp eeprom/boot.conf root@<installer-ip>:/tmp/boot.conf
ssh root@<installer-ip> 'sudo rpi-eeprom-config --apply /tmp/boot.conf'
```

```ini
[all]
BOOT_UART=1
POWER_OFF_ON_HALT=0
BOOT_ORDER=0xf416
PCIE_PROBE=1
```

| Setting | Why |
|---------|-----|
| `BOOT_ORDER=0xf416` | NVMe → SD → USB → restart. Keeps the installer SD as a recovery fallback; the shipped default (`0xf461`) prefers SD. |
| `PCIE_PROBE=1` | Needed for non-HAT+ M.2 adapters. HAT+ carriers auto-detect and do not need it; it is harmless if you are unsure. |
| `BOOT_UART=1` | Boot firmware messages on the debug UART (115200 8N1, `ttyAMA10` on the Pi 5). |

Applied on 2026-10-30 to a 4 GB board with a non-HAT+ adapter, bootloader
`2026-05-26` (`086b83e3`), which was already current. Record the board and
adapter here when you apply it elsewhere, because `PCIE_PROBE` depends on the
carrier, not on this repository.

Recovery: an invalid EEPROM config needs a bootloader-recovery SD card
(`recovery.bin`); a valid one always falls back to SD.
