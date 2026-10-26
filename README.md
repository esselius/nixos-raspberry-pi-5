# NixOS on Raspberry Pi 5 with an NVMe root

Reusable NixOS modules and an imaging/provisioning CLI for bringing a Raspberry Pi 5 online with:

- the vendor Raspberry Pi 5 kernel and firmware (U-Boot + extlinux),
- the bootloader on a microSD card,
- an ephemeral btrfs root on NVMe (impermanence),
- a one-shot bootstrap installer image for `nixos-anywhere`, without kexec.

This is the Pi 5 + NVMe + boot/storage layer extracted from
[`esselius/nix-homelab-hosts`](https://github.com/esselius/nix-homelab-hosts), where the
same design has been exercised on real 4 GB and 8 GB boards. The application layer
(incus, WireGuard, DNS, sops, monitoring, caches) deliberately stays in that project.

## What is in the box

| Output | Purpose |
|--------|---------|
| `nixosModules.default` | The full stack: Pi 5 hardware, NVMe root, SD boot, impermanence (snapshots opt-in). |
| `nixosModules.raspberry-pi-5` | Pi 5 vendor kernel, firmware staging, U-Boot, initrd module closure fix. |
| `nixosModules.nvme-root` | disko layout for the NVMe btrfs subvolumes, fstrim, and auto-scrub. |
| `nixosModules.sd-boot` | A guarded disko description of the SD card's existing partitions. |
| `nixosModules.impermanence` | Per-boot root reset, persisted paths, and optional snapper. |
| `nixosModules.installer` | Turns a configuration into the throwaway bootstrap SD image. |
| `lib.mkPi5Installer` | Builds an installer `nixosConfiguration` with a few arguments. |
| `packages.pi5-image` / `apps.pi5-image` | Build, flash, install, and provision CLI. |
| `images.pi5-bootstrap` | The demo installer image built from this repository's example. |

The modules close over this flake's `nixos-hardware`, `disko`, and `impermanence` inputs,
so consumers do not need to pass `inputs` through `specialArgs` or import those modules
themselves.

The repository's demo installer and example host use a test-only public key whose private
half was discarded, so the demo image is intentionally unreachable. Replace it with your
own key when using the examples; real installer configs must set `sshAuthorizedKeys`.

## Architecture

Boot chain for every host:

```
Pi 5 EEPROM -> firmware (SD p1 FAT) -> u-boot.bin -> extlinux.conf (SD p2 ext4)
            -> vendor kernel + initrd -> NVMe root (btrfs)
```

- **microSD owns the bootloader.** The SD card has the stock two-partition `sd-image-aarch64`
  layout. `/boot` is rewritten by the main host configuration on every rebuild.
- **NVMe owns the system and persistent state.** `@root` is reset on every boot; `@persist`
  is the only state that survives. `@nix` and `@snapshots` are separate subvolumes.
- **Vendor kernel, not mainline.** The `nixos-hardware` Raspberry Pi 5 profile defaults to
  `linux-rpi`. Mainline plus the vendor firmware DTBs produced `rp1_driver -22` (EINVAL)
  probe failures on real hardware, which killed both USB and Ethernet (the RP1 hosts both).
- **No kexec.** The bootstrap image sets `system.nixos.variant_id = "installer"`, which makes
  `nixos-anywhere` skip kexec. Pi 5 kexec is flaky; SD-image boot is the supported path.
- **No U-Boot fork or EEPROM configuration.** The chain above is stock nixpkgs +
  `nixos-hardware` firmware staging.

### Design decisions

| Decision | Value | Why |
|----------|-------|-----|
| nixpkgs | `nixos-unstable`, pinned | At extraction time the stable 26.05 SD images lacked the Pi 5 boot files; pinning means updates happen deliberately. |
| Board support | `nixos-hardware.nixosModules.raspberry-pi-5` | Upstream profile: extlinux, BCM2712 DTB filter, NVMe/PCIe/RP1 initrd modules, firmware staging. |
| Kernel | vendor `linux-rpi` | Mainline plus the vendor firmware DTBs broke RP1 (USB + Ethernet) with `-22`/EINVAL probe failures. |
| Boot device | microSD owns the bootloader | U-Boot v2026.10 still lacks NVMe support; the chain above is stock, with no U-Boot fork. |
| Filesystem | btrfs | Checksums and scrubs without a third-party module constraining kernel updates; ZFS is heavier for 4/8 GB boards. |
| Install | `nixos-anywhere`, kexec skipped | Pi 5 kexec is flaky; `variant_id = "installer"` makes nixos-anywhere use the SD-image boot path. |

The SD layout is deliberately the stock two-partition shape. A persistent rescue partition
was tried and dropped: every real incident still ended in a reflash, while the extra
partition added partition math and boot-order ambiguity.

### SD card layout

Created by flashing the bootstrap image. Normal rebuilds leave the partitions in place and
rewrite `/boot`; a hard reset may touch them, so treat the SD card as disposable.

| Partition | FS | Mount | Contents |
|-----------|----|-------|----------|
| p1 | FAT32 | `/boot/firmware` | GPU boot code, DTBs, overlays, `config.txt`, `u-boot.bin` |
| p2 | ext4, bootable | `/boot` | `extlinux.conf`, kernel, initrd per generation |

Use an 8 GB or larger microSD card. The installer's ext4 root is resized to 4 GiB so the
target closure fits during `nixos-anywhere`; the built image is about 4.3 GiB raw (1.4 GiB
compressed).

### NVMe layout

The disk that carries the system. A hard reset destroys and recreates it. The SD card is a
disposable installer medium and may be touched or rewritten during a hard reset.

| Subvolume | Mount | Lifetime |
|-----------|-------|----------|
| `@root` | `/` | Reset to an empty subvolume at every boot |
| `@nix` | `/nix` | Persists (the Nix store) |
| `@persist` | `/persist` | Persists: `machine-id`, SSH host keys, `/var/lib/nixos`, `/var/log`, plus whatever you add |
| `@snapshots` | `/snapshots` | snapper's snapshot store for `/persist` |

Mount options are `noatime,compress=zstd,nodiscard`; `services.fstrim` batches discards
instead of paying write amplification on every freed block.

## Quick start

### 1. Add this flake as an input

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    pi5 = {
      url = "path:../nixos-raspberry-pi-5"; # or github:esselius/nixos-raspberry-pi-5
      # Use your own nixpkgs/disko/impermanence pins, or omit this to use the
      # versions this flake was tested with.
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, pi5, ... }:
  let
    mkHost = modules: nixpkgs.lib.nixosSystem {
      system = "aarch64-linux";
      modules = [ pi5.nixosModules.default ] ++ modules;
    };
  in {
    nixosConfigurations = {
      # A normal host. Add your SSH/user config, services, and host name.
      rpi5-8gb = mkHost [ ./hosts/rpi5-8gb.nix ];

      # The throwaway installer image.
      rpi5-bootstrap = pi5.lib.mkPi5Installer {
        hostName = "rpi5-bootstrap";
        sshAuthorizedKeys = [
          "ssh-ed25519 AAAA... you@workstation"
        ];
        extraModules = [
          { system.stateVersion = "26.05"; }
        ];
      };
    };

    images.rpi5-bootstrap =
      self.nixosConfigurations.rpi5-bootstrap.config.system.build.sdImage;

    # Optional: re-export the CLI so `nix run .#pi5-image` works in this repo.
    # Use aarch64-linux (or x86_64-linux) on a Linux workstation.
    packages.aarch64-darwin.pi5-image = pi5.packages.aarch64-darwin.pi5-image;
  };
}
```

`pi5.lib.mkPi5Installer` wires the installer module, Raspberry Pi 5 hardware support, and
`system.stateVersion`. `extraModules` is where project-wide settings (SSH, Nix settings,
state version overrides) belong.

### 2. Build and flash the installer

```bash
# Build the SD image from the installer configuration.
nix run .#pi5-image -- build --flake . --installer rpi5-bootstrap --output pi5-bootstrap.img

