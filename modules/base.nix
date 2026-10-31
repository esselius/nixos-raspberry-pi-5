{
  lib,
  options,
  ...
}:
{
  # Everything except a boot medium. There is no default boot path: import one
  # of the two full stacks
  #
  #   nixosModules.sd-boot    - SD card owns firmware + U-Boot + /boot
  #   nixosModules.nvme-boot  - NVMe owns firmware + U-Boot + /boot
  #
  # or compose this file with nixosModules.boot-sd / nixosModules.boot-nvme
  # yourself. Both boot paths are first-class; neither is implicit.
  #
  # Snapper is deliberately not enabled here: snapshots are a site policy, not
  # a hardware requirement. Set pi5.impermanence.snapshots.enable = true in the
  # host/project layer if you want them.
  imports = [
    ./raspberry-pi-5.nix
    ./storage.nix
    ./impermanence.nix
  ];

  assertions = [
    {
      assertion = options.pi5 ? sdBoot || options.pi5 ? nvmeBoot;
      message = ''
        The base pi5 stack does not select a boot medium. Import
        nixosModules.sd-boot or nixosModules.nvme-boot (the full stacks), or add
        nixosModules.boot-sd / nixosModules.boot-nvme when composing yourself.
      '';
    }
  ];
}
