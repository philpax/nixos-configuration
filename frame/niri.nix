# A nested desktop application, not a replacement for SteamOS's compositor.
{ config, lib, pkgs, ... }:
let
  python = pkgs.python3.withPackages (python: [ python.python-xlib ]);
  quickshell = builtins.head (builtins.filter
    (package: (package.pname or "") == "quickshell") config.environment.systemPackages);
  tools = with pkgs; [
    niri xwayland-satellite fuzzel mako swaybg volantes-cursors
    wl-clipboard playerctl libnotify jq brightnessctl pavucontrol
    networkmanagerapplet procps lm_sensors curl duf
  ];
  startup = pkgs.writeShellScript "frame-niri-startup" ''
    ${python}/bin/python3 ${./niri-host-cursor.py} &
    ${quickshell}/bin/qs -p ${../common-dev-desktop/dotfiles/.config/quickshell} &
    ${pkgs.mako}/bin/mako &
    wallpaper="$HOME/wallpapers/16x9/Half_Life_2_Episode_Three_concept_2.jpg"
    if [ -r "$wallpaper" ]; then
      ${pkgs.swaybg}/bin/swaybg -i "$wallpaper" -m fill &
    else
      ${pkgs.swaybg}/bin/swaybg -c '#202020' &
    fi
  '';
  sharedConfig = ../common-dev-desktop/dotfiles/.config/niri/config.kdl;
  niriConfig = pkgs.runCommand "frame-niri-config.kdl" { nativeBuildInputs = [ pkgs.python3 ]; } ''
    python3 ${./niri_config.py} ${sharedConfig} "$out" ${startup}
  '';
  launcher = pkgs.writeShellScriptBin "frame-niri" ''
    export PATH=${lib.makeBinPath tools}:/run/system-manager/sw/bin:/usr/bin:$PATH
    export XDG_DATA_DIRS=${pkgs.volantes-cursors}/share:/run/system-manager/sw/share:/usr/local/share:/usr/share:''${XDG_DATA_DIRS:-}
    export XCURSOR_PATH=${pkgs.volantes-cursors}/share/icons:/usr/share/icons
    # The upstream package's nested X11 backend loads these libraries at runtime.
    export LD_LIBRARY_PATH=${lib.makeLibraryPath (with pkgs; [
      libX11 libXcursor libXrandr libXi libXinerama libXxf86vm libxcb libxkbcommon
    ])}:''${LD_LIBRARY_PATH:-}
    exec ${python}/bin/python3 ${./niri-launch.py} \
      --niri ${pkgs.niri}/bin/niri \
      --dbus-run-session ${pkgs.dbus}/bin/dbus-run-session \
      --config ${niriConfig}
  '';
  desktop = pkgs.makeDesktopItem {
    name = "frame-niri";
    desktopName = "Niri Desktop";
    comment = "Open a nested niri desktop inside gamescope";
    exec = "${launcher}/bin/frame-niri";
    icon = "preferences-desktop";
    categories = [ "Utility" ];
    extraConfig.X-Steam-Controller-Template = "Desktop";
  };
in
{
  imports = [ ../common-dev-desktop/quickshell.nix ];
  environment.systemPackages = tools ++ [ launcher desktop ];
}
