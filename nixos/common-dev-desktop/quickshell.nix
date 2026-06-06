{ pkgs, ... }:

let
  # imiric/qml-niri — QML plugin exposing niri's IPC (workspaces, focused
  # window, events) to QtQuick. Not yet packaged in nixpkgs; its default.nix
  # is a plain callPackage-style derivation we can use directly.
  qml-niri-rev = "3e90700d7765445517810248de0466d3bf4ca47c";
  qml-niri-src = pkgs.fetchFromGitHub {
    owner = "imiric";
    repo = "qml-niri";
    rev = qml-niri-rev;
    hash = "sha256-ou+fqdtANRSllDbYIeOz17Dv0TMLkKufWqWGvvdOYpg=";
  };
  qml-niri = pkgs.callPackage (qml-niri-src + "/default.nix") {
    version = "main-${builtins.substring 0 7 qml-niri-rev}";
  };

  # Mirror the flake's `quickshell-niri` output: add the plugin to
  # quickshell's buildInputs so Qt's wrap hook puts it on QML2_IMPORT_PATH.
  quickshell = pkgs.quickshell.overrideAttrs (prev: {
    buildInputs = [ qml-niri ] ++ prev.buildInputs;
  });
in
{
  environment.systemPackages = [ quickshell ];
}
