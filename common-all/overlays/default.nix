# Overlays every machine applies. NixOS sets nixpkgs.overlays from this list;
# Frame passes it to system-manager directly (see frame/default.nix).
[
  # Helix + the Steel plugin system. Steel's cog root ($STEEL_HOME) is set in
  # the fish config so it can be reloaded without a re-login; cogs are git
  # submodules under steel-cogs/, linked into $STEEL_HOME/cogs by sync.py.
  (import ./helix-steel.nix)
]
