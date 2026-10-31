# Maintenance notes

This repo is the Raspberry Pi 5 + NVMe bring-up layer: boot chain, disko
layouts, impermanence, and the imaging CLI. It deliberately contains no
application workloads and no host configurations; hosts live in the consuming
flake. `README.md` explains the design and the mechanics — this file lists only
the things that break the repo if you change them.

## Shape

- `modules/base.nix` is the stack without a boot medium. `sd-boot` and
  `nvme-boot` are the two full stacks and are named after the boot medium they
  choose. There is no default boot path. Snapper stays opt-in (site policy).
- The flake wrappers — not the module files — import `nixos-hardware`, `disko`,
  and `impermanence`. Keep it that way so consumers never pass `inputs` through
  `specialArgs`.
- `modules/lib/labels.nix` is the single definition of the partition labels and
  SD geometry. The installer image and the hosts read it; do not reintroduce a
  literal label or geometry value in a module.
- `scripts/pi5-image.sh` is orchestration only. Disk layout, boot chain, and
  persistence stay declarative in `modules/`.

## Do not

- **Bump the main `nixpkgs` pin to get a newer U-Boot.** The NVMe-only path needs
  U-Boot 2026.10+, built from the separate `nixpkgs-uboot` input with the patches
  in `patches/uboot/`. Newer `nixos-unstable` removed
  `boot.initrd.systemd.enable`, which `pi5.impermanence` still uses. Keep the
  patch provenance notes; drop the patches and the input once U-Boot ships them.
- **Move `/boot` onto the btrfs root.** It must stay ext4 (or FAT) and
  legacy-BIOS-bootable. The disko priorities (`firmware=100`, `boot=200`,
  `root=9001`) and the `boot_targets`-removal U-Boot shape were found
  empirically.
- **Switch the kernel to mainline** without testing RP1 (USB + Ethernet) on
  hardware. The vendor kernel is the supported pairing for the firmware DTBs.
- **Replace the demo key** in `flake.nix` with a real long-lived key. Its private
  half was discarded on purpose.
- **Drop `system.nixos.variant_id = "installer"`** from the installer module: it
  skips flaky Pi 5 kexec. Root SSH with keys is required by `nixos-anywhere`
  (it hardcodes root for installer targets), so the two go together.
- **Let the SD card be repartitioned.** The SD description is guarded, not merely
  `destroy = false`: its `preCreateHook` refuses to create a partition table or
  `mkfs` on anything that is not the expected two-partition MBR layout with the
  `FIRMWARE`/`NIXOS_BOOT` labels.
- **Relax the root-wipe service.** Keep `RemainAfterExit`, `subvol=/`, the
  fail-closed `RequiredBy`, fixed-point nested-subvolume deletion, no
  awk/arrays/process substitution, and no `neededForBoot` on `/boot` or
  `/boot/firmware`. Every one of those was found empirically; see README
  "Root-wipe mechanics".
- **Rename `NVME_BOOT` back to `NIXOS_BOOT`.** `NIXOS_BOOT` is the installer SD
  card's ext4 partition. Sharing the label makes `by-label` lookups ambiguous
  when the installer SD is inserted during recovery.

## Keep in sync

- `eeprom/boot.conf` and `eeprom/README.md` (`BOOT_ORDER=0xf416`,
  `PCIE_PROBE=1`) with the NVMe-only section of the README and the CLI's
  `--eeprom-config` examples. The EEPROM is not declarative.
- README "Hard-won details", the layouts, and the option tables with module
  changes.

## Before committing

```bash
nix fmt
nix flake check
```

`nix flake check` covers evaluation of the demo installer and the two stack
configurations, the negative assertion cases (including "no boot medium" and
"both boot media"), formatting, shellcheck (including `modules/root-wipe.sh`),
and building the `pi5-image` wrapper. It does **not** build the aarch64-linux SD
image or the NVMe-only system; use an aarch64-linux builder:

```bash
nix build .#images.pi5-bootstrap
nix build .#checks.aarch64-linux.uboot-nvme   # patched U-Boot: NVMe preboot present, boot_targets= absent
```
