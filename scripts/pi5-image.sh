#!/usr/bin/env bash
# pi5-image: build, flash, and install NixOS on a Raspberry Pi 5 with an NVMe root.
#
# Run through `nix run .#pi5-image -- <command> [options]`. This script only
# orchestrates; the NixOS modules in this flake are the source of truth for the
# disk layout, boot chain, and impermanence setup.

set -euo pipefail

readonly prog="pi5-image"

flake="."
installer="pi5-bootstrap"
host=""
mode=""
target=""
output=""
wait_seconds=180
wipe_nvme=""
ssh_key=""
build_on="auto"
assume_yes=0
dry_run=0
force=0
no_wait=0
accept_flake_config=0
allow_non_installer=0
ssh_port=""
ssh_options=()
cleanup_file=""
work_dir=""
positional=()
extra_args=()

log() { printf '%s: %s\n' "$prog" "$*" >&2; }
die() {
  printf '%s: error: %s\n' "$prog" "$*" >&2
  exit 1
}

show() {
  printf '%s:' "$prog" >&2
  printf ' %q' "$@"
  printf '\n' >&2
}

usage() {
  cat <<'EOF'
Build, flash, and install NixOS on a Raspberry Pi 5 with an NVMe root.

Usage:
  pi5-image build     [--flake FLAKE] [--installer NAME] [--output FILE] [--force]
  pi5-image flash     IMAGE DISK [--yes] [--dry-run]
  pi5-image install   --host HOST [--flake FLAKE] [--mode mount|wipe] TARGET
  pi5-image provision --host HOST [--flake FLAKE] DISK TARGET

Commands:
  build      Build the installer's system.build.sdImage and write a decompressed .img.
  flash      Write an image to a raw card. On macOS use /dev/rdiskN (or /dev/diskN).
  install    Run nixos-anywhere against an already-booted installer.
             Default mode is mount: keep the existing NVMe content.
  provision  Build the installer, flash it, wait for SSH, then install.
             Default mode is wipe: destroy and recreate the NVMe.

Options:
  --flake FLAKE       Flake to evaluate (default: .)
  --installer NAME    nixosConfiguration for the bootstrap image (default: pi5-bootstrap)
  --host NAME         nixosConfiguration to install
  --mode MODE         mount (preserve NVMe and SD) or wipe (destroy/recreate NVMe; SD is disposable)
  --output FILE       build: decompressed image path (default: <installer>.img)
  --ssh-key FILE      SSH identity used by nixos-anywhere and the wait loop
  --ssh-port PORT     SSH port for the target (default: nixos-anywhere's 22)
  --ssh-option OPT    extra ssh -o option (repeatable)
  --build-on MODE     nixos-anywhere build location: auto, local, remote (default: auto)
  --wipe-nvme DEVICE  discard DEVICE on the target before installing (e.g. /dev/nvme0n1)
                      Needed after a previous ZFS pool left a stale label.
  --wait SECONDS      provision: how long to wait for SSH (default: 180)
  --no-wait           provision: stop after flashing; do not wait/install
  --allow-non-installer  skip the VARIANT_ID=installer target check
  --accept-flake-config  trust the target flake's nixConfig (substituters/keys)
  --yes, -y           skip confirmation prompts
  --dry-run, -n       print the commands instead of running them
  --force, -f         build: overwrite output; flash: allow a loop test device
  --                  pass the remaining arguments to nixos-anywhere
  -h, --help          show this help

Examples:
  pi5-image build --flake . --output pi5-bootstrap.img
  pi5-image flash pi5-bootstrap.img /dev/rdisk4
  pi5-image install --flake . --host rpi5-8gb root@192.168.50.80
  pi5-image provision --flake . --host rpi5-8gb /dev/rdisk4 root@192.168.50.80

Set NIXOS_ANYWHERE=/path/to/nixos-anywhere to override the pinned tool.
EOF
}

need() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

confirm() {
  if [ "$assume_yes" -eq 1 ]; then
    return 0
  fi
  if [ ! -t 0 ]; then
    die "refusing to continue without --yes (stdin is not a terminal)"
  fi
  printf '%s\nContinue? [y/N] ' "$1" >&2
  local answer
  read -r answer || die "aborted"
  case "$answer" in
    y | Y | yes | YES) ;;
    *) die "aborted" ;;
  esac
}

