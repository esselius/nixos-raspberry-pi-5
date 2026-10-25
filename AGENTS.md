# Maintenance notes

This repo is the reusable Raspberry Pi 5 + NVMe bring-up layer extracted from
`nix-homelab-hosts`. It intentionally contains no application workloads.

- `modules/` is grouped by concern. `default.nix` is the opinionated full stack;
  the other files are independently importable through the flake's
  `nixosModules.<name>` wrappers.
- Flake wrappers (not the module files) import `nixos-hardware`, `disko`, and
  `impermanence`. Keep it that way so consumers do not need to pass `inputs`
  through `specialArgs`.
- `scripts/pi5-image.sh` is orchestration only. Disk layout, boot chain, and
  persistence must stay declarative in `modules/`. The package closure pins
  `nixos-anywhere`, `zstd`, and `openssh`.
- Keep the root-wipe service's non-obvious properties: `RemainAfterExit`, nested
  subvolume deletion, no awk/arrays/process substitution, and no
  `neededForBoot` on `/boot` or `/boot/firmware`. They were found empirically;
  see README "Root-wipe mechanics".
- Keep the SD card description mount-only (`destroy = false`) and only pair it
  with disko's mount mode. It must never reformat the SD card.
- Do not switch the kernel to mainline without testing RP1 (USB + Ethernet) on
  hardware; the vendor kernel is the supported pairing for the firmware DTBs.
- The bootstrap image must keep `system.nixos.variant_id = "installer"` (skips
  flaky Pi 5 kexec) and root SSH with keys (nixos-anywhere hardcodes root for
  installer targets).
- Run `nix fmt` and `nix flake check` before committing. The checks cover
  evaluation, formatting, shellcheck, and building the `pi5-image` wrapper; they
  do not build the aarch64-linux SD image.
- Build the image with an aarch64-linux builder when validating changes:
  `nix build .#images.pi5-bootstrap`.
- Keep README "Hard-won details", the migration section, and the option tables
  in sync with module changes.