# Flash it. Find the card with `diskutil list` on macOS or `lsblk` on Linux.
# On macOS the raw disk is /dev/rdiskN (faster than /dev/diskN).
nix run .#pi5-image -- flash pi5-bootstrap.img /dev/rdisk4
```

The CLI refuses `/dev/rdisk0`, partitions, non-whole disks, and the disk that backs the
running system. It asks for confirmation unless `--yes` is passed.

### 3. Boot the Pi and install over the network

Insert the SD card, attach the NVMe, connect Ethernet, and power on. The installer gets an
address over DHCP. From the workstation:

```bash
# First install or a genuine clean slate: disko destroys and recreates the NVMe.
# The SD card is a disposable installer medium.
nix run .#pi5-image -- install \
  --flake . --host rpi5-8gb --mode wipe \
  root@192.168.50.80

# Or do everything above in one go: build, flash, wait for SSH, then install.
nix run .#pi5-image -- provision \
  --flake . --installer rpi5-bootstrap --host rpi5-8gb \
  /dev/rdisk4 root@192.168.50.80
```

`provision` requires the installer to be reachable at the given address and uses `--mode
wipe` by default. Pass `--mode mount` to reuse the existing NVMe content.

### 4. Soft reset (reuse the NVMe)

If the SD card or its bootloader is broken but the NVMe is fine, reflash the installer and
run:

```bash
nix run .#pi5-image -- install \
  --flake . --host rpi5-8gb --mode mount \
  root@192.168.50.80
