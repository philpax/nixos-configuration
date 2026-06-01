{ pkgs, ... }:

# IDA Pro 9.3 packaged for NixOS. The derivation below is adapted, with thanks,
# from msanft's ida-pro-overlay:
#   https://raw.githubusercontent.com/msanft/ida-pro-overlay/refs/heads/main/packages/ida-pro.nix
# Retargeted at IDA Pro 9.3.260213.
#
# IDA Pro is unfree and distributed as a licensed binary, so we don't vendor the
# installer. `requireFile` expects it to already live in the Nix store; add it with:
#
#   nix-store --add-fixed sha256 ida-pro_93_x64linux.run
#
# (nix will also print this exact command if the file is missing at build time.)

let
  inherit (pkgs) lib;

  pythonForIDA = pkgs.python313.withPackages (ps: with ps; [ rpyc ]);

  # Byte-pattern substitution applied to the core libraries after extraction.
  # `from`/`to` must be the same length since we overwrite in place. Only files
  # present for this platform are touched — on Linux just the .so variants exist,
  # so the .dll/.dylib entries are skipped.
  hexPatch = {
    from = "EDFD425CF978";
    to   = "EDFD42CBF978";
    files = [
      "ida.dll" "ida32.dll"
      "libida.so" "libida32.so"
      "libida.dylib" "libida32.dylib"
    ];
  };

  # One guarded substitution per candidate file. `\Q…\E` quotes regex
  # metacharacters in the packed bytes; we require at least one match in any file
  # that exists, so a pattern that's silently absent (e.g. after a version bump
  # moved it) fails the build rather than passing unchanged.
  patchScript = lib.concatMapStringsSep "\n" (file: ''
    if [ -f "$IDADIR/${file}" ]; then
      echo "Patching ${file}..."
      perl -0777 -pi -e 'my $cnt = (s/\Q''${\pack("H*","${hexPatch.from}")}\E/''${\pack("H*","${hexPatch.to}")}/g) || 0; die "ida-pro: expected >=1 substitution in ${file}, did $cnt\n" if $cnt < 1' "$IDADIR/${file}"
    fi
  '') hexPatch.files;

  ida-pro = pkgs.stdenv.mkDerivation rec {
    pname = "ida-pro";
    version = "9.3.260213";

    src = pkgs.requireFile {
      name = "ida-pro_93_x64linux.run";
      url = "https://my.hex-rays.com/";
      sha256 = "2ed43ae4bb84d74dcae6f0099210dfa8d61bfea4952f5f9a07a9aae16cb70f82";
    };

    desktopItem = pkgs.makeDesktopItem {
      name = "ida-pro";
      exec = "ida";
      comment = meta.description;
      desktopName = "IDA Pro";
      genericName = "Interactive Disassembler";
      categories = [ "Development" ];
      startupWMClass = "IDA";
    };
    desktopItems = [ desktopItem ];

    nativeBuildInputs = with pkgs; [
      makeWrapper
      copyDesktopItems
      autoPatchelfHook
      qt6.wrapQtAppsHook
      perl
    ];

    # We just get a runfile in $src, so no need to unpack it.
    dontUnpack = true;

    # Add everything to the RPATH, in case IDA decides to dlopen things.
    runtimeDependencies = with pkgs; [
      cairo
      dbus
      fontconfig
      freetype
      glib
      gtk3
      libdrm
      libGL
      libkrb5
      libsecret
      qt6.qtbase
      qt6.qtwayland
      libunwind
      libxkbcommon
      openssl.out
      stdenv.cc.cc
      libice
      libsm
      libx11
      libxau
      libxcb
      libxext
      libxi
      libxrender
      libxcb-image
      libxcb-keysyms
      libxcb-render-util
      libxcb-wm
      zlib
      curl.out
      pythonForIDA
    ];
    buildInputs = runtimeDependencies;

    dontWrapQtApps = true;

    installPhase = ''
      runHook preInstall

      function print_debug_info() {
        if [ -f installbuilder_installer.log ]; then
          cat installbuilder_installer.log
        else
          echo "No debug information available."
        fi
      }

      trap print_debug_info EXIT

      mkdir -p $out/bin $out/lib $out/opt/.local/share/applications

      # IDA depends on quite some things extracted by the runfile, so first extract everything
      # into $out/opt, then remove the unnecessary files and directories.
      IDADIR="$out/opt"
      # IDA doesn't always honor `--prefix`, so we need to hack and set $HOME here.
      HOME="$out/opt"

      # Invoke the installer with the dynamic loader directly, avoiding the need
      # to copy it to fix permissions and patch the executable.
      $(cat $NIX_CC/nix-support/dynamic-linker) $src \
        --mode unattended --debuglevel 4 --prefix $IDADIR

      # Apply hex patches before linking/patchelf so $out/lib reflects them.
      ${patchScript}

      # Link the exported libraries to the output.
      for lib in $IDADIR/*.so $IDADIR/*.so.6; do
        ln -s $lib $out/lib/$(basename $lib)
      done

      # Manually patch libraries that dlopen stuff.
      patchelf --add-needed libpython3.13.so $out/lib/libida.so
      patchelf --add-needed libcrypto.so $out/lib/libida.so
      patchelf --add-needed libsecret-1.so.0 $out/lib/libida.so

      # Some libraries come with the installer.
      addAutoPatchelfSearchPath $IDADIR

      # Link the binaries to the output.
      # Also, hack the PATH so that pythonForIDA is used over the system python.
      for bb in ida; do
        wrapProgram $IDADIR/$bb \
          --prefix IDADIR : $IDADIR \
          --prefix QT_PLUGIN_PATH : $IDADIR/plugins/platforms \
          --prefix PYTHONPATH : $out/bin/idalib/python \
          --prefix PATH : ${pythonForIDA}/bin:$IDADIR \
          --prefix LD_LIBRARY_PATH : $out/lib
        ln -s $IDADIR/$bb $out/bin/$bb
      done

      runHook postInstall
    '';

    meta = with lib; {
      description = "The world's smartest and most feature-full disassembler";
      homepage = "https://hex-rays.com/ida-pro/";
      license = licenses.unfree;
      mainProgram = "ida";
      maintainers = with maintainers; [ msanft ];
      platforms = [ "x86_64-linux" ]; # Right now, the installation script only supports Linux.
      sourceProvenance = with sourceTypes; [ binaryNativeCode ];
    };
  };
in
{
  environment.systemPackages = [ ida-pro ];
}
