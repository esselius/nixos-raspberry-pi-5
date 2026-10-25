{ lib, ... }:
{
  imports = [
    ./raspberry-pi-5.nix
    ./nvme-root.nix
    ./sd-boot.nix
    ./impermanence.nix
  ];

  # Snapshot the persisted state on the reference hosts. The granular
  # impermanence module leaves this off by default; the full stack turns it on.
  pi5.impermanence.snapshots.enable = lib.mkDefault true;
}
