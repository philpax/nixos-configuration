{ pkgs, ... }:
let
  # Moonshine (github.com/hgaiser/moonshine): a headless Moonlight/GameStream
  # server. Each stream runs in its own isolated Wayland/Vulkan compositor, and a
  # Vulkan WSI layer (registered below) routes each game's frames into it.
  moonshine = pkgs.callPackage ../moonshine/package.nix { };

  user = "philpax";
  configFile = "/home/${user}/.config/moonshine/config.toml";

  # The unit runs as `user` via User=, but Moonshine launches game sessions
  # through the user's systemd instance (systemd-run --user over D-Bus), so it
  # needs XDG_RUNTIME_DIR / the session bus address resolved for that user.
  # Linger (below) keeps that instance alive with no interactive login.
  startMoonshine = pkgs.writeShellApplication {
    name = "start-moonshine";
    runtimeInputs = [ pkgs.coreutils moonshine ];
    text = ''
      uid="$(id -u)"
      export XDG_RUNTIME_DIR="''${XDG_RUNTIME_DIR:-/run/user/$uid}"
      export DBUS_SESSION_BUS_ADDRESS="''${DBUS_SESSION_BUS_ADDRESS:-unix:path=$XDG_RUNTIME_DIR/bus}"
      if [ ! -d "$XDG_RUNTIME_DIR" ]; then
        echo "moonshine: $XDG_RUNTIME_DIR missing — is linger enabled for $(id -un)?" >&2
        exit 1
      fi
      exec moonshine "$@"
    '';
  };
in
{
  # Keep the user's systemd user instance running without an interactive login,
  # so Moonshine can spawn game sessions on a headless (not-logged-in) machine.
  users.users.${user}.linger = true;

  systemd.services.moonshine = {
    description = "Moonshine — headless Moonlight/GameStream streaming server";
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    # Log both crates: the server's actual logic lives in moonshine_core, not the
    # thin `moonshine` bin crate.
    environment.MOONSHINE_LOG = "moonshine=info,moonshine_core=info";
    serviceConfig = {
      User = user;
      Group = "users";
      SupplementaryGroups = [ "input" "video" "render" ];
      ExecStart = "${startMoonshine}/bin/start-moonshine ${configFile}";
      Restart = "always";
      RestartSec = 3;
      # inputtino virtual devices + GPU nodes for the Vulkan encode/compositor.
      DeviceAllow = [
        "/dev/uinput rw"
        "/dev/uhid rw"
        "char-drm rw"
        "char-nvidia rw"
        "char-nvidia-uvm rw"
      ];
    };
  };

  # Virtual input devices (inputtino): gamepad (incl. motion/touchpad/haptics),
  # keyboard and mouse injection from the Moonlight client.
  hardware.uinput.enable = true;
  boot.kernelModules = [ "uhid" ];
  services.udev.extraRules = ''
    KERNEL=="uinput", SUBSYSTEM=="misc", OPTIONS+="static_node=uinput", TAG+="uaccess", GROUP="input", MODE="0660"
    KERNEL=="uhid", TAG+="uaccess", GROUP="input", MODE="0660"
    SUBSYSTEM=="hidraw", KERNELS=="uhid", TAG+="uaccess", GROUP="input", MODE="0660"
    SUBSYSTEMS=="input", ATTRS{name}=="Moonshine *", TAG+="uaccess", GROUP="input", MODE="0660"
  '';

  # Register the Moonshine Vulkan WSI layer. It is gated by ENABLE_MOONSHINE_WSI=1,
  # which Moonshine sets only in the environment of apps it streams, so the layer
  # is inert for every other Vulkan program on the system. /etc/vulkan is scanned
  # by the loader unconditionally (independent of XDG_DATA_DIRS), which matters in
  # the lingering headless session where XDG_DATA_DIRS may be minimal.
  environment.etc."vulkan/implicit_layer.d/VkLayer_moonshine_wsi.json".source =
    "${moonshine}/share/vulkan/implicit_layer.d/VkLayer_moonshine_wsi.json";

  # GameStream / Moonlight: TCP 47989 (HTTP) + 47984 (HTTPS) webserver, 48010 RTSP;
  # UDP 47998 video, 47999 control, 48000 audio.
  networking.firewall = {
    allowedTCPPorts = [ 47984 47989 48010 ];
    allowedUDPPorts = [ 47998 47999 48000 ];
  };

  environment.systemPackages = [ moonshine ];
}
