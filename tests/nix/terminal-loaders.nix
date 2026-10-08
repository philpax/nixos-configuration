{ system ? "x86_64-linux", nixpkgsPin ? ../../frame/nixpkgs.json }:
let
  environment = import ../../frame/environment.nix {
    inherit system nixpkgsPin;
    overrides = { pkgs, fontPackages, ... }: {
      inherit fontPackages;
      cliPackages = (import ../../common-all/packages/runtime.nix { inherit pkgs; }) ++ [
        pkgs.gcc pkgs.clang pkgs.openssl pkgs.openssl.dev pkgs.pkg-config
      ];
    };
  };
  pkgs = environment.pkgs;
  lib = pkgs.lib;
  profile = environment.profile;
  # Only test code, passive terminal config and activation asset code enter tooling builds.
  source = lib.fileset.toSource {
    root = ../..;
    fileset = lib.fileset.unions [
      ../../frame/__init__.py
      ../../frame/activation.py
      ../../frame/paths.py
      ../../frame/templates
      ../../common-dev-desktop/dotfiles/.config/ghostty/config
      ../../common-dev-desktop/dotfiles/.config/alacritty/alacritty.toml
      ../terminal_scenarios.py
      ../host_fontconfig.py
    ];
  };
  ocean = pkgs.kdePackages.ocean-sound-theme;
  bell = "${ocean}/share/sounds/ocean/stereo/bell-window-system.oga";
  alacrittyLoader = assert pkgs.alacritty.version == "0.17.0";
    pkgs.alacritty.overrideAttrs (old: {
      pname = "alacritty-frame-config-loader-test";
      # Source and cargoDeps remain the selected Nixpkgs package's exact inputs.
      outputs = [ "out" ];
      nativeBuildInputs = old.nativeBuildInputs ++ [ pkgs.python3 ];
      postPatch = (old.postPatch or "") + ''
        cp ${../alacritty_loader.rs} alacritty/src/config/frame_cli_loader.rs
        printf '\n#[cfg(test)]\nmod frame_cli_loader;\n' >> alacritty/src/config/mod.rs
      '';
      buildPhase = ''
        runHook preBuild
        runHook postBuild
      '';
      doCheck = true;
      checkPhase = ''
        runHook preCheck
        export FRAME_TERMINAL_FIXTURE="$TMPDIR/deployed terminal fixture"
        python3 ${source}/tests/terminal_scenarios.py prepare \
          --repo ${source} --root "$FRAME_TERMINAL_FIXTURE" --bell ${bell}
        export HOME="$FRAME_TERMINAL_FIXTURE/home with spaces"
        export XDG_CONFIG_HOME="$HOME/.config"
        export XDG_CONFIG_DIRS="$HOME/empty config dirs"
        cargo test --offline --locked --package alacritty --bin alacritty \
          config::frame_cli_loader::alacritty_deployed_config_loader \
          -- --exact --test-threads=1 --nocapture | tee loader-test.log
        grep -F '1 passed; 0 failed' loader-test.log
        runHook postCheck
      '';
      installPhase = ''
        mkdir -p "$out"
        cp loader-test.log "$out/loader-test.log"
      '';
      postInstall = "";
      postFixup = "";
      doInstallCheck = false;
    });
  ghosttyLoader = pkgs.runCommand "ghostty-frame-deployed-config-test" {
    nativeBuildInputs = [ pkgs.python3 pkgs.ghostty ];
  } ''
    mkdir -p "$out"
    # Missing CLI support is an error; no optional check or silent skip is allowed.
    ghostty +validate-config --help > "$out/validate-help.txt"
    ghostty +show-config --help > "$out/show-help.txt"
    python3 ${source}/tests/terminal_scenarios.py ghostty \
      --repo ${source} --ghostty ${pkgs.ghostty}/bin/ghostty \
      --fish ${pkgs.fish}/bin/fish --bell ${bell} > "$out/effective-config.json"
  '';
  hostFontArtifact = pkgs.runCommand "frame-host-font-artifact" {
    nativeBuildInputs = [ pkgs.python3 ];
  } ''
    python3 ${source}/tests/terminal_scenarios.py export-fonts \
      --repo ${source} --profile ${profile} --destination "$out"
  '';
  profileCheck = pkgs.runCommand "frame-lightweight-profile-test" {
    nativeBuildInputs = [ pkgs.python3 ];
  } ''
    mkdir -p "$out"
    export PATH=${profile}/bin:$PATH
    export PKG_CONFIG_PATH=${profile}/lib/pkgconfig:${profile}/share/pkgconfig
    test "$(readlink -f ${profile}/bin/cc)" = "$(readlink -f ${pkgs.gcc}/bin/cc)"
    printf '#include <openssl/crypto.h>\nint main(void) { return OpenSSL_version(0) == 0; }\n' > openssl.c
    for compiler in gcc clang cc; do
      "$compiler" openssl.c $(pkg-config --cflags --libs openssl) -o "test-$compiler"
      "./test-$compiler"
    done
    python3 -c 'import json; p=json.load(open("${profile}/share/frame-cli/build-info.json")); assert p["fontPackages"]; assert any(r["path"] == "${pkgs.openssl.dev}" for r in p["cliPackages"])'
    cp ${profile}/share/frame-cli/build-info.json "$out/build-info.json"
  '';
in
{
  inherit profile alacrittyLoader ghosttyLoader hostFontArtifact profileCheck;
  metadata = {
    nixpkgs = environment.pin;
    alacrittyVersion = pkgs.alacritty.version;
    ghosttyVersion = pkgs.ghostty.version;
    profileDrv = profile.drvPath;
  };
  checks = pkgs.runCommand "frame-terminal-loader-checks" { } ''
    mkdir -p "$out"
    ln -s ${alacrittyLoader} "$out/alacritty"
    ln -s ${ghosttyLoader} "$out/ghostty"
    ln -s ${profileCheck} "$out/profile"
  '';
}
