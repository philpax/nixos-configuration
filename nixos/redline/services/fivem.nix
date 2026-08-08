{ config, lib, pkgs, ... }:

let
  folders = import ../folders.nix;
  fivemSecrets = import ../secrets/fivem.nix;

  fivemUser = "fivem";
  fivemGroup = "fivem";
  fivemDir = folders.fivem;
  port = 30120;

  # "LATEST RECOMMENDED" from
  # https://runtime.fivem.net/artifacts/fivem/build_proot_linux/master/
  # Bump the build and the hash together; the artifact directory is immutable.
  fxserverBuild = "25770-8ddccd4e4dfd6a760ce18651656463f961cc4761";

  # Despite the "proot" in the artifact channel name there is no proot: the
  # tarball is an Alpine tree whose bundled musl loader is invoked directly.
  # The shipped run.sh is a #!/bin/bash script, which doesn't exist here, so we
  # rebuild its invocation as a wrapper instead.
  fxserver = pkgs.stdenvNoCC.mkDerivation {
    pname = "fxserver";
    version = lib.head (lib.splitString "-" fxserverBuild);

    src = pkgs.fetchurl {
      url = "https://runtime.fivem.net/artifacts/fivem/build_proot_linux/master/${fxserverBuild}/fx.tar.xz";
      hash = "sha256-TVWs0TBmUa7PhFdplIXHNtCKrjewdcSTpm2s1iNAJjE=";
    };

    sourceRoot = ".";
    nativeBuildInputs = [ pkgs.makeWrapper ];

    # Prebuilt musl binaries carrying their own loader and libraries. patchelf
    # and strip have nothing useful to do here and plenty to break.
    dontFixup = true;

    installPhase = ''
      runHook preInstall

      mkdir -p $out/share/fxserver $out/bin
      cp -r alpine $out/share/fxserver/

      cfx=$out/share/fxserver/alpine/opt/cfx-server
      makeWrapper $cfx/ld-musl-x86_64.so.1 $out/bin/FXServer \
        --add-flags "--library-path $out/share/fxserver/alpine/usr/lib/v8/:$out/share/fxserver/alpine/lib/:$out/share/fxserver/alpine/usr/lib/" \
        --add-flags "--" \
        --add-flags "$cfx/FXServer" \
        --add-flags "+set citizen_dir $cfx/citizen/"

      runHook postInstall
    '';

    meta = {
      description = "Cfx.re FXServer, the FiveM dedicated server";
      homepage = "https://fivem.net/";
      platforms = [ "x86_64-linux" ];
      sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
    };
  };

  cfxServerData = pkgs.fetchFromGitHub {
    owner = "citizenfx";
    repo = "cfx-server-data";
    rev = "e265cb251c88260533c847d4a1a2838c7d828a66";
    hash = "sha256-7bO8C1BLJb1FwmHxWK4AjhTvXACmJTQGT16bQngrKHA=";
  };

  # Built from source to set its client-side defaults and to let a saved ped
  # be your default ped; see the file for why that needs a compile.
  vmenu = pkgs.callPackage ./fivem/vmenu.nix { };

  # The complete set of resources the server runs, assembled at build time.
  # Copied into place on each start (see ExecStartPre) rather than symlinked,
  # for reasons documented there.
  resources = pkgs.runCommand "fivem-resources" { } ''
    mkdir -p $out

    # A deliberately small slice of cfx-server-data. Notably absent: `chat`,
    # which ships unbuilt here and has the yarn/webpack builder resources fetch
    # node_modules into its own directory on first start — impossible from the
    # store. It comes from the FXServer package instead, further down.
    for res in \
      '[managers]/mapmanager' \
      '[managers]/spawnmanager' \
      '[system]/baseevents' \
      '[system]/hardcap' \
      '[system]/rconlog' \
      '[system]/sessionmanager' \
      '[gameplay]/chat-theme-gtao' \
      '[gameplay]/playernames' \
      '[gamemodes]/basic-gamemode' \
      '[gamemodes]/[maps]/fivem-map-skater'
    do
      mkdir -p "$out/$(dirname "$res")"
      cp -r --no-preserve=mode "${cfxServerData}/resources/$res" "$out/$res"
    done

    # FXServer ships a prebuilt `chat` under citizen/system_resources, but only
    # `monitor` is auto-discovered from there — an `ensure chat` against the
    # bundled copy fails with "Couldn't find resource chat". Copying it in is
    # still much better than building cfx-server-data's source copy: this one
    # already has its dist/ compiled.
    cp -r --no-preserve=mode \
      ${fxserver}/share/fxserver/alpine/opt/cfx-server/citizen/system_resources/chat \
      $out/chat

    cp -r --no-preserve=mode ${vmenu} $out/vMenu
    cp -r --no-preserve=mode ${./fivem/sandbox} $out/sandbox
    cp -r --no-preserve=mode ${./fivem/npc} $out/npc
    cp -r --no-preserve=mode ${./fivem/joinpassword} $out/joinpassword
    cp -r --no-preserve=mode ${./fivem/scoreboard} $out/scoreboard
    cp -r --no-preserve=mode ${./fivem/race} $out/race
  '';

  # A quote, semicolon or newline in a secret would end its cfg value early and
  # leave the remainder to be executed as a console command.
  secretsAreCfgSafe = lib.all
    (s: !(lib.hasInfix "\"" s) && !(lib.hasInfix ";" s) && !(lib.hasInfix "\n" s))
    [
      fivemSecrets.rconPassword
      fivemSecrets.joinPassword
      fivemSecrets.licenseKey
    ];

  serverCfgText = ''
    endpoint_add_tcp "0.0.0.0:${toString port}"
    endpoint_add_udp "0.0.0.0:${toString port}"

    sv_hostname "redline sandbox"
    sets sv_projectName "redline sandbox"
    sets sv_projectDesc "Freeroam sandbox: vMenu, /car, PvP, all DLC"
    sv_maxclients 12
    sets tags "sandbox, freeroam, vmenu, pvp"
    sets locale "en-AU"

    set onesync on
    sv_scriptHookAllowed 0

    # Unlocks DLC vehicle/ped/weapon models up to "A Safehouse in the Hills"
    # (mp2025_02). Must be a build the FXServer artifact above knows about —
    # bump the two together.
    # https://docs.fivem.net/docs/server-manual/server-commands/#sv_enforcegamebuild
    sv_enforceGameBuild 3751

    # Culling drops distant off-screen entities from sync, and a player who
    # isn't synced has no local ped for a map blip to attach to. Off, so
    # everyone stays visible on the map at any range.
    set onesync_distanceCulling false
    set onesync_distanceCullVehicles false

    # Reachable from the internet on the UDP endpoint above, and authenticates
    # as system.console — every console command, including add_principal. The
    # password is plaintext on the wire and sits in a world-readable
    # /nix/store file that is also on FXServer's argv. Unset disables RCON.
    #
    # `set`, not the bare `rcon_password "..."` the stock server.cfg ships:
    # libcitizen-server-impl registers the convar ConVar_ReadOnly (flag 0x10),
    # so the bare form is silently refused and RCON keeps answering "must set
    # rcon_password". `set` goes through the variable manager and lands.
    #
    # Not `setr` either: that replicates the password to every client, and RCON
    # authenticates as system.console.
    set rcon_password "${fivemSecrets.rconPassword}"

    # Keep the server out of the public browser: everyone who joins gets the
    # whole of vMenu (see the ace below), so the join password and not being
    # advertised are the only things between a stranger and admin powers.
    # Direct connect still works. Drop this line to be listed publicly.
    set sv_master1 ""

    # Don't hand out player IP endpoints to connected clients.
    sv_endpointPrivacy true

    # From keymaster.fivem.net. This lands in a world-readable /nix/store file,
    # same as every other secret in this configuration.
    sv_licenseKey "${fivemSecrets.licenseKey}"

    # Plain `set`, never `sets`: replicated convars are sent to every client.
    set sandbox_join_password "${fivemSecrets.joinPassword}"
    ensure joinpassword

    ensure mapmanager
    ensure spawnmanager
    ensure sessionmanager
    ensure baseevents
    ensure hardcap
    ensure rconlog
    ensure chat
    ensure chat-theme-gtao
    ensure playernames

    ensure fivem-map-skater
    ensure basic-gamemode

    # Sandbox: everyone gets the whole of vMenu. Permissions still have to be
    # switched on for the ace to be consulted at all.
    setr vmenu_use_permissions true

    # These are FiveM input-mapper key *names*, not control IDs — vMenu feeds
    # them straight to RegisterKeyMapping, and a numeric value silently
    # registers nothing at all.
    # https://docs.fivem.net/docs/game-references/input-mapper-parameter-ids/keyboard/
    setr vmenu_menu_toggle_key "F7"
    setr vmenu_noclip_toggle_key "F2"

    # RegisterKeyMapping bindings persist in each client's profile under this
    # id, so a changed default won't reach anyone who already registered under
    # the old one. Bump this whenever the keys above change.
    setr vmenu_keymapping_id "redlineSandbox1"

    setr vmenu_enable_time_sync true
    setr vmenu_enable_weather_sync true

    # 1 = friendly fire on, 2 = forced off, 0 = leave the game's default.
    # vMenu applies this once at startup, and sandbox/pvp.lua reasserts the
    # per-ped half of it after model changes and respawns.
    setr vmenu_pvp_mode 1

    # Adds animals to vMenu's ped spawner.
    setr vmenu_enable_animals_spawn_menu true

    # Overhead names belong to `playernames` above (250m, needs line of
    # sight). vMenu's copy is a second CreateMpGamerTag on the same ped and
    # the two recreate each other's tags forever, so leave vMenu's "Show
    # Player Names" off.

    # Everything else vMenu does is a per-client setting with no convar and no
    # reachable ace. Those defaults live in fivem/vmenu.nix.
    add_ace builtin.everyone "vMenu.Everything" allow

    ensure vMenu
    ensure sandbox
    ensure npc
    ensure scoreboard
    ensure race
  '';

  # The cfg parser treats `;` as a command separator inside `#` comments too, so
  # a comment's tail gets executed at boot — `...defaults off; set it anyway`
  # silently created a convar named `it`. Nothing here needs one.
  serverCfg =
    assert lib.assertMsg (!(lib.hasInfix ";" serverCfgText))
      "fivem: server.cfg contains a semicolon, which the cfg parser treats as a command separator even inside a comment.";
    assert lib.assertMsg secretsAreCfgSafe
      "fivem: a secret in secrets/fivem.nix contains a quote, semicolon or newline.";
    pkgs.writeText "fivem-server.cfg" serverCfgText;
