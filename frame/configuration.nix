# Steam Frame: SteamOS with Nix and system-manager. Shared layers come in
# through their portable.nix; ./steamos.nix supplies the NixOS options they use.
{ config, pkgs, ... }:

let
  cursorPython = pkgs.python3.withPackages (python: [ (python.python-xlib or python.xlib) ]);
  gamescopeScroll = pkgs.writeShellScriptBin "gamescope" ''
    exec /usr/bin/gamescope --vr-scroll-speed 0.25 "$@"
  '';
in
{
  imports =
    [
      ./steamos.nix
      ./niri.nix
      ../common-all/portable.nix
      ../common-dev/portable.nix
      ../common-desktop/portable.nix
      ../common-dev-desktop/portable.nix
    ];

  mainUser = "steamos";
  philpax.syncthing.device = "frame";
  # SteamOS gives each account a group of the same name, rather than `users`.
  services.syncthing.group = config.mainUser;
  networking.firewall.allowedTCPPorts = pkgs.lib.mkForce [ ];
  networking.firewall.allowedUDPPorts = pkgs.lib.mkForce [ ];

  hardware.graphics.enable = true;

  environment.etc = {
    # Read by `./deploy.sh --status`, the counterpart of NixOS's
    # /run/current-system/nixos-version.
    "frame/nixpkgs-version".text = pkgs.lib.version;

    # Desktop Mode in the headset view.
    # KWin draws the cursor on a hardware plane the headset view does not show.
    "environment.d/90-kwin-software-cursor.conf".text = ''
      KWIN_FORCE_SW_CURSOR=1
    '';
    "systemd/user/gamescope-session.service.d/scroll.conf".text = ''
      [Service]
      Environment="PATH=${gamescopeScroll}/bin:/run/wrappers/bin:/run/system-manager/sw/bin:${config.users.users.${config.mainUser}.home}/.nix-profile/bin:/nix/var/nix/profiles/default/bin:/etc/profiles/per-user/${config.mainUser}/bin:/usr/local/sbin:/usr/local/bin:/usr/bin"
    '';
    # KWin starts with gamescope's 256 px cursor; reapply the kcminputrc size,
    # defaulting to 24 px.
    "xdg/autostart/frame-cursor-size.desktop".text = ''
      [Desktop Entry]
      Type=Application
      Name=Frame cursor size
      Exec=/bin/sh -c "kreadconfig6 --file kcminputrc --group Mouse --key cursorSize | grep -q . || kwriteconfig6 --file kcminputrc --group Mouse --key cursorSize 24; exec dbus-send --session --type=signal /KGlobalSettings org.kde.KGlobalSettings.notifyChange int32:5 int32:0"
      OnlyShowIn=KDE;
      X-KDE-autostart-phase=2
      NoDisplay=true
    '';
    # Hide gamescope's X cursor only on KWin's nested output window.
    "xdg/autostart/frame-host-cursor.desktop".text = ''
      [Desktop Entry]
      Type=Application
      Name=Frame KDE host cursor
      Exec=${cursorPython}/bin/python3 ${./hide-kde-host-cursor.py} --display :0
      OnlyShowIn=KDE;
      X-KDE-autostart-phase=2
      NoDisplay=true
    '';
  };

  # Nightly upgrade, matching system.autoUpgrade on the NixOS machines: update
  # root's channels, then rebuild from the checkout. system-manager's own
  # system.autoUpgrade only supports flakes.
  systemd.services.frame-upgrade = {
    description = "Update channels and switch Frame's system-manager configuration";
    restartIfChanged = false;
    unitConfig.X-StopOnRemoval = false;
    serviceConfig.Type = "oneshot";
    script = ''
      export PATH=/nix/var/nix/profiles/default/bin:/usr/bin:$PATH
      nix-channel --update nixos system-manager
      ${config.users.users.${config.mainUser}.home}/nixos-configuration/frame/rebuild.sh switch
    '';
    startAt = "04:40";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
  };
  systemd.timers.frame-upgrade.timerConfig.Persistent = true;

  # The SteamOS kernel lacks hidp and hid_magicmouse, so the Magic Trackpad 2
  # needs this userspace driver; pairing is in its README.
  systemd.user.services.mt2-driver = {
    description = "Magic Trackpad 2 userspace multitouch driver";
    wantedBy = [ "default.target" ];
    serviceConfig = {
      Type = "exec";
      ExecStart = "${pkgs.python3}/bin/python3 ${./magic-trackpad-2-linux-userspace/mt2_driver.py} --swipe-navigation";
      Restart = "on-failure";
      RestartSec = 5;
    };
  };
}
