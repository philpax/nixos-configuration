{ config, pkgs, ... }:

{
  environment.systemPackages = with pkgs; [
    # Basic system tools
    wget
    fastfetch
    screen
    jq

    # File system tools
    ntfs3g
    p7zip

    # System monitoring
    lm_sensors

    # Misc
    xdg-utils
  ];

  programs.nix-ld.enable = true;
}
