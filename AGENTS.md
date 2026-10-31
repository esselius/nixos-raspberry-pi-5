# Maintenance notes

This repo is the reusable Raspberry Pi 5 + NVMe bring-up layer extracted from
`nix-homelab-hosts`. It intentionally contains no application workloads.

- `modules/` is grouped by concern. `default.nix` is the base stack (hardware +
  NVMe root + impermanence) and deliberately has **no boot medium**; `sd-boot.nix`
  and `nvme-boot.nix` are mutually exclusive opt-ins. The convenience wrappers
  are `default-sd-boot` and `default-nvme-boot`. Snapper stays opt-in (site
  policy). The other files are independently importable through the flake's
  `nixosModules.<name>` wrappers.
- Flake wrappers (not the module files) import `nixos-hardware`, `disko`, and
  `impermanence`. Keep it that way so consumers do not need to pass `inputs`
  through `specialArgs`.
- The NVMe-only path needs U-Boot 2026.10+, built from the separate
  `nixpkgs-uboot` input with the patches in `nix/patches/uboot/`. Do not bump the
  main `nixpkgs` pin to get a newer U-Boot: newer `nixos-unstable` removed
  `boot.initrd.systemd.enable`, which `pi5.impermanence` still uses. Keep the
  patch provenance notes and drop the patches + input once U-Boot ships them.
- `pi5.nvmeBoot` is the NVMe-only layout: FAT `FIRMWARE` (p1), ext4
  `NIXOS_BOOT` (p2), btrfs `NVME_ROOT` (p3). The disko priorities
  (`firmware=100`, `boot=200`, `root=9001`), the legacy-BIOS-bootable attribute
  on `/boot`, and the `boot_targets`-removal U-Boot shape were found empirically.
  `/boot` must stay ext4/FAT and must not move onto the btrfs root.
- The EEPROM is not declarative. Keep `examples/nvme-boot/boot.conf`
  (`BOOT_ORDER=0xf416`, `PCIE_PROBE=1`) and the `pi5-image eeprom` /
  `--eeprom-config` docs in sync with the NVMe-only section.
- `scripts/pi5-image.sh` is orchestration only. Disk layout, boot chain, and
  persistence must stay declarative in `modules/`. The package closure pins
  `nixos-anywhere`, `zstd`, `openssh`, coreutils/gawk/sed/grep, and (on Linux)
  util-linux.
- Keep the root-wipe service's non-obvious properties: `RemainAfterExit`,
  `subvol=/`, fail-closed `RequiredBy`, fixed-point nested-subvolume deletion,
  no awk/arrays/process substitution, and no `neededForBoot` on `/boot` or
  `/boot/firmware`. They were found empirically; see README "Root-wipe
  mechanics".
- The SD card description is guarded, not merely `destroy = false`: its
  `preCreateHook` refuses to create a partition table or `mkfs` on anything
  that is not the expected two-partition MBR layout with `FIRMWARE`/`NIXOS_BOOT`
  labels. Keep that guard.
- The demo host/image key is a test-only public key with the private half
  discarded. Do not replace it with a real long-lived key.
- Do not switch the kernel to mainline without testing RP1 (USB + Ethernet) on
  hardware; the vendor kernel is the supported pairing for the firmware DTBs.
- The bootstrap image must keep `system.nixos.variant_id = "installer"` (skips
  flaky Pi 5 kexec) and root SSH with keys (nixos-anywhere hardcodes root for
  installer targets).
- Run `nix fmt` and `nix flake check` before committing. The checks cover
  evaluation of both boot-path examples, negative assertion tests (including
  "no boot medium" and "both boot media"), formatting, shellcheck (including
  `modules/scripts/root-wipe.sh`), and building the `pi5-image` wrapper; they do
  not build the aarch64-linux SD image or the NVMe-only system.
- Build with an aarch64-linux builder when validating changes:
  `nix build .#images.pi5-bootstrap` and
  `nix build .#nixosConfigurations.pi5-nvme-example.config.system.build.toplevel`.
  `nix build .#checks.aarch64-linux.uboot-nvme` verifies the patched U-Boot
  binary (NVMe preboot present, `boot_targets=` absent).
- Keep README "Hard-won details", the NVMe-only section, the migration section,
  and the option tables in sync with module changes.
