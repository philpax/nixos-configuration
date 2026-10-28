# Steam Frame: SteamOS with Nix and system-manager. Shared layers come in
# through their portable.nix; ./steamos.nix supplies the NixOS options they use.
{ config, pkgs, ... }:

{
  imports =
    [
      ./steamos.nix
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

  # Desktop Mode in the headset view.
  environment.etc = {
    # KWin draws the cursor on a hardware plane the headset view does not show.
    "environment.d/90-kwin-software-cursor.conf".text = ''
      KWIN_FORCE_SW_CURSOR=1
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
  };

  # The SteamOS kernel lacks hidp and hid_magicmouse, so the Magic Trackpad 2
  # needs this userspace driver; pairing is in its README.
  systemd.user.services.mt2-driver = {
    description = "Magic Trackpad 2 userspace multitouch driver";
    wantedBy = [ "default.target" ];
    serviceConfig = {
      Type = "exec";
      ExecStart = "${pkgs.python3}/bin/python3 ${./magic-trackpad-2-linux-userspace/mt2_driver.py}";
      Restart = "on-failure";
      RestartSec = 5;
    };
  };
}
