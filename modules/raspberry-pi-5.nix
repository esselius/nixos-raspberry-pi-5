{ lib, pkgs, ... }:
{
  # Raspberry Pi 5 hardware support. The flake's `raspberry-pi-5` module wrapper
  # imports `nixos-hardware.nixosModules.raspberry-pi-5`; this file only adds
  # the two fixes that profile still needs.
  assertions = [
    {
      assertion = pkgs.stdenv.hostPlatform.isAarch64;
      message = "The Raspberry Pi 5 modules require an aarch64-linux NixOS system.";
    }
  ];

  nixpkgs.overlays = [
    (final: prev: {
      # The vendor `linux-rpi` kernel does not build every module the
      # raspberry-pi-5 profile's initrd asks for (for example `tpm-crb`).
      # Without `allowMissing`, the initrd closure fails outright on the first
      # missing module instead of skipping it. This is not a side effect of
      # hardware.enableAllHardware (which is false here).
      makeModulesClosure = x: prev.makeModulesClosure (x // { allowMissing = true; });
    })
  ];

  hardware.raspberry-pi.firmware = {
    # Refresh /boot/firmware on every switch (firmware, DTBs, overlays,
    # config.txt, u-boot.bin). The sd-image build wires the same installer at
    # image-build time, where it is forced regardless of this option.
    enable = lib.mkDefault true;
    uboot.enable = lib.mkDefault true;
  };

  # The nixos-hardware profile defaults to the vendor kernel on purpose. Do not
  # override boot.kernelPackages with mainline here: mainline + the vendor
  # firmware DTBs produced `rp1_driver -22` (EINVAL) probe failures on real
  # hardware, killing both USB and Ethernet. If you want mainline, test RP1
  # and NVMe on your own board first.
}
