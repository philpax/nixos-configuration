{ config, lib, pkgs, ... }:

let
  ddclientSecrets = import ../secrets/ddclient.nix;

  ddclientConfig = pkgs.writeText "ddclient-config" ''
    protocol=namecheap
    use=web, web=dynamicdns.park-your-domain.com/getip
    server=dynamicdns.park-your-domain.com
    login=philpax.me
    password=${ddclientSecrets.password}
    # Without this ddclient tries to cache into its own store path and logs three
    # "Failed to create cache file directory: ... Read-only file system" warnings on
    # every run. StateDirectory=ddclient gives us a writable dir; use it.
    cache=/var/lib/ddclient/ddclient.cache
    promare.philpax.me
  '';

  # Replaces the prestart script from the upstream NixOS ddclient module, which does
  # `install --mode=600 --owner=$USER`. The unit is DynamicUser=true, so $USER is a
  # transient identity that only becomes resolvable through NSS once the service is
  # properly up — meaning the FIRST run after every boot fails with
  #
  #     install: invalid user 'ddclient'
  #
  # and the unit sits in `failed` until the timer fires again ~10 minutes later, when
  # the UID is reserved in /run/systemd/dynamic-uid/ and the lookup succeeds. Verified
  # in the journal across two consecutive boots: fails at first attempt, succeeds at
  # every subsequent one.
  #
  # systemd creates RuntimeDirectory=/run/ddclient owned by that same dynamic user
  # BEFORE ExecStartPre runs, so we can take the owner from the directory itself as a
  # numeric uid and never consult NSS at all.
  ddclientPrestart = pkgs.writeShellScript "ddclient-prestart" ''
    set -eu
    uid="$(${pkgs.coreutils}/bin/stat -c %u /run/ddclient)"
    ${pkgs.coreutils}/bin/install --mode=600 --owner="$uid" \
      ${ddclientConfig} /run/ddclient/ddclient.conf
  '';
in
{
  services.ddclient = {
    enable = true;
    configFile = ddclientConfig;
  };

  # `!` keeps the upstream semantics: run with full privileges rather than as the
  # DynamicUser, since it has to chown the file it just wrote.
  systemd.services.ddclient.serviceConfig.ExecStartPre =
    lib.mkForce "!${ddclientPrestart}";
}