```

`--mode mount` passes `--disko-mode mount` to `nixos-anywhere`, which mounts the existing
NVMe filesystems and the SD card and then rewrites the system and bootloader without
destroying the NVMe. This is verified on real hardware in the source project.

If the NVMe previously held a ZFS pool, disko may skip `mkfs.btrfs` because the installer
has ZFS disabled and cannot destroy the pool. Discard the disk first from the booted
installer, or let the CLI do it:

```bash
nix run .#pi5-image -- provision --flake . --installer rpi5-bootstrap --host rpi5-8gb \
  --wipe-nvme /dev/nvme0n1 /dev/rdisk4 root@192.168.50.80
```

## Module reference

The granular modules are composable. `nixosModules.default` imports all of them; if you
import `nvme-root`, `sd-boot`, or `impermanence` individually, also import
`raspberry-pi-5` for actual hardware support, and make sure the storage modules agree on
subvolume names and mount points. `impermanence` expects a mounted persist filesystem, and
derives its root device and snapshot mount from `nvme-root` unless you set `rootDevice` and
`snapshots.mountPath` yourself.

### `pi5.nvme`

| Option | Default | Notes |
|--------|---------|-------|
| `device` | `"/dev/nvme0n1"` | Whole disk; `/dev/disk/by-id/...` is recommended with multiple NVMe devices. |
| `partitionLabel` | `"NVME_ROOT"` | Used by the initrd root reset, not the kernel device name. |
| `mountOptions` | `[ "noatime" "compress=zstd" "nodiscard" ]` | Applied to every subvolume. |
| `subvolumes` | `@root→/`, `@nix→/nix`, `@persist→/persist`, `@snapshots→/snapshots` | Subvolume name to mount point. |

The module also enables `services.fstrim` and scrubs the `@persist` mount.

### `pi5.sdBoot`

| Option | Default | Notes |
|--------|---------|-------|
| `device` | `"/dev/mmcblk0"` | Pi 5 SD slot. |
| `firmwareLabel` | `"FIRMWARE"` | Must match the installer's FAT volume label. |
| `rootLabel` | `"NIXOS_BOOT"` | Must match `pi5.installer.rootVolumeLabel`. |

The mounts are fixed at `/boot/firmware` (vfat) and `/boot` (ext4), matching
`generic-extlinux-compatible` and the stock sd-image layout. The partitions are mounted by
filesystem label, not by `mmcblk0pN`.

This description exists so disko can mount the SD's existing partitions and give the
bootloader install its `/boot` and `/boot/firmware`. It has `destroy = false`, and a
`preCreateHook` that refuses to create a partition table or run `mkfs` on anything that is
not already a two-partition MBR SD with the expected vfat/ext4 labels. A blank or damaged
SD must be reflashed; use `--mode mount` for a soft reset. A hard reset still touches the
SD (as a disposable installer medium).

### `pi5.impermanence`

| Option | Default | Notes |
|--------|---------|-------|
| `persistPath` | `"/persist"` | Must match the `@persist` mount point. |
| `rootDevice` | `/dev/disk/by-partlabel/<nvme.partitionLabel>` | btrfs top level used by the initrd reset; override when not using `nvme-root`. |
| `rootSubvolume` | `"@root"` | Deleted and recreated in the initrd on every boot. |
| `resetRoot` | `true` | Disable only for a deliberately mutable root. |
| `directories` | `/var/lib/nixos`, `/var/log` | Replaces the defaults when set. |
| `extraDirectories` | `[]` | Appended after `directories`; use this to add service state. |
| `files` | `machine-id`, SSH host keys | Replaces the defaults when set. |
| `extraFiles` | `[]` | Appended after `files`. |
| `snapshots.enable` | `false` | Snapper is site policy, not a hardware requirement. |
| `snapshots.subvolume` | `"@snapshots"` | Bind-mounted at `<persistPath>/.snapshots`. |
| `snapshots.mountPath` | `null` | Derived from `pi5.nvme.subvolumes`; set explicitly without `nvme-root`. |
| `snapshots.timeline.{hourly,daily,weekly,monthly,quarterly,yearly}` | `8`, `7`, `0`, `3`, `0`, `0` | Retention counts; `0` disables a bucket. |

`nixosModules.default` does not enable snapshots. Set
`pi5.impermanence.snapshots.enable = true` in the project/host layer to opt in; the original
homelab repo does this explicitly in `modules/storage.nix`.

### `pi5.installer`

| Option | Default | Notes |
|--------|---------|-------|
| `hostName` | `"pi5-bootstrap"` | |
| `sshAuthorizedKeys` | `[]` | Required in practice; evaluation fails if the effective root key list is empty. |
| `adminUser` | `"admin"` | Passwordless sudo + SSH. |
| `consoleAutologin` | `true` | |
| `permitRootLogin` | `"prohibit-password"` | `nixos-anywhere` needs root SSH on installer variants. |
| `firmwareSize` | `256` | MiB. |
| `rootVolumeLabel` | `"NIXOS_BOOT"` | ext4 boot/root partition label. |
| `rootFilesystemSize` | `"4G"` | Resized before image assembly so the target closure fits. |
| `extraPackages` | `[]` | Added to the installer environment (`vim` is always included). |

The installer disables ZFS (`boot.supportedFilesystems.zfs = false`). nixpkgs'
`sd-image-aarch64.nix` pulls in the base profile, which enables ZFS; `zfs-kernel` needs the
kernel's `dev` output, which is not in the binary caches, so leaving it on forces a full
`linux-rpi` build for every installer image.

### Hardware options

`nixosModules.raspberry-pi-5` sets:

```nix
hardware.raspberry-pi.firmware = {
  enable = true;        # refresh /boot/firmware on every switch
  uboot.enable = true;  # chainload U-Boot from config.txt
};
```

`nixos-hardware` exposes the rest of the firmware staging options
(`hardware.raspberry-pi.firmware.path`, `.package`, `.uboot.package`,
`.useGenerationDeviceTree`, and `hardware.raspberry-pi.configtxt.*`).

The module also applies the `makeModulesClosure` overlay with `allowMissing = true`: the
vendor kernel does not build every module the Raspberry Pi 5 profile's initrd asks for
(for example `tpm-crb`), and without the overlay the initrd build fails on the first
missing module.

## Imaging CLI

```
pi5-image build     [--flake FLAKE] [--installer NAME] [--output FILE] [--force]
pi5-image flash     IMAGE DISK [--yes] [--dry-run]
pi5-image install   --host HOST [--flake FLAKE] [--mode mount|wipe] TARGET
pi5-image provision --host HOST [--flake FLAKE] DISK TARGET
```

- `--flake` defaults to `.`; run it from the project that defines the
  `nixosConfigurations` and `images`.
- `--installer` defaults to `pi5-bootstrap` and addresses
  `nixosConfigurations.<name>.config.system.build.sdImage`.
- `install` defaults to `--mode mount`; `provision` defaults to `--mode wipe`. There is no
  silent destructive default in `install`.
- `--ssh-key` is passed to both `nixos-anywhere` and the reachability wait; `--ssh-port`
  and repeatable `--ssh-option` are forwarded too.
- `--build-on auto|local|remote` is forwarded to `nixos-anywhere`. `auto` is the default;
  `remote` builds the closure on the Pi, which is useful when the workstation cannot build
  aarch64-linux.
- `--wipe-nvme /dev/nvme0n1` runs `blkdiscard` on the target before installing; use it after
  a previous ZFS pool. It refuses `/dev/mmcblk*` and `/dev/loop*`.
- `install`/`provision` verify that the target has `VARIANT_ID=installer` before running
  `nixos-anywhere`; `--allow-non-installer` bypasses the check.
- `provision --no-wait` stops after flashing and leaves the install command for later.
- `--accept-flake-config` is opt-in; the CLI does not trust a target flake's `nixConfig` by
  default.
- `--` passes the remaining arguments to `nixos-anywhere`.
- `NIXOS_ANYWHERE=/path/to/nixos-anywhere` overrides the pinned tool.

The CLI is a `writeShellApplication` with `nixos-anywhere`, `zstd`, `openssh`, GNU
coreutils/gawk/sed/grep, and (on Linux) util-linux pinned in its runtime closure. It works
on macOS and Linux. Building the SD image still needs an aarch64-linux builder (or a Linux
host); the CLI does not hide that. The Nix build output is rooted with an out-link until the
command exits, so a concurrent GC cannot remove it mid-flash.

## Install playbooks

### Hard reset (wipes NVMe)

```bash
nix run .#pi5-image -- build --flake . --installer rpi5-bootstrap --output pi5-bootstrap.img
nix run .#pi5-image -- flash pi5-bootstrap.img /dev/rdisk4
# boot the Pi with the NVMe attached
nix run .#pi5-image -- install --flake . --host rpi5-8gb --mode wipe root@<ip>
```

No manual chroot or `switch-to-configuration boot` dance is needed. The SD card's partitions
are declared in disko, so the bootloader install step writes into the SD card in the same
run. With `--mode wipe`, nixos-anywhere uses disko's default destroy/create path: the NVMe
is recreated and the SD is mounted for the bootloader install. The SD is disposable; reflash
it if the install is interrupted. A soft reset uses `--mode mount` and only mounts both
disks.

### Soft reset (SD reflash, NVMe preserved)

```bash
# reflash the installer, boot it, then:
nix run .#pi5-image -- install --flake . --host rpi5-8gb --mode mount root@<ip>
```

### Recovery

| Symptom | Fix | NVMe impact |
|---------|-----|-------------|
| SD card or bootloader broken, NVMe fine | reflash the installer, then soft reset | none |
| Want a genuinely clean slate | reflash the installer, then hard reset | destroyed |
| Host does not boot after a bad activation | select the previous generation at the U-Boot/extlinux prompt on SD p2 | none |

## Hard-won details

These are the non-obvious parts that make the design work. Keep them in mind before
"simplifying" the modules.

### The bootloader-install caveat

`nixos-anywhere` only auto-mounts filesystems that **disko** declares; it has no flag to
mount arbitrary extra filesystems. If disko only knows about the NVMe, the bootloader install
writes `extlinux.conf` and kernels into `@root/boot` on the NVMe instead of onto the SD card.
The generation may boot once by luck, and then the next boot's impermanence reset deletes
`@root` and the bootloader with it.

`pi5.sdBoot` describes the SD card's **existing** FAT + ext4 partitions. That makes
`nixos-anywhere --disko-mode mount` mount both disks and lets the bootloader step succeed
automatically. It is intended for mount mode; in create mode its `preCreateHook` verifies
that the disk is already the expected two-partition MBR layout and aborts otherwise, so a
blank or damaged SD is reflashed rather than silently repartitioned. `destroy = false` keeps
the disk out of disko's destroy stage as well.

### Root-wipe mechanics

`boot.initrd.systemd.services.root-wipe` runs before `sysroot.mount`, deletes `@root`, and
recreates it empty. Several details are load-bearing:

1. **`RemainAfterExit = true` is required.** Without it, systemd started the unit twice per
   boot. Two near-simultaneous mount + delete/create sequences against the same btrfs device
   reliably hung the entire boot with no further console output.
2. **Mount the top level with `subvol=/`.** Mounting the filesystem's default subvolume
   would make `/btrfs_tmp/@root` resolve inside that subvolume instead of the top level.
3. **Fail closed.** The unit is `RequiredBy=sysroot.mount`, not merely wanted, so a failed
   wipe stops the boot instead of mounting a partially wiped root.
4. **Delete nested subvolumes first, to a fixed point.** systemd auto-creates
   `@root/srv`, `@root/var/lib/portables`, `@root/var/lib/machines`, `@root/tmp`, and
   `@root/var/tmp` on first boot. `btrfs subvolume list` is parent-first, so the script
   repeats deletion passes until no more progress is made. The child list lives in
   `/run`, not on the btrfs top level.
5. **The initrd shell has no `awk`.** It also does not reliably support bash arrays or
   process substitution. The module parses `btrfs subvolume list` with a POSIX `while read`
   loop; do not replace it with a "nicer" pipeline.
6. **Do not mark `/boot` or `/boot/firmware` `neededForBoot`.** U-Boot has already loaded
   the kernel and initrd before Linux starts. Forcing initrd to probe SD/MMC while NVMe PCIe
   enumeration is happening contributed to early-boot hangs.
7. **Assertions guard the catastrophic cases:** `@nix` must mount at `/nix`, exactly one
   subvolume must mount at `/`, and the persist/snapshot mounts must be declared btrfs
   filesystems.

### Vendor kernel and module closure

The profile's vendor kernel is deliberate; see the architecture section. The
`makeModulesClosure` overlay with `allowMissing = true` is also required: the initrd wants
modules the vendor kernel fork does not build. This is independent of
`hardware.enableAllHardware`.

### disko's legacy-table warning

Evaluating any host prints disko's "legacy table is outdated" warning for the SD card. The
SD is MBR/msdos, and disko's newer `gpt` type addresses partitions by GPT partlabel, so it
cannot describe this disk. disko offers no way to silence just this warning
(nix-community/disko#812). It is harmless because the SD description is mount-only.

### No kexec / root SSH on the installer

`nixos-anywhere` hardcodes root SSH for targets with `system.nixos.variant_id =
"installer"`, and there is no flag to override it. The installer therefore allows root SSH
with keys. This is acceptable because the image is throwaway and reflashed before every use.
Skipping kexec (for Pi 5 stability) and disabling root SSH on the installer are mutually
exclusive.

### Unchecked hardware assumptions

- U-Boot v2026.10's `rpi_arm64_defconfig` still lacks NVMe support. NVMe-only boot needs the
  Pi firmware plus a kernel bootloader (or a future U-Boot patch), not just a config change.
- Some M.2 HATs have NVMe adapter/EEPROM quirks. This design does not depend on booting from
  NVMe, so those are irrelevant until the boot path changes.
- Use the 27 W USB-C PSU and active cooling for sustained load on either board.
- The vendor kernel is not in a public Hydra jobset. A `nix flake update` that bumps
  `nixos-hardware` can mean a long local `linux-rpi` build; update inputs deliberately and
  warm your binary cache.

## Reusing this in `nix-homelab-hosts`

The original project keeps its application modules; only the Pi/NVMe/boot layer moves here.
Concretely:

### Add the input and re-export the CLI

```nix
inputs.pi5 = {
  url = "path:../nixos-raspberry-pi-5"; # or github:esselius/nixos-raspberry-pi-5
  inputs.nixpkgs.follows = "nixpkgs";
};

