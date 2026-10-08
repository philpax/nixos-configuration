{ system ? "x86_64-linux", nixpkgsPin ? ../../frame/nixpkgs.json, extraOverride ? null }:
let
  environment = import ../../frame/environment.nix {
    inherit system nixpkgsPin;
    overrides = { pkgs, cliPackages, fontPackages }:
      let
        selected = {
          cliPackages = (import ../../common-all/packages/runtime.nix { inherit pkgs; }) ++
            (with pkgs; [ gcc clang openssl openssl.dev pkg-config hello ]);
          fontPackages = [ pkgs.cozette ];
        };
      in if extraOverride == null then selected
      else (if builtins.isFunction extraOverride then extraOverride else import extraOverride) {
        inherit pkgs;
        inherit (selected) cliPackages fontPackages;
      };
  };
  pkgs = environment.pkgs;
  profile = environment.profile;
  assetEnvironment = import ../../frame/environment.nix {
    inherit system nixpkgsPin;
    overrides = { pkgs, cliPackages, fontPackages }: {
      cliPackages = import ../../common-all/packages/runtime.nix { inherit pkgs; };
      fontPackages = with pkgs; [
        cozette iosevka noto-fonts noto-fonts-cjk-sans noto-fonts-color-emoji nerd-fonts.meslo-lg
      ];
    };
  };
  compilerCheck = pkgs.runCommand "frame-cli-compiler-check" { } ''
    export PATH=${profile}/bin
    export PKG_CONFIG_PATH=${profile}/lib/pkgconfig:${profile}/share/pkgconfig
    test "$(readlink -f ${profile}/bin/cc)" = "$(readlink -f ${pkgs.gcc}/bin/cc)"
    for command in fish bash python3 ssh ssh-agent ssh-add curl less grep sed awk find ps mount ip tar gzip bzip2 xz which; do
      test -x ${profile}/bin/$command
    done
    test -r ${profile}/etc/ssl/certs/ca-bundle.crt
    gcc --version
    clang --version
    cc --version
    cat > main.c <<'C'
    #include <openssl/crypto.h>
    #include <stdio.h>
    int main(void) { puts(OpenSSL_version(OPENSSL_VERSION)); return 0; }
    C
    for compiler in gcc clang cc; do
      "$compiler" main.c $(pkg-config --cflags --libs openssl) -o "check-$compiler"
      ./check-$compiler
    done
    test -r ${profile}/include/openssl/crypto.h
    test -r ${profile}/lib/pkgconfig/openssl.pc
    test -L ${profile}/share/frame-cli/nixpkgs
    test -L ${profile}/share/frame-cli/assets/bell
    test -L ${profile}/share/frame-cli/assets/fonts/font-0-${pkgs.cozette.name}-out
    touch "$out"
  '';
in
{
  inherit profile compilerCheck;
  assetProfile = assetEnvironment.profile;
  inherit (environment) pkgs cliPackages fontPackages outputManifest assetManifest buildInfo;
  testAssets = {
    profile = assetEnvironment.profile;
    fonts = assetEnvironment.assetManifest.fonts;
    bell = assetEnvironment.assetManifest.bell;
  };
}
