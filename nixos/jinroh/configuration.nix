{ config, pkgs, ... }:

{
  imports =
    [
      ../common-all/configuration.nix
      ../common-desktop/configuration.nix
    ];

  system.stateVersion = "24.11";

  networking.hostName = "jinroh";

  # KDE Plasma Desktop Environment
  services.desktopManager.plasma6.enable = true;

  # Blackbird compilation
  environment.systemPackages = with pkgs; [
    rustup
    clang
    lld
    pkg-config
  ];

  users.users.philpax.packages = with pkgs; [
    kdePackages.kate
  ];

  # Enable automatic login for the user.
  services.displayManager.autoLogin.enable = true;
  services.displayManager.autoLogin.user = "philpax";
}
