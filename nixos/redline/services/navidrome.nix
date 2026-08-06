{ config, lib, pkgs, ... }:

let
  folders = import ../folders.nix;
  audiomuseSecrets = import ../secrets/audiomuse.nix;

  # Vendored from nixpkgs unstable (pkgs/by-name/na/navidrome/plugins/audiomuseai/
  # package.nix) — the current channel snapshot has navidromePlugins and its
  # build-plugin helper (byte-identical to unstable's) but not this plugin yet.
  # Drop this and use pkgs.navidromePlugins.audiomuseai once the channel catches up.
  audiomuseaiPlugin = pkgs.navidromePlugins.build-plugin rec {
    pname = "audiomuseai";
    version = "8";

    src = pkgs.fetchFromGitHub {
      owner = "NeptuneHub";
      repo = "AudioMuse-AI-NV-plugin";
      tag = "v${version}";
      hash = "sha256-WyobjyadD9IcY6mFYhCmuQgLbnoHpDoiLfINNfKmQM8=";
    };

    vendorHash = "sha256-mXes+doBSa5kcfHp1cuzTz30wnyyPN7NLC0iOSL8FDo=";

    meta = {
      description = "Navidrome plugin that integrates core AudioMuse-AI features into the Navidrome frontend.";
      homepage = "https://github.com/NeptuneHub/AudioMuse-AI-NV-plugin";
      license = lib.licenses.agpl3Only;
    };
  };

  # Mirror of the invocation the navidrome module's ExecStart uses: same binary,
  # and an identically-generated settings file (same generator, name and content
  # → same store path). The module runs the server chrooted with
  # WorkingDirectory=/var/lib/navidrome and no DataFolder setting, so the DB
  # lives in that directory; the oneshots below reproduce the working directory
  # (unchrooted) and reach the same database.
  settingsFormat = pkgs.formats.json { };
  navidromeCli = pkgs.writeShellScript "navidrome-cli" ''
    exec ${lib.getExe config.services.navidrome.finalPackage} \
      --configfile ${settingsFormat.generate "navidrome.json" config.services.navidrome.settings} "$@"
  '';

  # navidrome.service is Type=simple, so After= only orders on exec, not on the
  # DB being migrated — and the CLI subcommands below open the same SQLite DB
  # but never run migrations themselves. Poll the HTTP endpoint: navidrome only
  # binds the port after db.Init() completes, so "port answers" ⇒ "DB ready".
  # Same lesson as the immich-stacker readiness poll in immich.nix.
  waitForNavidrome = ''
    echo "Waiting for navidrome at 127.0.0.1:4533 ..."
    i=0
    until ${pkgs.curl}/bin/curl -fsS --max-time 5 \
        "http://127.0.0.1:4533/ping" >/dev/null 2>&1; do
      i=$((i + 1))
      if [ "$i" -ge 60 ]; then
        echo "ERROR: navidrome did not become ready within 60s"
        exit 1
      fi
      ${pkgs.coreutils}/bin/sleep 1
    done
    echo "navidrome is up (waited ''${i}s)"
  '';

  # `navidrome user create` only accepts the password via an interactive
  # terminal prompt (term.ReadPassword on stdin — no flag, no env var, and a
  # plain pipe fails with ENOTTY), so expect drives it under a pty. The
  # heredoc is quoted: $env(...) is Tcl, and expect does not rescan its
  # result, so arbitrary password characters are safe.
  createAudiomuseUser = pkgs.writeShellScript "navidrome-audiomuse-user" ''
    set -euo pipefail
    ${waitForNavidrome}
    users=$(${navidromeCli} user list -f csv)
    # Exact match on the username column only — a grep over the whole row
    # would false-positive on emails, display names or library paths.
    if printf '%s\n' "$users" | ${pkgs.coreutils}/bin/cut -d, -f2 \
        | ${pkgs.gnugrep}/bin/grep -qx audiomuse; then
      echo "Navidrome user 'audiomuse' already exists; nothing to do"
      exit 0
    fi
    echo "Creating Navidrome user 'audiomuse'"
    export AUDIOMUSE_ND_PASSWORD=${lib.escapeShellArg audiomuseSecrets.navidromePassword}
    ${pkgs.expect}/bin/expect <<'EOF'
      # user create opens the DB before prompting; give it headroom rather
      # than expect's 10s default, and treat a missed prompt as fatal instead
      # of blindly send-ing into the void.
      set timeout 120
      spawn ${navidromeCli} user create -u audiomuse --name AudioMuse
      expect {
        "Enter new password" {}
        timeout { puts "ERROR: timed out waiting for password prompt"; exit 1 }
        eof { puts "ERROR: user create exited before prompting"; exit 1 }
      }
      send -- "$env(AUDIOMUSE_ND_PASSWORD)\r"
      expect {
        "Confirm new password" {}
        timeout { puts "ERROR: timed out waiting for confirmation prompt"; exit 1 }
        eof { puts "ERROR: user create exited before confirming"; exit 1 }
      }
      send -- "$env(AUDIOMUSE_ND_PASSWORD)\r"
      expect eof
      catch wait result
      if {[lindex $result 2] == -1} { exit 1 }
      exit [lindex $result 3]
    EOF
  '';

  # Desired plugin config, stamped so we can tell when a navidrome restart is
  # actually needed (see below).
  # 8800 = the host port audiomuse.nix publishes the flask container on
  # (container-internal 8000 is taken on the host by python -m http.server).
  pluginConfig = builtins.toJSON {
    apiUrl = "http://127.0.0.1:8800";
    apiToken = audiomuseSecrets.apiToken;
  };
  pluginStamp = pkgs.writeText "navidrome-audiomuse-plugin-stamp" ''
    ${audiomuseaiPlugin}
    ${pluginConfig}
  '';

  # Assert-state for the plugin: rescan registers the wasm from the (read-only,
  # store-provided) plugins folder in the DB, enable is a no-op when already
  # enabled, and edit rewrites the config row — UI drift is stomped on every
  # run. The running server only reads plugin state once at startup (its
  # refresh event bus is in-process, invisible to this CLI), and it *disables*
  # a plugin whose .ndp content changed — so after any change to the plugin
  # package or config, navidrome must be restarted to pick the state up. The
  # stamp file limits that restart to actual changes; ExecStartPost below
  # performs it as root.
  configureAudiomusePlugin = pkgs.writeShellScript "navidrome-audiomuse-plugin" ''
    set -euo pipefail
    ${waitForNavidrome}
    ${navidromeCli} plugin rescan
    ${navidromeCli} plugin enable audiomuseai
    ${navidromeCli} plugin edit audiomuseai --config ${lib.escapeShellArg pluginConfig}
    # Stamp into the plugin unit's own StateDirectory, not navidrome's DB dir:
    # the DB dir is shared with the hardened server, and a stale root-owned
    # stamp there blocks this (unprivileged) overwrite with "Permission denied".
    cp ${pluginStamp} /var/lib/navidrome-plugin/.audiomuse-plugin-desired
  '';

  restartNavidromeIfStale = pkgs.writeShellScript "navidrome-audiomuse-plugin-restart" ''
    set -euo pipefail
    desired=/var/lib/navidrome-plugin/.audiomuse-plugin-desired
    applied=/var/lib/navidrome-plugin/.audiomuse-plugin-applied
    if [ -f "$desired" ] && ! ${pkgs.diffutils}/bin/cmp -s "$desired" "$applied"; then
      echo "Plugin package or config changed; restarting navidrome to load it"
      ${pkgs.systemd}/bin/systemctl try-restart navidrome.service
      cp "$desired" "$applied"
    fi
  '';
