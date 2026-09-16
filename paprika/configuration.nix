{ config, pkgs, ... }:

{
  imports =
    [
      <nixos-hardware/lenovo/thinkpad/t480s>
      ../common-all/configuration.nix
      ../common-desktop/configuration.nix
      ../common-dev/programs/development.nix
      ../common-dev-desktop/configuration.nix
    ];

  system.stateVersion = "24.11";

  swapDevices = [{
    device = "/swapfile";
    size = 16 * 1024; # 16 GB
  }];

  # Docker, for the Overworld compose stack (Postgres, Redis, SeaweedFS, the
  # orchestrator and the Discord bot). No TCP listener, and enableOnBoot keeps
  # it off the boot path; the socket may still start it on demand.
  virtualisation.docker = {
    enable = true;
    enableOnBoot = false;
    listenOptions = [ "/run/docker.sock" ];
    daemon.settings.live-restore = true;
  };

  # The socket is root:docker 0660, so this group is what lets the Overworld
  # Makefile targets run without sudo. Deliberate exception to the note on
  # extraGroups in ../common-all/configuration.nix, which is right about the
  # cost — it is control equivalent to root over the engine.
  users.users.${config.mainUser}.extraGroups = [ "docker" ];

  time.timeZone = "Asia/Tokyo";
  networking.hostName = "paprika";
  philpax.syncthing.device = "paprika";
}
