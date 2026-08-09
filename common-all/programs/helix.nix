{ pkgs, ... }:

{
  # Helix + the Steel plugin system; see ../overlays/helix-steel.nix. Steel's cog root
  # ($STEEL_HOME) is set in the fish config, not here, so it can be reloaded without a
  # re-login. Cogs are git submodules under steel-cogs/, symlinked into $STEEL_HOME/cogs
  # by sync.py (build_cog_symlinks).
  environment.systemPackages = [ pkgs.helix-steel ];
}
