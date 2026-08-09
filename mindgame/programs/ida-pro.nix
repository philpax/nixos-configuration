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

  # Prebuilt BinDiff 8 / BinExport 12 plugins for the IDA 9.3 SDK, from
  # Lil-Ran's CI builds (built on Ubuntu 24.04). Each archive holds the IDA
  # plugin under `ida/`, alongside tool binaries we don't install here.
  bindiffZip = pkgs.fetchurl {
    url = "https://github.com/Lil-Ran/build-bindiff-for-ida-9/releases/download/release-20260302-1/BinDiff-IDA_9.3-x86_64-linux-built_on_ubuntu_24.04.zip";
    sha256 = "885dd92ac46aa92ccb831dbeb6c67d4828bf2cea9ceb257856dfb64164e03069";
  };
  binexportZip = pkgs.fetchurl {
    url = "https://github.com/Lil-Ran/build-bindiff-for-ida-9/releases/download/release-20260302-1/BinExport-IDA_9.3-x86_64-linux-built_on_ubuntu_24.04.zip";
    sha256 = "cd888487f2c7265918204e0f5cc428624c87b5f40511d35230a075131e876521";
  };

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

  # The licensed installer, added to the store manually with
  #   nix-store --add-fixed sha256 ida-pro_93_x64linux.run
  # It's only a build-time input to ida-pro, so it's kept alive against
  # `nix-collect-garbage` by a GC root (see systemd.tmpfiles below) — otherwise
  # the next GC deletes it and the build fails until it's re-added by hand.
  installerSrc = pkgs.requireFile {
    name = "ida-pro_93_x64linux.run";
    url = "https://my.hex-rays.com/";
    sha256 = "2ed43ae4bb84d74dcae6f0099210dfa8d61bfea4952f5f9a07a9aae16cb70f82";
  };

  ida-pro = pkgs.stdenv.mkDerivation rec {
    pname = "ida-pro";
    version = "9.3.260213";

    src = installerSrc;

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
      unzip
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

      # Drop the BinDiff / BinExport plugins into IDA's plugins directory. These
      # are prebuilt against Ubuntu's glibc; autoPatchelfHook (postFixup) rewrites
      # their RPATH against IDA's own libraries (see addAutoPatchelfSearchPath
      # below) and the buildInputs. `-j` flattens the `ida/` prefix.
      mkdir -p "$IDADIR/plugins"
      unzip -j -o ${bindiffZip} 'ida/*.so' -d "$IDADIR/plugins"
      unzip -j -o ${binexportZip} 'ida/*.so' -d "$IDADIR/plugins"

      # Install the BinDiff core engine and CLI tools in a self-contained
      # directory laid out the way BinDiff expects: the IDA plugin launches
      # "<directory>/bin/bindiff", where <directory> comes from bindiff.json
      # (wired up via environment.etc below). autoPatchelfHook fixes their
      # interpreter/RPATH; they only need libstdc++ and glibc.
      mkdir -p "$IDADIR/bindiff/bin"
      unzip -j -o ${bindiffZip} 'bindiff' 'tools/bindiff_config_setup' -d "$IDADIR/bindiff/bin"
      unzip -j -o ${binexportZip} 'tools/binexport2dump' -d "$IDADIR/bindiff/bin"
      chmod +x "$IDADIR"/bindiff/bin/*
      for b in bindiff binexport2dump bindiff_config_setup; do
        ln -s "$IDADIR/bindiff/bin/$b" "$out/bin/$b"
      done

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

  # --- Headless idalib-mcp helpers -------------------------------------------
  #
  # idalib's libidalib.so is linked against IDA's bundled Python (pythonForIDA),
  # so the ida-pro-mcp project venv must be built from that exact interpreter or
  # init_library() segfaults. `ida-mcp-setup` (re)creates that venv and refreshes
  # the IDADIR config; `ida-mcp` launches the server with IDADIR baked in, so it
  # survives IDA-only rebuilds without re-running setup. After a python313/IDA
  # rebuild, re-run `ida-mcp-setup`.

  idaMcpSetup = pkgs.writeShellScriptBin "ida-mcp-setup" ''
    set -euo pipefail
    PROJECT="''${IDA_PRO_MCP_DIR:-$HOME/programming/ida-pro-mcp}"
    cd "$PROJECT"

    PYBIN="${pythonForIDA}/bin/python3.13"
    IDADIR="${ida-pro}/opt"

    echo ">> pinning project venv to IDA's python: $PYBIN"
    uv python pin "$PYBIN"
    # Not our repo; keep the machine-specific pin out of git status.
    if [ -d .git ] && [ -f .git/info/exclude ]; then
      grep -qxF .python-version .git/info/exclude || echo .python-version >> .git/info/exclude
    fi

    echo ">> uv sync"
    uv sync

    echo ">> activating idalib (refreshes ~/.idapro/ida-config.json -> $IDADIR)"
    uv run "$IDADIR/idalib/python/py-activate-idalib.py"

    echo
    echo "Done. Start the MCP server with:  ida-mcp --stdio"
  '';

  idaMcp = pkgs.writeShellScriptBin "ida-mcp" ''
    export IDADIR="${ida-pro}/opt"
    exec uv run --directory "''${IDA_PRO_MCP_DIR:-$HOME/programming/ida-pro-mcp}" idalib-mcp "$@"
  '';
in
{
  environment.systemPackages = [ ida-pro idaMcpSetup idaMcp ];

  # BinDiff looks for /etc/opt/bindiff/bindiff.json before ~/.bindiff/bindiff.json.
  # Provide it system-wide so the IDA plugin finds the bundled engine without any
  # per-user setup: `directory` is the BinDiff install root (engine at its
  # bin/bindiff), `ida.directory` is the IDA install. Partial configs merge over
  # BinDiff's built-in defaults, and regenerating it here keeps the store paths
  # current across rebuilds.
  environment.etc."opt/bindiff/bindiff.json".text = builtins.toJSON {
    directory = "${ida-pro}/opt/bindiff";
    ida.directory = "${ida-pro}/opt";
  };

  # Pin the licensed installer as a GC root. It's a build-only input, so without
  # this `nix-collect-garbage` reclaims it and the next rebuild fails until it's
  # manually re-added from backup. `L+` recreates the symlink if the target moves.
  systemd.tmpfiles.rules = [
    "L+ /nix/var/nix/gcroots/ida-pro-installer - - - - ${installerSrc}"
  ];
}
