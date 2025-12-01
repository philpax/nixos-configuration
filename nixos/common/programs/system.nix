{ config, pkgs, ... }:

{
  environment.systemPackages = with pkgs; [
    # Basic system tools
    wget
    fastfetch
    screen
    jq
    parallel

    # File system tools
    parted
    ntfs3g
    p7zip
    btrfs-progs

    # System monitoring
    lm_sensors

    # Misc
    xdg-utils
  ];

  programs.nix-ld.enable = true;
}