# Optional, so `nix run .#pi5-image` works from the original repo:
packages.aarch64-darwin.pi5-image =
  inputs.pi5.packages.aarch64-darwin.pi5-image;
```

The original can then drop its `nixos-hardware`, `disko`, and `impermanence` inputs if they
are not used elsewhere. `sops-nix` stays.

### Main hosts

Replace the contents of the old Pi/storage imports in `flake.nix`:

```nix
mainHostModules = [
  inputs.pi5.nixosModules.default
  ./modules/nix-settings.nix
  ./modules/ssh-access.nix
  ./modules/site.nix
  ./modules/wireguard.nix
  ./modules/dns.nix
  ./modules/incus
  ./modules/sops.nix
  ./modules/monitoring-agent.nix
  ./modules/cgroup-metrics.nix
  ./modules/nvme-wear.nix
  ./modules/nix-cache.nix
  ./modules/pki.nix
  ./modules/storage.nix   # now only project-specific additions
];
```

`mkHost (mainHostModules ++ [ ./hosts/rpi5-8gb.nix ])` stays as it is.

Delete:

- `modules/raspberry-pi.nix` (vendor profile, overlay, firmware),
- `disko-nvme.nix` (NVMe layout),
- `disko-sd.nix` (SD mount description),
- the `disko.nixosModules.disko` and `impermanence.nixosModules.impermanence` imports.

Trim `modules/storage.nix` to only the application-specific persistence additions. The
root-wipe service, fstrim, auto-scrub, snapper config, and the `/persist/.snapshots` bind
mount now come from `pi5.impermanence`. Snapshots are opt-in in the extracted default stack,
so the original explicitly enables them to preserve its behavior:

```nix
{ ... }:
{
  pi5.impermanence = {
    snapshots.enable = true;
    extraDirectories = [
      "/var/lib/incus"
      "/var/lib/unbound"
    ];
  };
}
```

`/var/lib/nixos`, `/var/log`, the machine-id, and the SSH host keys are already defaults, so
they do not need to be repeated. Use `extraFiles` for additional files. `hosts/rpi5-8gb.nix`
and `hosts/rpi5-4gb.nix` do not need changes.

### Bootstrap installer

Replace `hosts/rpi5-bootstrap.nix` with `mkPi5Installer`. Keep the project SSH settings by
reusing `ssh-access.nix`, and set `site.permitRootLogin` to `"prohibit-password"` (the
installer module defaults to that, but `ssh-access.nix` would otherwise set it to `"no"`):

```nix
rpi5-bootstrap = inputs.pi5.lib.mkPi5Installer {
  hostName = "rpi5-bootstrap";
  # sshAuthorizedKeys can be omitted here because ssh-access.nix already
  # supplies the root/admin keys from site.sshPublicKey.
  extraModules = [
    ./modules/nix-settings.nix
    ./modules/ssh-access.nix
    {
      system.stateVersion = "26.05";
      site.permitRootLogin = "prohibit-password";
    }
  ];
};
```

The old bootstrap-specific settings (`variant_id`, `sdImage.firmwareSize`,
`rootVolumeLabel`, the resize hook, autologin, ZFS off, vim) are all in the installer module.
`images.rpi5-bootstrap` can keep pointing at
`config.system.build.sdImage`.

### Taskfile

The CLI replaces the shell in `bootstrap`, `flash`, `install`, and `install:mount`; the
`HOST`/`IP` inventory resolution stays in the project:

```yaml
bootstrap:
  cmds:
    - nix run .#pi5-image -- build --flake . --installer rpi5-bootstrap --output {{.BOOTSTRAP_IMAGE}} --force

