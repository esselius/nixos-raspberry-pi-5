{
  lib,
  stdenv,
  writeShellApplication,
  nixos-anywhere,
  zstd,
  openssh,
  util-linux,
  coreutils,
  gawk,
  gnused,
  gnugrep,
}:
writeShellApplication {
  name = "pi5-image";
  runtimeInputs = [
    nixos-anywhere
    zstd
    openssh
  ]
  ++ lib.optional stdenv.hostPlatform.isLinux util-linux;
  text = builtins.readFile ../scripts/pi5-image.sh;
  meta = {
    description = "Build, flash, and install NixOS on a Raspberry Pi 5 with an NVMe root";
    mainProgram = "pi5-image";
    platforms = lib.platforms.darwin ++ lib.platforms.linux;
  };
}