cleanup() {
  if [ -n "$cleanup_file" ]; then
    rm -f "$cleanup_file"
  fi
  if [ -n "$work_dir" ]; then
    rm -rf "$work_dir"
  fi
}
trap cleanup EXIT

validate_mode() {
  case "$mode" in
    mount | wipe) ;;
    *) die "--mode must be 'mount' or 'wipe' (got: $mode)" ;;
  esac
}

is_compressed() {
  case "$1" in
    *.zst) return 0 ;;
    *) return 1 ;;
  esac
}

nix_build_cmd() {
  local -a args=(
    nix
    --extra-experimental-features "nix-command flakes"
    build
    --out-link "$work_dir/result"
  )
  if [ "$accept_flake_config" -eq 1 ]; then
    args+=(--accept-flake-config)
  fi
  args+=("${flake}#nixosConfigurations.${installer}.config.system.build.sdImage")
  "${args[@]}"
}

find_image() {
  local out=$1
  local nullglob_was_set=0
  local -a candidates=()
  if shopt -q nullglob; then
    nullglob_was_set=1
  fi
  shopt -s nullglob
  candidates=("$out"/sd-image/*.img.zst "$out"/sd-image/*.img)
  if [ "$nullglob_was_set" -eq 0 ]; then
    shopt -u nullglob
  fi
  if [ "${#candidates[@]}" -eq 0 ]; then
    die "no SD image (*.img or *.img.zst) found under $out/sd-image"
  fi
  printf '%s\n' "${candidates[0]}"
}

build_image() {
  need nix
  if ! nix_build_cmd; then
    die "nix build failed. The SD image is an aarch64-linux derivation; on macOS configure an aarch64-linux builder or run the build on a Linux machine."
  fi
  find_image "$work_dir/result"
}

write_image_file() {
  local src=$1 dest=$2
  if [ -e "$dest" ] && [ "$force" -ne 1 ]; then
    die "output already exists: $dest (use --force to overwrite)"
  fi

  cleanup_file="${dest}.partial"
  log "writing $dest"
  if is_compressed "$src"; then
    need zstd
    zstd -dc "$src" >"$cleanup_file"
  else
    cp "$src" "$cleanup_file"
  fi
  mv "$cleanup_file" "$dest"
  cleanup_file=""
  log "wrote $dest ($(du -h "$dest" | cut -f1))"
}

preview_flash() {
  local src=$1 disk=$2 bs=$3
  if is_compressed "$src"; then
    log "would run: zstd -dc $(printf '%q' "$src") | sudo dd of=$(printf '%q' "$disk") bs=$bs conv=fsync"
  else
    log "would run: sudo dd if=$(printf '%q' "$src") of=$(printf '%q' "$disk") bs=$bs conv=fsync"
  fi
}

write_disk() {
  local src=$1 disk=$2 bs=$3
  local -a progress=()
  if [ "$(uname -s)" = "Linux" ] && dd --version >/dev/null 2>&1; then
    progress=(status=progress)
  fi

  if is_compressed "$src"; then
    need zstd
    zstd -dc "$src" | sudo dd of="$disk" bs="$bs" conv=fsync "${progress[@]}"
  else
    sudo dd if="$src" of="$disk" bs="$bs" conv=fsync "${progress[@]}"
  fi
  sync
}

normalize_darwin_disk() {
  local disk=$1 root_src root_whole root_store root_stores target_disk info
  case "$disk" in
    /dev/disk[0-9]*) disk="/dev/r${disk#/dev/}" ;;
    /dev/rdisk[0-9]*) ;;
    *) die "on macOS DISK must look like /dev/rdisk4 or /dev/disk4 (got: $disk)" ;;
  esac

  if [[ ! "$disk" =~ ^/dev/rdisk[0-9]+$ ]]; then
    die "refusing to write a partition or non-whole disk: $disk"
  fi
  if [ ! -e "$disk" ]; then
    die "no such disk: $disk"
  fi

  target_disk="disk${disk#/dev/rdisk}"
  info=$(diskutil info "$disk" 2>/dev/null || true)
  if [ -z "$info" ]; then
    die "diskutil cannot inspect $disk"
  fi
  if printf '%s\n' "$info" | grep -q 'Virtual:.*Yes'; then
    die "refusing to write $disk: it is a synthesized/virtual disk, not a physical device"
  fi

  # /dev/disk0 is the internal boot device on Apple Silicon. Refuse it
  # explicitly: df(1) reports the synthesized APFS container (disk3s...), not
  # the physical disk behind it, so the root check alone would miss it.
  if [ "$target_disk" = "disk0" ]; then
    die "refusing to write $disk: it is the internal system disk"
  fi

  # Resolve the physical disk(s) that back /. On Apple Silicon, / is a volume
  # on a synthesized APFS container whose physical store is e.g. disk0s2. On
  # non-APFS layouts the whole disk is already the physical device.
  root_src=$(df -P / | awk 'NR==2 {print $1}')
  root_whole=$(printf '%s\n' "$root_src" | sed -E 's#^/dev/r?(disk[0-9]+).*#\1#')
  root_stores=$(diskutil info "/dev/$root_whole" 2>/dev/null | awk -F': *' '/APFS Physical Store/ {print $2}')
  if [ -z "$root_stores" ]; then
    if [ "$root_whole" = "$target_disk" ]; then
      die "refusing to write $disk: it backs the running system"
    fi
  else
    while IFS= read -r root_store; do
      [ -n "$root_store" ] || continue
      root_whole=$(printf '%s\n' "$root_store" | sed -E 's#^(disk[0-9]+).*#\1#')
      if [ "$root_whole" = "$target_disk" ]; then
        die "refusing to write $disk: it backs the running system"
      fi
    done <<<"$root_stores"
  fi

  printf '%s\n' "$disk"
}

normalize_linux_disk() {
  local disk=$1 real target_name root_src root_real src mnt src_real
  if [ ! -b "$disk" ]; then
    die "not a block device: $disk"
  fi
  real=$(readlink -f "$disk")
  target_name=$(basename "$real")

  # A partition, LVM LV, RAID member, or loop device is not a flash target.
  # Accept loop devices only with --force, for tests.
  target_type=$(lsblk -dno TYPE "$real" 2>/dev/null || true)
  case "$target_type" in
    disk) ;;
    loop)
      if [ "$force" -ne 1 ]; then
        die "refusing loop device $disk; use --force only for loop-based tests"
      fi
      ;;
    *)
      die "refusing $disk: lsblk type '${target_type:-unknown}' is not a whole disk"
      ;;
  esac

  root_src=$(awk '$2 == "/" { print $1; exit }' /proc/mounts)
  root_real=$(readlink -f "$root_src" 2>/dev/null || printf '%s' "$root_src")
  case "$root_real" in
    "$real" | "$real"[0-9]* | "$real"p[0-9]*) die "refusing to write $disk: it backs /" ;;
  esac

  # Direct partitions are covered by the prefix checks. lsblk -s also walks
  # LVM/RAID/device-mapper parents, so a root filesystem on /dev/mapper/... is
  # caught even though /proc/mounts never mentions the underlying disk.
  while read -r src mnt _; do
    src_real=$(readlink -f "$src" 2>/dev/null || printf '%s' "$src")
    case "$src_real" in
      "$real" | "$real"[0-9]* | "$real"p[0-9]*) die "refusing to write $disk: $src is mounted at $mnt" ;;
    esac
    if command -v lsblk >/dev/null 2>&1 \
      && lsblk -s -l -no NAME "$src_real" 2>/dev/null | grep -Fqx "$target_name"; then
      die "refusing to write $disk: it backs $src (mounted at $mnt)"
    fi
  done </proc/mounts

  if [ -r /proc/swaps ]; then
    while read -r src _; do
      [ -n "$src" ] || continue
      [ "$src" = "Filename" ] && continue
      src_real=$(readlink -f "$src" 2>/dev/null || printf '%s' "$src")
      case "$src_real" in
        "$real" | "$real"[0-9]* | "$real"p[0-9]*) die "refusing to write $disk: $src is active swap" ;;
      esac
      if command -v lsblk >/dev/null 2>&1 \
        && lsblk -s -l -no NAME "$src_real" 2>/dev/null | grep -Fqx "$target_name"; then
        die "refusing to write $disk: it backs active swap ($src)"
      fi
    done </proc/swaps
  fi

  printf '%s\n' "$disk"
}

do_flash() {
  local src=$1 disk=$2 bs
  if [ ! -f "$src" ]; then
    die "image not found: $src"
  fi

  case "$(uname -s)" in
    Darwin)
      disk=$(normalize_darwin_disk "$disk")
      bs=4M
      if [ "$dry_run" -eq 1 ]; then
        preview_flash "$src" "$disk" "$bs"
        return 0
      fi
      diskutil unmountDisk "$disk"
      write_disk "$src" "$disk" "$bs"
      diskutil eject "$disk"
      ;;
    Linux)
      disk=$(normalize_linux_disk "$disk")
      bs=4M
      if [ "$dry_run" -eq 1 ]; then
        preview_flash "$src" "$disk" "$bs"
        return 0
      fi
      write_disk "$src" "$disk" "$bs"
      ;;
    *)
      die "unsupported platform: $(uname -s)"
      ;;
  esac
}

validate_disk() {
  case "$(uname -s)" in
    Darwin) normalize_darwin_disk "$1" >/dev/null ;;
    Linux) normalize_linux_disk "$1" >/dev/null ;;
    *) die "unsupported platform: $(uname -s)" ;;
  esac
}

do_ssh() {
  local -a args=(
    ssh
    -o BatchMode=yes
    -o ConnectTimeout=10
    -o UserKnownHostsFile=/dev/null
    -o StrictHostKeyChecking=no
  )
  if [ -n "$ssh_port" ]; then
    args+=(-p "$ssh_port")
  fi
  for opt in "${ssh_options[@]}"; do
    args+=(-o "$opt")
  done
  if [ -n "$ssh_key" ]; then
    args+=(-i "$ssh_key")
  fi
  "${args[@]}" "$@"
}

wait_for_ssh() {
  local deadline=$((SECONDS + wait_seconds))
  log "waiting up to ${wait_seconds}s for $target"
  while [ "$SECONDS" -lt "$deadline" ]; do
    if do_ssh "$target" true >/dev/null 2>&1; then
      log "target is reachable"
      return 0
    fi
    sleep 3
  done
  die "timed out after ${wait_seconds}s waiting for $target"
}

check_installer_target() {
  if [ "$allow_non_installer" -eq 1 ]; then
    return 0
  fi
  if ! do_ssh "$target" 'grep -q "^VARIANT_ID=installer" /etc/os-release' >/dev/null 2>&1; then
    die "target $target is not the installer image (VARIANT_ID=installer); use --allow-non-installer to override"
  fi
}

do_install() {
  local na=${NIXOS_ANYWHERE:-nixos-anywhere}
  local -a args=(--flake "${flake}#${host}" --build-on "$build_on")

  if [ "$mode" = "mount" ]; then
    args+=(--disko-mode mount)
  else
    args+=(--disko-mode disko)
  fi
  if [ -n "$ssh_port" ]; then
    args+=(-p "$ssh_port")
  fi
  for opt in "${ssh_options[@]}"; do
    args+=(--ssh-option "$opt")
  done
  if [ -n "$ssh_key" ]; then
    args+=(-i "$ssh_key")
  fi
  args+=("${extra_args[@]}" "$target")

  if [ -n "$wipe_nvme" ]; then
    case "$wipe_nvme" in
      /dev/mmcblk* | /dev/loop*)
        die "refusing --wipe-nvme on SD/eMMC/loop device: $wipe_nvme"
        ;;
    esac
    log "discarding $wipe_nvme on $target before install"
    if [ "$dry_run" -eq 1 ]; then
      show ssh "$target" "sudo blkdiscard -f $wipe_nvme"
    else
      do_ssh "$target" "test -b $(printf '%q' "$wipe_nvme")" \
        || die "no such block device on $target: $wipe_nvme"
      do_ssh "$target" "sudo blkdiscard -f $(printf '%q' "$wipe_nvme")"
    fi
  fi

  show "$na" "${args[@]}"
  if [ "$dry_run" -eq 1 ]; then
    return 0
  fi
  need "$na"
  "$na" "${args[@]}"
}

cmd_build() {
  if [ "${#positional[@]}" -ne 0 ]; then
    die "build takes no positional arguments"
  fi

  local dest=${output:-${installer}.img}
  if [ "$dry_run" -eq 1 ]; then
    log "would build ${flake}#nixosConfigurations.${installer}.config.system.build.sdImage"
    log "would write the decompressed image to $dest"
    return 0
  fi

  local image
  image=$(build_image)
  log "SD image: $image"
  write_image_file "$image" "$dest"
}

cmd_flash() {
  if [ "${#positional[@]}" -ne 2 ]; then
    die "usage: pi5-image flash IMAGE DISK"
  fi
  local image=${positional[0]} disk=${positional[1]}
  if [ "$dry_run" -eq 0 ]; then
    [ -f "$image" ] || die "image not found: $image"
    validate_disk "$disk"
    confirm "Flash $image to $disk. EVERYTHING on $disk will be destroyed."
  fi
  do_flash "$image" "$disk"
}

cmd_install() {
  if [ "${#positional[@]}" -ne 1 ]; then
    die "usage: pi5-image install [options] TARGET"
  fi
  if [ -z "$host" ]; then
    die "--host is required"
  fi

  target=${positional[0]}
  mode=${mode:-mount}
  validate_mode
  if [ -n "$wipe_nvme" ] && [ "$mode" != "wipe" ]; then
    die "--wipe-nvme requires --mode wipe"
  fi

  if [ "$dry_run" -eq 0 ]; then
    check_installer_target
    if [ "$mode" = "wipe" ]; then
      confirm "Install '$host' onto $target in wipe mode. The target NVMe will be destroyed; the SD card is disposable."
    else
      confirm "Install '$host' onto $target in mount mode. Existing NVMe and SD content will be preserved."
    fi
  fi
  do_install
}

cmd_provision() {
  if [ "${#positional[@]}" -ne 2 ]; then
    die "usage: pi5-image provision [options] DISK TARGET"
  fi
  if [ -z "$host" ]; then
    die "--host is required"
  fi

  local disk=${positional[0]}
  target=${positional[1]}
  mode=${mode:-wipe}
  validate_mode
  if [ -n "$wipe_nvme" ] && [ "$mode" != "wipe" ]; then
    die "--wipe-nvme requires --mode wipe"
  fi

  if [ "$dry_run" -eq 1 ]; then
    validate_disk "$disk"
    log "would build ${flake}#nixosConfigurations.${installer}.config.system.build.sdImage"
    preview_flash "/path/to/sd-image.img.zst" "$disk" "4M"
    if [ "$no_wait" -eq 1 ]; then
      log "would stop after flashing (--no-wait)"
    else
      log "would wait up to ${wait_seconds}s for $target"
      do_install
    fi
    return 0
  fi

  validate_disk "$disk"
  confirm "Build installer '$installer', flash it to $disk (all data on it will be lost), then install '$host' on $target in ${mode} mode. Wipe mode also destroys the target NVMe; the SD card is disposable."
  local image
  image=$(build_image)
  log "SD image: $image"
  do_flash "$image" "$disk"
  log "SD card written. Insert it into the Pi, connect the NVMe, and power on."

  if [ "$no_wait" -eq 1 ]; then
    log "not waiting for the target (--no-wait); run pi5-image install when it is reachable"
    return 0
  fi

  wait_for_ssh
  check_installer_target
  do_install
}

command=${1:-}
case "$command" in
  build | flash | install | provision) shift ;;
  help | -h | --help | "")
    usage
    exit 0
    ;;
  *)
    usage >&2
    die "unknown command: $command"
    ;;
esac

while [ "$#" -gt 0 ]; do
  case "$1" in
    --flake)
      [ "$#" -ge 2 ] || die "--flake requires a value"
      flake=$2
      shift 2
      ;;
    --flake=*)
      flake=${1#*=}
      shift
      ;;
    --installer)
      [ "$#" -ge 2 ] || die "--installer requires a value"
      installer=$2
      shift 2
      ;;
    --host)
      [ "$#" -ge 2 ] || die "--host requires a value"
      host=$2
      shift 2
      ;;
    --mode)
      [ "$#" -ge 2 ] || die "--mode requires a value"
      mode=$2
      shift 2
      ;;
    --output | -o)
      [ "$#" -ge 2 ] || die "--output requires a value"
      output=$2
      shift 2
      ;;
    --ssh-key)
      [ "$#" -ge 2 ] || die "--ssh-key requires a value"
      ssh_key=$2
      shift 2
      ;;
    --ssh-port)
      [ "$#" -ge 2 ] || die "--ssh-port requires a value"
      ssh_port=$2
      shift 2
      ;;
    --ssh-option)
      [ "$#" -ge 2 ] || die "--ssh-option requires a value"
      ssh_options+=("$2")
      shift 2
      ;;
    --accept-flake-config)
      accept_flake_config=1
      shift
      ;;
    --allow-non-installer)
      allow_non_installer=1
      shift
      ;;
    --build-on)
      [ "$#" -ge 2 ] || die "--build-on requires a value"
      build_on=$2
      shift 2
      ;;
    --wait)
      [ "$#" -ge 2 ] || die "--wait requires a value"
      wait_seconds=$2
      shift 2
      ;;
    --wipe-nvme)
      [ "$#" -ge 2 ] || die "--wipe-nvme requires a value"
      wipe_nvme=$2
      shift 2
      ;;
    --no-wait)
      no_wait=1
      shift
      ;;
    --yes | -y)
      assume_yes=1
      shift
      ;;
    --dry-run | -n)
      dry_run=1
      shift
      ;;
    --force | -f)
      force=1
      shift
      ;;
    --)
      shift
      extra_args=("$@")
      break
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    -*)
      die "unknown option: $1"
      ;;
    *)
      positional+=("$1")
      shift
      ;;
  esac
done

case "$build_on" in
  auto | local | remote) ;;
  *) die "--build-on must be 'auto', 'local', or 'remote' (got: $build_on)" ;;
esac

case "$wait_seconds" in
  '' | *[!0-9]*) die "--wait must be a positive integer (got: $wait_seconds)" ;;
esac
if [ "$wait_seconds" -eq 0 ]; then
  die "--wait must be greater than zero"
fi

if [ -n "$ssh_key" ] && [ ! -f "$ssh_key" ]; then
  die "SSH key not found: $ssh_key"
fi

if [ -n "$ssh_port" ]; then
  case "$ssh_port" in
    '' | *[!0-9]*) die "--ssh-port must be an integer (got: $ssh_port)" ;;
  esac
  if [ "$ssh_port" -lt 1 ] || [ "$ssh_port" -gt 65535 ]; then
    die "--ssh-port must be between 1 and 65535 (got: $ssh_port)"
  fi
fi

if [ -z "$installer" ]; then
  die "--installer must not be empty"
fi

if [ "$command" != "build" ] && [ -n "$output" ]; then
  die "--output is only supported by build"
fi

work_dir=$(mktemp -d "${TMPDIR:-/tmp}/pi5-image.XXXXXX") \
  || die "cannot create a temporary directory"

case "$command" in
  build) cmd_build ;;
  flash) cmd_flash ;;
  install) cmd_install ;;
  provision) cmd_provision ;;
esac
