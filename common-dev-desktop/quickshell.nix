{ pkgs, ... }:

let
  # imiric/qml-niri — QML plugin exposing niri's IPC (workspaces, focused
  # window, events) to QtQuick. Not yet packaged in nixpkgs; its default.nix
  # is a plain callPackage-style derivation we can use directly.
  # Bumped from 3e90700 for sendRawAction (arbitrary niri actions) and
  # WorkspaceModel.get/indexOfId, both needed by the draggable workspace bar.
  qml-niri-rev = "4b31c331eccd9c99a7d97c778e374672b4a39c29";
  qml-niri-src = pkgs.fetchFromGitHub {
    owner = "imiric";
    repo = "qml-niri";
    rev = qml-niri-rev;
    hash = "sha256-c3bZ2cfMBMkxuADzkZn0jJJsgDXan4p43wBSAju1n0g=";
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
