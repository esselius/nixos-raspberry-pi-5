{
  lib,
  options,
  ...
}:
{
  # The full stack minus a boot medium. The boot path is an explicit choice:
  # import one of
  #
  #   nixosModules.sd-boot    - SD card owns firmware + U-Boot + /boot
  #   nixosModules.nvme-boot  - NVMe owns firmware + U-Boot + /boot
  #
  # The convenience wrappers `default-sd-boot` and `default-nvme-boot` combine
  # this stack with the matching boot module. Both boot paths are first-class;
  # neither is implicit.
  #
  # Snapper is deliberately not enabled here: snapshots are a site policy, not
  # a hardware requirement. Set pi5.impermanence.snapshots.enable = true in the
  # host/project layer if you want them.
  imports = [
    ./raspberry-pi-5.nix
    ./nvme-root.nix
    ./impermanence.nix
  ];

  assertions = [
    {
      assertion = options.pi5 ? sdBoot || options.pi5 ? nvmeBoot;
      message = ''
        pi5.nixosModules.default no longer selects a boot medium. Import
        nixosModules.sd-boot or nixosModules.nvme-boot, or use the full-stack
        wrappers nixosModules.default-sd-boot / nixosModules.default-nvme-boot.
      '';
    }
  ];
}
