# Implements, on SteamOS through system-manager, the NixOS options that the
# shared layers use, so each layer's portable.nix means the same thing on Frame
# as on the NixOS machines. Options are declared only as far as the layers need
# them; anything else fails evaluation rather than being silently ignored.
{ config, lib, pkgs, utils, nixosModulesPath, ... }:
let
  inherit (lib) mkEnableOption mkIf mkOption types;
  user = config.mainUser;

  # system-manager has no user units, so render systemd.user.services with the
  # NixOS unit types and install them under /etc/systemd/user.
  userUnits =
    (lib.evalModules {
      modules = [
        ({ config, ... }: {
          options.services = mkOption { type = utils.systemdUtils.types.services; default = { }; };
          options.units = mkOption { type = utils.systemdUtils.types.units; default = { }; };
          config.units = lib.mapAttrs' (name: service:
            lib.nameValuePair "${name}.service" (utils.systemdUtils.lib.serviceToUnit service)
          ) config.services;
        })
        { services = config.systemd.user.services; }
      ];
    }).config.units;
  enabledUserUnits = lib.filterAttrs (_: unit: unit.enable) userUnits;
  userUnitFiles = lib.concatMapAttrs (name: unit:
    { "systemd/user/${name}".source = "${unit.unit}/${name}"; }
    // lib.listToAttrs (map (target:
      lib.nameValuePair "systemd/user/${target}.wants/${name}" { source = "${unit.unit}/${name}"; }
    ) unit.wantedBy)
  ) enabledUserUnits;

  fontAliases = lib.concatStrings (lib.mapAttrsToList (name: families:
    let generic = { sansSerif = "sans-serif"; }.${name} or name; in
    "  <alias><family>${generic}</family><prefer>"
    + lib.concatMapStrings (family: "<family>${family}</family>") families
    + "</prefer></alias>\n"
  ) config.fonts.fontconfig.defaultFonts);
  fontconfigFile = pkgs.writeText "52-nixos-default-fonts.conf" (''
    <?xml version="1.0"?>
    <!DOCTYPE fontconfig SYSTEM "urn:fontconfig:fonts.dtd">
    <fontconfig>
      <dir>/run/current-system/sw/share/fonts</dir>
  '' + fontAliases + ''
    </fontconfig>
  '');

  # NixOS gives every shell and session the same environment. system-manager
  # writes it, including environment.extraInit, only to profile.d, which login
  # shells read but sessions started by the user manager do not. This generator
  # sources the Nix-owned profile scripts for the user manager and emits what
  # they change; SteamOS's own profile.d stays out of the session.
  profileEnvironmentGenerator = pkgs.writeScript "60-nix-profile" ''
    #!${pkgs.bash}/bin/bash
    declare -A before
    while IFS= read -r -d "" entry; do before[''${entry%%=*}]=''${entry#*=}; done < <(env -0)
    for script in /etc/profile.d/nix-daemon.sh /etc/profile.d/system-manager-path.sh; do
      [ -r "$script" ] && . "$script"
    done
    # The profile scripts prepend unconditionally; keep each entry once.
    for list in PATH XDG_DATA_DIRS; do
      [[ -v $list ]] || continue
      value=$(printf %s "''${!list}" | ${pkgs.gawk}/bin/awk -v RS=: -v ORS=: 'NF && !seen[$0]++')
      export "$list=''${value%:}"
    done
    while IFS= read -r -d "" entry; do
      name=''${entry%%=*} value=''${entry#*=}
      case $name in _ | SHLVL | PWD | OLDPWD) continue ;; esac
      [[ -v before[$name] && ''${before[$name]} == "$value" ]] && continue
      value=''${value//\\/\\\\} value=''${value//\"/\\\"}
      value=''${value//\$/\\\$} value=''${value//\`/\\\`}
      printf '%s="%s"\n' "$name" "$value"
    done < <(env -0)
  '';
in
{
  imports = [ (nixosModulesPath + "/services/networking/syncthing.nix") ];

  options = {
    programs.fish.enable = mkEnableOption "fish, continuing interactive logins in it";

    fonts.packages = mkOption {
      type = types.listOf types.package;
      default = [ ];
      description = "Fonts linked into the system profile and registered with the host's Fontconfig.";
    };
    fonts.fontconfig.defaultFonts = mkOption {
      type = types.attrsOf (types.listOf types.str);
      default = { };
      description = "Preferred families per generic name (monospace, sansSerif, serif, emoji).";
    };

    # Read by the NixOS Syncthing module; SteamOS has no system-wide proxy.
    networking.proxy.envVars = mkOption {
      type = types.attrsOf types.str;
      default = { };
      internal = true;
    };

    hardware.graphics = {
      enable = mkEnableOption "Nix-built GL and Vulkan drivers at /run/opengl-driver";
      package = mkOption {
        type = types.package;
        default = pkgs.mesa;
        description = "Driver package; SteamOS's own Mesa links against host libraries Nix programs can't load.";
      };
      extraPackages = mkOption {
        type = types.listOf types.package;
        default = [ ];
      };
    };
  };

  config = lib.mkMerge [
    {
      nixpkgs.hostPlatform = "aarch64-linux";
      # SteamOS is Arch-based; system-manager only allows Ubuntu, Debian and NixOS.
      system-manager.allowAnyDistro = true;
      # SteamOS owns the accounts; frame/bootstrap.sh creates the Nix build users.
      services.userborn.enable = false;
      # Gives modules the account's home directory; nothing else consumes it
      # while userborn is off.
      users.users.${user}.isNormalUser = true;

      environment.etc = userUnitFiles // {
        "systemd/user-environment-generators/60-nix-profile".source = profileEnvironmentGenerator;
      };

      # User managers read /etc/systemd/user only on reload. This reruns whenever
      # the rendered units change, including when system-manager reactivates at
      # boot after an OS update has removed them.
      systemd.services.reload-user-units = {
        description = "Reload ${user}'s systemd manager for system-manager user units";
        wantedBy = [ "system-manager.target" ];
        restartTriggers = lib.mapAttrsToList (_: file: file.source) userUnitFiles;
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        # SteamOS has no systemd-machined, so `systemctl --machine` cannot
        # reach the user manager; talk to its bus directly instead.
        script = ''
          runtime=/run/user/$(id -u ${user})
          [ -S "$runtime/bus" ] || exit 0
          manager() {
            ${pkgs.util-linux}/bin/runuser -u ${user} -- env XDG_RUNTIME_DIR="$runtime" \
              DBUS_SESSION_BUS_ADDRESS="unix:path=$runtime/bus" systemctl --user "$@"
          }
          manager daemon-reload
          manager start default.target
        '';
      };
    }

    (mkIf config.programs.ssh.startAgent {
      programs.ssh.enable = true;
      # Same unit as nixos/modules/programs/ssh.nix.
      systemd.user.services.ssh-agent = {
        description = "SSH Agent";
        wantedBy = [ "default.target" ];
        unitConfig.ConditionUser = "!@system";
        serviceConfig = {
          ExecStartPre = "${pkgs.coreutils}/bin/rm -f %t/ssh-agent";
          ExecStart = "${config.programs.ssh.package}/bin/ssh-agent -a %t/ssh-agent";
          StandardOutput = "null";
          Type = "forking";
          Restart = "on-failure";
          SuccessExitStatus = "0 2";
        };
      };
    })

    (mkIf config.programs.fish.enable {
      environment.systemPackages = [ pkgs.fish ];
      # SteamOS's login shell stays bash, so a missing /nix never locks anyone
      # out. Interactive login shells continue in fish, like the NixOS machines.
      environment.etc."profile.d/zz-fish.sh".text = ''
        case $- in *i*) ;; *) return ;; esac
        if [ -t 0 ] && [ -x /run/current-system/sw/bin/fish ]; then
          exec /run/current-system/sw/bin/fish --login
        fi
      '';
      # SHELL still names bash, the login shell, so programs that start a shell
      # (zellij, editors) would open bash. nixpkgs fish sources this file.
      environment.etc."fish/config.fish".text = ''
        set -gx SHELL /run/current-system/sw/bin/fish
      '';
    })

    (mkIf (config.fonts.packages != [ ]) {
      environment.systemPackages = config.fonts.packages;
      # Read by SteamOS's Fontconfig and by Nix-built programs alike.
      environment.etc."fonts/conf.d/52-nixos-default-fonts.conf".source = fontconfigFile;
    })

    (mkIf config.hardware.graphics.enable {
      systemd.tmpfiles.rules = [
        "L+ /run/opengl-driver - - - - ${pkgs.buildEnv {
          name = "graphics-drivers";
          paths = [ config.hardware.graphics.package ] ++ config.hardware.graphics.extraPackages;
        }}"
      ];
    })
  ];
}
