{ ... }:

# Gamescope for local gaming: per-game scaling / HDR / frame-limiting via Steam
# launch options, e.g. `gamescope -W 2560 -H 1440 -f -- %command%`.
{
  programs.gamescope = {
    enable = true;
    capSysNice = true;
  };
}
