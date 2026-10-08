{ nixpkgs, checkout }:
let
  host = import (builtins.toPath nixpkgs + "/nixos") {};
  inherit (host) config pkgs;
  lib = pkgs.lib;
  output = package: {
    name = package.name;
    outputName = package.outputName or "out";
    path = toString package;
  };
  outputs = packages:
    if builtins.length packages > 2048 then
      throw "Current-host package summary exceeds its bound"
    else map output packages;
  module = path: import (builtins.toPath checkout + path) {
    inherit config pkgs lib;
  };
  packageModules = [
    "/common-all/programs/system.nix"
    "/common-all/programs/development.nix"
    "/common-all/programs/network.nix"
    "/common-all/programs/media.nix"
    "/common-all/programs/helix.nix"
    "/common-dev/programs/development.nix"
  ];
  desktop = module "/common-desktop/configuration.nix";
in
assert lib.assertMsg (builtins.all (item: item.assertion) config.assertions)
  "Current-host NixOS assertions failed";
{
  hostname = config.networking.hostName;
  system = pkgs.stdenv.hostPlatform.system;
  assertionsPassed = true;
  drvPath = config.system.build.toplevel.drvPath;
  affectedPackages = builtins.listToAttrs (map (path: {
    name = path;
    value = outputs (module path).environment.systemPackages;
  }) packageModules);
  systemPackages = outputs config.environment.systemPackages;
  fonts = {
    explicitPackages = outputs desktop.fonts.packages;
    effectivePackages = outputs config.fonts.packages;
    inherit (config.fonts) enableDefaultPackages;
    inherit (config.fonts.fontconfig) enable defaultFonts;
  };
  settings = {
    shell = {
      fish = config.programs.fish.enable;
      nixLd = config.programs.nix-ld.enable;
      nixLdPackage = output config.programs.nix-ld.package;
      nixLdLibraries = outputs config.programs.nix-ld.libraries;
      sshStartAgent = config.programs.ssh.startAgent;
      defaultShell = toString config.users.defaultUserShell;
      mainUserShell = toString config.users.users.${config.mainUser}.shell;
      shells = map toString config.environment.shells;
    };
    services = {
      inherit (config.services.tailscale) enable useRoutingFeatures;
      sddm = config.services.displayManager.sddm.enable;
      pulseaudio = config.services.pulseaudio.enable;
      pipewire = config.services.pipewire.enable;
      pipewireAlsa = config.services.pipewire.alsa.enable;
      pipewireAlsa32 = config.services.pipewire.alsa.support32Bit;
      pipewirePulse = config.services.pipewire.pulse.enable;
      printing = config.services.printing.enable;
      printingPackage = output config.services.printing.package;
      avahi = config.services.avahi.enable;
      avahiMdns4 = config.services.avahi.nssmdns4;
      networkmanager = config.networking.networkmanager.enable;
      rtkit = config.security.rtkit.enable;
      firefox = config.programs.firefox.enable;
    };
    firewall = {
      inherit (config.networking.firewall)
        enable allowedTCPPorts allowedUDPPorts allowedTCPPortRanges
        allowedUDPPortRanges trustedInterfaces checkReversePath;
    };
  };
}
