{ config, pkgs, unstable ? null }:
let
  # Get all .nix files in the current directory except default.nix
  serviceFiles = builtins.filter (f: f != "default.nix")
    (builtins.map (f: builtins.baseNameOf f)
      (builtins.filter (f: builtins.match ".*\\.nix$" f != null)
        (builtins.attrNames (builtins.readDir ./.))));

  # Create import expressions for each service file
  serviceImports = builtins.map (file:
    import (./. + "/${file}") { inherit config pkgs unstable; }
  ) serviceFiles;
in
{
  imports = serviceImports;
}