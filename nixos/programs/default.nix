{ config, pkgs, unstable ? null }:
let
  # Get all .nix files in the current directory except default.nix
  programFiles = builtins.filter (f: f != "default.nix")
    (builtins.map (f: builtins.baseNameOf f)
      (builtins.filter (f: builtins.match ".*\\.nix$" f != null)
        (builtins.attrNames (builtins.readDir ./.))));

  # Create import expressions for each program file
  programImports = builtins.map (file:
    import (./. + "/${file}") { inherit config pkgs unstable; }
  ) programFiles;
in
{
  imports = programImports;
}