in
{
  services.navidrome = {
    enable = true;
    package = pkgs.navidrome;
    plugins = [ audiomuseaiPlugin ];
    settings = {
      Address = "0.0.0.0";
      MusicFolder = folders.music;
      Subsonic.AppendAlbumVersion = false;
      # Agents are opt-in by name; without this the audiomuseai plugin's
      # similar-artist agent is registered but never consulted (Instant Mix
      # would still work — sonic similarity bypasses the agent list — but
      # Artist Radio would silently keep coming from Last.fm). Order matters:
      # first agent that answers wins.
      Agents = "audiomuseai,lastfm,deezer,listenbrainz";
    };
  };

  # Only extend the user the navidrome module creates. The mkIf has to wrap the whole
  # `users.users` attrset, not just extraGroups: naming `users.users.navidrome.*` at all
  # instantiates that submodule, and with the service disabled (e.g. via
  # redline.ssd0.enable = false) it has no group or isSystemUser and fails evaluation.
  users.users = lib.mkIf config.services.navidrome.enable {
    navidrome.extraGroups = [ "editabledata" ];
  };

  # Declarative provisioning for the AudioMuse-AI integration. Both oneshots
  # wait for navidrome's DB to be ready and are idempotent. Wants= (not
  # Requires=) so the plugin oneshot's navidrome restart can't stop-propagate
  # back into the oneshot mid-run; RemainAfterExit so switch-to-configuration
  # re-runs them when their definition changes (a plain dead oneshot is
  # skipped on activation and would only re-run at boot). They are ordered
  # against each other purely to serialize their writes to navidrome's SQLite
  # DB. Gated in ssd0.nix alongside navidrome itself — their Wants= would
  # otherwise pull the disabled service back in.
  systemd.services.navidrome-audiomuse-user = {
    description = "Ensure the audiomuse Navidrome user exists";
    after = [ "navidrome.service" ];
    wants = [ "navidrome.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      TimeoutStartSec = "5m";
      User = "navidrome";
      Group = "navidrome";
      WorkingDirectory = "/var/lib/navidrome";
      ExecStart = createAudiomuseUser;
    };
  };

  systemd.services.navidrome-audiomuse-plugin = {
    description = "Enable and configure the AudioMuse-AI Navidrome plugin";
    after = [ "navidrome.service" "navidrome-audiomuse-user.service" ];
    wants = [ "navidrome.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      TimeoutStartSec = "5m";
      User = "navidrome";
      Group = "navidrome";
      # Created on unit start, owned by navidrome, so the stamp writes by the
      # unprivileged script below can never be blocked by root-owned leftovers
      # in navidrome's DB dir. WorkingDirectory stays /var/lib/navidrome: the
      # CLI subcommands locate the DB relative to it.
      StateDirectory = "navidrome-plugin";
      WorkingDirectory = "/var/lib/navidrome";
      ExecStart = configureAudiomusePlugin;
      # "+" = run as root: the restart decision is made by comparing the stamp
      # the (unprivileged) main script wrote against the last applied one.
      ExecStartPost = "+${restartNavidromeIfStale}";
    };
  };

  # Navidrome port
  networking.firewall.allowedTCPPorts = [ 4533 ];
}
