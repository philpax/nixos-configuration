# Timebomb: attach an expiry date to a temporary hack so it nags you once
# the date passes, instead of quietly living forever.
#
#   let timebomb = import ../common-all/lib/timebomb.nix { inherit lib; };
#   in someOption = timebomb "2026-07-22" "drop this; fixed upstream in nixpkgs#123456" value;
#
# Dates are ISO 8601 (YYYY-MM-DD), interpreted as midnight UTC. Once expired,
# evaluation emits a warning whenever the wrapped value is forced. Relies on
# builtins.currentTime, so it needs impure evaluation (channels/nix-build:
# fine; pure flake eval would reject it).
{ lib }:
let
  # Days from the Unix epoch to a Gregorian civil date
  # (Howard Hinnant's days_from_civil; integer division is exact here
  # because every intermediate is non-negative for years >= 1).
  daysFromCivil =
    y: m: d:
    let
      y' = if m <= 2 then y - 1 else y;
      era = y' / 400;
      yoe = y' - era * 400;
      doy = (153 * (lib.mod (m + 9) 12) + 2) / 5 + d - 1;
      doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    in
    era * 146097 + doe - 719468;

  parseDate =
    date:
    let
      m = builtins.match "([0-9]{4})-([0-9]{2})-([0-9]{2})" date;
      parts = map lib.toIntBase10 m;
      month = builtins.elemAt parts 1;
      day = builtins.elemAt parts 2;
    in
    if m == null then
      throw "timebomb: expected an ISO 8601 date (YYYY-MM-DD), got: ${date}"
    else if month < 1 || month > 12 || day < 1 || day > 31 then
      throw "timebomb: not a valid calendar date: ${date}"
    else
      parts;
in
date: reason: value:
let
  parts = parseDate date;
  expiry =
    86400 * daysFromCivil (builtins.elemAt parts 0) (builtins.elemAt parts 1) (builtins.elemAt parts 2);
in
if builtins.currentTime >= expiry then
  lib.warn "⏰ timebomb expired (${date}): ${reason}" value
else
  value
