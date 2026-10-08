# Trusted executable Nix configuration. Copy to ~/.config/frame-cli/overrides.nix
# only if these changes are wanted; sync does not install this example.
{ pkgs, cliPackages, fontPackages }:
{
  # Remove a non-required utility and add another. Runtime tools must remain.
  cliPackages = builtins.filter (p: p != pkgs.tldr) cliPackages ++ [ pkgs.hello ];
  inherit fontPackages;
}