in
{
  users.users.${fivemUser} = {
    isSystemUser = true;
    group = fivemGroup;
    description = "FiveM server service user";
    home = fivemDir;
    shell = "${pkgs.bash}/bin/bash";
  };

  users.groups.${fivemGroup} = { };

  # ReadWritePaths below has to resolve before systemd sets up the unit's mount
  # namespace, which happens before any ExecStartPre — including a `+` one — so
  # the service can't create its own data directory. tmpfiles gets there first.
  systemd.tmpfiles.rules = [
    "d ${fivemDir} 0750 ${fivemUser} ${fivemGroup} -"
    "d ${fivemDir}/cache 0750 ${fivemUser} ${fivemGroup} -"
  ];

  systemd.services.fivem-server = {
    description = "FiveM (FXServer) sandbox server";
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];

    path = [ pkgs.coreutils ];

    # A rejected license key is a permanent failure, not a transient one —
    # give up rather than retry against keymaster every ten seconds forever.
    unitConfig = {
      StartLimitIntervalSec = 300;
      StartLimitBurst = 5;
    };

    serviceConfig = {
      Type = "simple";
      User = fivemUser;
      Group = fivemGroup;

      WorkingDirectory = fivemDir;
      # FXServer discovers resources relative to its working directory, so the
      # store-built tree gets mirrored in from there.
      #
      # This is a copy rather than a symlink because vMenu writes into its own
      # resource directory on startup — MainServer.SetupAddonPerms regenerates
      # config/templates/SupplementaryPermissionTemplate.cfg every boot, and
      # throws (taking the whole server script down with it) if the path is
      # read-only. The copy is wholly derived from `resources`, so it is wiped
      # and re-made on every start: edits made in place here do not survive a
      # restart, which is the point. Change the Nix, not the copy.
      #
      # Staged then swapped: a copy that fails part-way must not leave a
      # half-populated tree behind, because the restart limit then burns out in
      # under a minute and the unit stays dead.
      ExecStartPre = pkgs.writeShellScript "fivem-pre-start" ''
        set -euo pipefail

        staging=${fivemDir}/.resources-staging
        rm -rf "$staging"
        mkdir -p "$staging"
        cp -r --no-preserve=mode ${resources}/. "$staging"/

        rm -rf ${fivemDir}/resources
        mv "$staging" ${fivemDir}/resources
      '';
      # StandardInput=null hands FXServer's console an immediate EOF, which it
      # otherwise reads as Ctrl-C and shuts down a few seconds after boot.
      ExecStart = "${fxserver}/bin/FXServer +set con_disableNonTTYReads 1 +exec ${serverCfg}";

      StandardInput = "null";
      StandardOutput = "journal";
      StandardError = "journal";
      SyslogIdentifier = "fivem-server";

      Restart = "on-failure";
      RestartSec = "10";

      ReadWritePaths = [ fivemDir ];

      NoNewPrivileges = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      PrivateTmp = true;
      ProtectKernelTunables = true;
      ProtectKernelModules = true;
      ProtectControlGroups = true;
      RestrictRealtime = true;
      RestrictSUIDSGID = true;

      LimitNOFILE = 65536;
    };
  };

  networking.firewall.allowedTCPPorts = [ port ];
  networking.firewall.allowedUDPPorts = [ port ];
}
