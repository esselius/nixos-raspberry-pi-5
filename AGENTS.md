# Maintenance notes

This repo is the Raspberry Pi 5 + NVMe bring-up layer: boot chain, disko
layouts, impermanence. It holds no application workloads and no host
configurations; hosts live in the consuming flake. `README.md` explains the
design, the commands, and the mechanics. This file holds the invariants — the
things that break the repo if they change.

There is no imaging CLI. `README.md` "Quick start" is the source of truth for
build (`nix build .#images.<name>`), flash (`zstd -dc | dd`), and install
(`nixos-anywhere --disko-mode disko|mount`).

## Shape

- `base` (in `flake.nix`) is `hardware` + `storage` + `impermanence`, with no
  boot medium. `sd-boot` and `nvme-boot` are the two full stacks, named after
  the boot medium they choose. There is no default boot path. Snapper stays
  opt-in.
- The flake wrappers, not the module files, import `nixos-hardware`, `disko`,
  and `impermanence`, so consumers never pass `inputs` through `specialArgs`.
- `modules/lib/labels.nix` is the only definition of the partition labels and SD
  geometry; every module reads it.
- `pkgs/uboot-nvme/` holds the U-Boot derivation, its patches, and their
  provenance in one place.

## Invariants

- **The main `nixpkgs` pin stays put.** U-Boot comes from the `nixpkgs-uboot`
  input plus `pkgs/uboot-nvme/`. Newer `nixos-unstable` removed
  `boot.initrd.systemd.enable`, which `pi5.impermanence` uses. Drop the patches
  and the extra input when U-Boot ships them.
- **`/boot` stays ext4 (or FAT) and legacy-BIOS-bootable**, never on the btrfs
  root. The disko priorities (`firmware=100`, `boot=200`, `root=9001`) and the
  `boot_targets`-removal U-Boot shape were found empirically.
- **The vendor `linux-rpi` kernel stays.** Mainline plus the vendor DTBs broke
  RP1 (USB + Ethernet) with `-22`/EINVAL; test RP1 on hardware before changing
  it.
- **`system.nixos.variant_id = "installer"` stays** in the installer module: it
  is what makes `nixos-anywhere` skip flaky Pi 5 kexec. Root SSH with keys goes
  with it, because `nixos-anywhere` connects to installer targets as root. That
  pairing is also why the flake exports no installer image: a real one needs
  real keys.
- **The SD `preCreateHook` stays.** It refuses a partition table or `mkfs`
  unless the card is already the expected two-partition MBR layout with the
  `FIRMWARE`/`NIXOS_BOOT` labels, so a damaged card is reflashed instead of
  silently repartitioned.
- **The root-wipe service keeps** `RemainAfterExit`, `subvol=/`, a fail-closed
  `RequiredBy=sysroot.mount`, fixed-point nested-subvolume deletion, POSIX shell
  only (no awk, arrays, or process substitution), and no `neededForBoot` on
  `/boot` or `/boot/firmware`. Each of those was found empirically; see README
  "Root-wipe mechanics".
- **`NVME_BOOT` is the NVMe `/boot` label; `NIXOS_BOOT` is the installer SD's
  ext4 partition.** Sharing the label makes `by-label` lookups ambiguous with
  the installer SD inserted during recovery.

## Keep in sync

- `eeprom/boot.conf` and `eeprom/README.md` (`BOOT_ORDER=0xf416`,
  `PCIE_PROBE=1`) with the README's NVMe-only section. The EEPROM is not
  declarative.
- README "Hard-won details", the layouts, and the option tables with module
  changes.

## Before committing

```bash
nix fmt
nix flake check
```

`nix flake check` covers evaluation of an installer configuration and the two
stack configurations, the negative assertion cases (including "no boot medium"
and "both boot media"), formatting, shellcheck (including
`modules/root-wipe.sh`). It does not build the aarch64-linux SD image or the
NVMe-only system; use an aarch64-linux builder:

```bash
nix build .#images.<name>                     # in the consuming flake
nix build .#checks.aarch64-linux.uboot-nvme   # NVMe preboot present, boot_targets= absent
```
