# Example host for the full stack. Replace the hostname, SSH key, and any
# service-specific settings with your own.
{
  networking.hostName = "pi5-example";
  system.stateVersion = "26.05";

  # Minimal remote access for the example. On an impermanent system, users are
  # declarative and /etc/passwd is rebuilt at boot; mutableUsers = false keeps
  # runtime useradd/passwd changes from appearing to work until the next boot.
  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
      PermitRootLogin = "no";
    };
  };

  security.sudo.wheelNeedsPassword = false;
  users.mutableUsers = false;

  users.users.admin = {
    isNormalUser = true;
    description = "admin";
    extraGroups = [ "wheel" ];
    openssh.authorizedKeys.keys = [
      # Test-only key; the private half was discarded, so this example host is
      # intentionally unreachable. Replace it with your own public key.
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPVIgmsKXn3UwSmCQ7r0GnIKQ9rxh14VzYm4gtUHhaWi pi5-demo-test-only-no-private-key-retained"
    ];
  };
}