flash:
  cmds:
    - nix run .#pi5-image -- flash {{.BOOTSTRAP_IMAGE}} {{.DISK}} --yes

install:
  cmds:
    - |
      ip="$(scripts/host-ip.sh "{{.HOST}}" "{{.IP}}")"
      nix run .#pi5-image -- install --flake . --host "{{.HOST}}" --mode wipe --yes "root@$ip"

install:mount:
  cmds:
    - |
      ip="$(scripts/host-ip.sh "{{.HOST}}" "{{.IP}}")"
      nix run .#pi5-image -- install --flake . --host "{{.HOST}}" --mode mount --yes "root@$ip"
```

Keep the existing `CONFIRM=WIPE|MOUNT|FLASH` gating if you want it; the CLI independently
requires `--yes` or an interactive confirmation. `install` is the hard reset (it recreates
the NVMe and reinstalls the bootloader on the SD, which is disposable); `install:mount`
preserves both. Keep the original dirty-worktree guard and `nix flake check` before the CLI
call; only the `nixos-anywhere` invocation changes.

## Development

```bash
nix develop
nix flake check          # eval-all + fmt + shellcheck + CLI wrapper build
nix fmt
nix build .#pi5-image
nix run .#pi5-image -- --help
```

`nix flake check` evaluates every `nixosConfiguration` and the installer image derivation
but does not build the aarch64-linux image. Build that with an aarch64-linux builder:

```bash
nix build .#images.pi5-bootstrap
```

### Verification status

This extraction has been checked in several ways:

- `nix flake check` passes on an Apple Silicon macOS host (eval-all, formatting, shellcheck,
  and the `pi5-image` wrapper build), and the same checks evaluate for `aarch64-linux`.
- `nix build .#images.pi5-bootstrap` completed through an aarch64-linux builder: a 4.26 GiB
  raw image, 1.41 GiB compressed. The FAT partition contains the Pi 5 DTBs, `u-boot.bin`,
  and a `config.txt` with `kernel=u-boot.bin` and `arm_64bit=1`; the ext4 partition contains
  `extlinux.conf` pointing at the vendor `linux-rpi` kernel and initrd (6.18.50 at
  extraction time).
