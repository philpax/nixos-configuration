# Surface failed systemd units instead of leaving them in the journal.
#
# Motivation: on 2026-07-27 the weekly btrfs scrub found corruption on /mnt/ssd0
# (`Error summary: csum=9`), exited 3, and the unit went to `failed`. That was a full
# week's warning before the filesystem forced itself read-only on 2026-08-01 and took
# 19 files with it. The detection worked perfectly. Nothing told anyone.
#
# Three layers, deliberately redundant, cheapest first:
#   1. login banner  — `systemctl --failed` on every interactive shell. Zero state,
#                      catches EVERY unit, not just the ones wired below. This is the
#                      layer that would actually have caught Jul 27.
#   2. OnFailure hook — journal at err + wall + a persistent log that survives the unit
#                      later succeeding (a weekly job that fails once then passes would
#                      otherwise erase its own evidence from `systemctl --failed`).
#   3. `unit-failures` — command to read that history back.
{ config, lib, pkgs, ... }:

let
  stateDir = "/var/lib/unit-alerts";
  logFile = "${stateDir}/failures.log";

  alertScript = pkgs.writeShellScript "unit-alert" ''
    set -u
    unit="''${1:-unknown}"
    ts="$(${pkgs.coreutils}/bin/date -Is)"
    msg="SYSTEMD UNIT FAILED: $unit  ($ts)"

    # 1. journal, at error priority so it stands out from the unit's own output
    echo "$msg" | ${pkgs.systemd}/bin/systemd-cat -t unit-alert -p err

    # 2. broadcast to any attached terminal (best-effort; nobody may be logged in)
    echo "$msg" | ${pkgs.util-linux}/bin/wall -n 2>/dev/null || true

    # 3. persistent record. `systemctl --failed` only shows the CURRENT state, so a
    #    weekly job that fails once and passes next week would vanish without this.
    ${pkgs.coreutils}/bin/mkdir -p ${stateDir}
    {
      printf '%s\t%s\n' "$ts" "$unit"
      ${pkgs.systemd}/bin/systemctl status --no-pager --lines=15 "$unit" 2>&1 \
        | ${pkgs.gnused}/bin/sed 's/^/    /'
      echo
    } >> ${logFile}
  '';

  # Units worth an explicit hook: silent failure of either loses data or hides
  # data loss. Everything else is still covered by the login banner.
  # hermes-backup-check is the counterpart to the in-guest backup timer. The VM
  # writes hourly dumps to a virtiofs drop directory, and nothing on the host
  # would otherwise detect that stopping. A stale drop is indistinguishable from
  # a healthy one from rsync's perspective, because rsync copies the same files
  # indefinitely. This has the same shape as the Jul 27 miss, one layer out.
  watched = [ "backup-sync" "hermes-backup-check" ]
    ++ lib.optional config.redline.ssd0.enable "btrfs-scrub-mnt-ssd0";

in
{
  systemd.services = {
    "unit-alert@" = {
      description = "Report that %i failed";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${alertScript} %i";
      };
    };
  }
  # Attach OnFailure to each watched unit. %n expands to the failing unit's full name,
  # so one template instance serves all of them.
  // lib.genAttrs watched (_: {
    onFailure = [ "unit-alert@%n.service" ];
  });

  systemd.tmpfiles.rules = [ "d ${stateDir} 0755 root root -" ];

  environment.systemPackages = [
    (pkgs.writeShellScriptBin "unit-failures" ''
      if [ ! -s ${logFile} ]; then
        echo "No recorded unit failures (${logFile} is empty)."
      else
        echo "=== recorded unit failures — ${logFile} ==="
        cat ${logFile}
      fi
      echo
      echo "=== currently failed ==="
      ${pkgs.systemd}/bin/systemctl --failed --no-pager
    '')
  ];

  # Login banner. fish is the login shell here; bash/zsh covered separately so the
  # banner does not depend on which shell happens to be used.
  programs.fish.interactiveShellInit = lib.mkAfter ''
    if status is-interactive
      set -l _failed (systemctl --failed --no-legend --plain 2>/dev/null | string trim)
      if test -n "$_failed"
        set_color red --bold
        echo "!! systemd units in failed state:"
        set_color normal
        for _u in $_failed
          echo "     $_u"
        end
        echo "   `unit-failures` for history, `systemctl status <unit>` for detail."
      end
    end
  '';

  environment.interactiveShellInit = ''
    if [ -n "''${PS1:-}" ]; then
      _failed=$(systemctl --failed --no-legend --plain 2>/dev/null)
      if [ -n "$_failed" ]; then
        printf '\033[1;31m!! systemd units in failed state:\033[0m\n'
        printf '%s\n' "$_failed" | sed 's/^/     /'
        echo "   \`unit-failures\` for history, \`systemctl status <unit>\` for detail."
      fi
      unset _failed
    fi
  '';
}
