#!/usr/bin/env bash
# Reset the btrfs root subvolume to a pristine empty state in the initrd.
# The Nix wrapper sets root_device and root_subvolume before sourcing this file.
# shellcheck disable=SC2154
set -eux

for _ in $(seq 1 200); do
  [ -e "$root_device" ] && break
  sleep 0.05
done
udevadm settle --timeout=10 || true

mkdir -p /btrfs_tmp
# subvol=/ is required: mounting the filesystem's default subvolume would make
# @root resolve inside that subvolume instead of at the top level.
mount -o subvol=/,nodiscard "$root_device" /btrfs_tmp

target=/btrfs_tmp/$root_subvolume
children_file=/run/pi5-root-wipe-children.txt

if [ -e "$target" ]; then
  btrfs property set "$target" ro false 2>/dev/null || true

  # btrfs lists children parent-first, which is the wrong order for deletion.
  # Repeat passes: each pass deletes the currently deletable leaves until no
  # more progress is made.
  btrfs subvolume list -o "$target" >"$children_file"
  while [ -s "$children_file" ]; do
    removed=0
    while read -r line; do
      subvolume="${line#* path }"
      [ -n "$subvolume" ] || continue
      btrfs property set "/btrfs_tmp/$subvolume" ro false 2>/dev/null || true
      if btrfs subvolume delete "/btrfs_tmp/$subvolume"; then
        removed=1
      fi
    done <"$children_file"
    [ "$removed" -eq 1 ] || break
    btrfs subvolume list -o "$target" >"$children_file"
  done

  btrfs subvolume delete "$target"
fi
btrfs subvolume create "$target"

umount /btrfs_tmp
rmdir /btrfs_tmp
