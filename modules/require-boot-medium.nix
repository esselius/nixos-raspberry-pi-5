{
  lib,
  options,
  ...
}:
{
  # The base stack is composed in flake.nix from `hardware` + `storage` +
  # `impermanence`; this file only enforces the choice it leaves open. There is
  # no default boot path: import one of the two full stacks
  #
  #   nixosModules.sd-boot    - SD card owns firmware + U-Boot + /boot
  #   nixosModules.nvme-boot  - NVMe owns firmware + U-Boot + /boot
  #
  # or add nixosModules.boot-sd / nixosModules.boot-nvme when composing
  # yourself. Both boot paths are first-class; neither is implicit.
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