- `nix-homelab-hosts` was migrated on branch `pi5-extract` using the steps in this README.
  All three configurations (`rpi5-8gb`, `rpi5-4gb`, `rpi5-bootstrap`) evaluate and
  `nix flake check` passes. The migration preserved the original layout, kernel, firmware,
  persistence, installer `sdImage`, SSH settings, and `variant_id`. The later hardening
  pass intentionally changes a few details: `/boot` and the firmware partition mount by
  label, the SD create path is guarded, the root wipe is fail-closed, snapshot yearly
  retention defaults to 0, and the installer no longer duplicates the `wheel` group.
- The consumer API was tested with `inputs.pi5.nixosModules.default`,
  `inputs.pi5.nixosModules.<granular>`, and `inputs.pi5.lib.mkPi5Installer`, including
  `inputs.pi5.inputs.nixpkgs.follows = "nixpkgs"`.

The design and the individual mechanics were verified on real hardware in the source
project, including:

- vendor kernel boot, RP1 (USB + Ethernet) alive, NVMe enumerated on PCIe;
- the full impermanence mount tree and the root-wipe `RemainAfterExit` fix, with consecutive
  clean reboots and no failed units;
- `nixos-anywhere` hard reset and `--disko-mode mount` soft reset, including an automatic
  bootloader install into the SD card and a reboot into the working system;
- a marker file on `/` disappearing after reboot while the `/persist` marker survived.

The extracted modules have not yet been booted on hardware themselves. Treat a first install
from this repository as a bring-up test, and keep the source project's verification
checklist for the application layer.

## Out of scope

Deliberately left in `nix-homelab-hosts`: incus, WireGuard, Unbound/DNS, sops, the caching
layer, Grafana Alloy, the NVMe SMART wear collector, and the host inventory/Taskfile
conveniences. Those are application or fleet concerns, not the Pi 5 + NVMe boot layer.
