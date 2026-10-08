{ system ? "aarch64-linux", nixpkgsPin ? ./nixpkgs.json, overrides ? null }:
let
  fail = message: throw "frame-cli: ${message}";
  pinValue = if builtins.isAttrs nixpkgsPin then nixpkgsPin
    else builtins.fromJSON (builtins.readFile nixpkgsPin);
  pin = if builtins.isAttrs pinValue
    && builtins.attrNames pinValue == [ "rev" "sha256" ]
    && builtins.isString pinValue.rev
    && builtins.match "[0-9a-f]{40}" pinValue.rev != null
    && builtins.isString pinValue.sha256
    && builtins.match "sha256-[A-Za-z0-9+/]{43}=" pinValue.sha256 != null
    then pinValue else fail "nixpkgs pin must contain a complete rev and sha256 NAR hash";
  source = builtins.fetchTarball {
    url = "https://github.com/NixOS/nixpkgs/archive/${pin.rev}.tar.gz";
    sha256 = pin.sha256;
  };
  pkgs = import source {
    inherit system;
    config.allowUnfree = true;
    overlays = [ (import ../common-all/overlays/helix-steel.nix) ];
  };
  lib = pkgs.lib;
  runtimePackages = import ../common-all/packages/runtime.nix { inherit pkgs; };
  defaultCliPackages = lib.concatMap (path: import path { inherit pkgs; }) [
    ../common-all/packages/system.nix
    ../common-all/packages/development.nix
    ../common-all/packages/network.nix
    ../common-all/packages/media.nix
    ../common-all/packages/helix.nix
    ../common-dev/packages/development.nix
    ../common-all/packages/runtime.nix
  ];
  defaultFontPackages = import ../common-desktop/packages/fonts.nix { inherit pkgs; };
  overrideFile = if overrides == null || builtins.isFunction overrides then null
    else if builtins.isPath overrides || builtins.isString overrides then overrides
    else fail "overrides must be a function or a path to a function";
  overrideFunction = if overrides == null then null
    else if builtins.isFunction overrides then overrides else import overrideFile;
  effective = if overrides == null then {
    cliPackages = defaultCliPackages;
    fontPackages = defaultFontPackages;
  } else if builtins.isFunction overrideFunction then overrideFunction {
    inherit pkgs;
    cliPackages = defaultCliPackages;
    fontPackages = defaultFontPackages;
  } else fail "overrides must be a function accepting { pkgs, cliPackages, fontPackages }";
  validList = value: builtins.isList value && builtins.all lib.isDerivation value;
  validated = if builtins.isAttrs effective
    && builtins.attrNames effective == [ "cliPackages" "fontPackages" ]
    && validList effective.cliPackages && validList effective.fontPackages
    then effective else fail "overrides must return exactly cliPackages and fontPackages derivation lists";
  hasRuntime = builtins.all (required:
    builtins.any (package: package.outPath == required.outPath) validated.cliPackages
  ) runtimePackages;
  cliPackages = if hasRuntime then validated.cliPackages
    else fail "overrides removed required entry/runtime packages";
  fontPackages = validated.fontPackages;
  # Deduplicate exact output selections, not package names or derivation paths.
  uniqueOutputs = packages: lib.foldl' (acc: package:
    if builtins.any (old: old.outPath == package.outPath) acc then acc else acc ++ [ package ]
  ) [ ] packages;
  selectedCliOutputs = uniqueOutputs cliPackages;
  selectedFontOutputs = uniqueOutputs fontPackages;
  outputRecord = kind: index: package: {
    inherit kind;
    name = package.name;
    output = package.outputName or "out";
    path = package.outPath;
    reference = "${kind}-${toString index}-${lib.strings.sanitizeDerivationName package.name}-${package.outputName or "out"}";
  };
  outputManifest = lib.imap0 (outputRecord "cli") selectedCliOutputs;
  # Companion declarations extend the selected output's traversal roots, not its inventory.
  # Trusted user overrides can declare other dependencies through passthru.frameFontCompanions.
  fontCompanions = package:
    let
      declared = package.frameFontCompanions or [ ];
      dejavu = lib.optional ((package.pname or "") == "dejavu-fonts"
        && package ? minimal && lib.isDerivation package.minimal) package.minimal;
    in if validList declared then uniqueOutputs (dejavu ++ declared)
       else fail "font passthru.frameFontCompanions must be a derivation list";
  fontManifest = lib.imap0 (index: package:
    let
      record = outputRecord "font" index package;
      companions = lib.imap0 (companionIndex: companion:
        (outputRecord "font-companion" companionIndex companion) // {
          reference = "font-companions/${record.reference}-${toString companionIndex}-${lib.strings.sanitizeDerivationName companion.name}-${companion.outputName or "out"}";
        }
      ) (fontCompanions package);
    in record // { reference = "fonts/${record.reference}"; }
      // lib.optionalAttrs (companions != [ ]) { inherit companions; }
  ) selectedFontOutputs;
  ocean = pkgs.kdePackages.ocean-sound-theme;
  assetManifest = {
    fonts = fontManifest;
    bell = {
      name = ocean.name;
      output = ocean.outputName or "out";
      path = ocean.outPath;
      reference = "bell";
      relativePath = "share/sounds/ocean/stereo/bell-window-system.oga";
    };
  };
  overrideText = if overrideFile == null then null else builtins.readFile overrideFile;
  buildInfo = {
    schemaVersion = 1;
    inherit system;
    nixpkgs = pin // { path = toString source; };
    overrides = if overrides == null then null else {
      kind = if builtins.isFunction overrides then "function" else "file";
      sha256 = if overrideText == null then null else builtins.hashString "sha256" overrideText;
      source = if overrideText == null then null else "overrides.nix";
    };
    cliPackages = outputManifest;
    fontPackages = assetManifest.fonts;
    assets = assetManifest;
  };
  metadata = pkgs.runCommand "frame-cli-metadata" { } ''
    mkdir -p "$out/share/frame-cli/outputs" "$out/share/frame-cli/assets/fonts" "$out/share/frame-cli/assets/font-companions"
    cp ${pkgs.writeText "frame-cli-build-info.json" (builtins.toJSON buildInfo)} "$out/share/frame-cli/build-info.json"
    cp ${pkgs.writeText "frame-cli-output-manifest.json" (builtins.toJSON outputManifest)} "$out/share/frame-cli/output-manifest.json"
    cp ${pkgs.writeText "frame-cli-assets.json" (builtins.toJSON assetManifest)} "$out/share/frame-cli/assets.json"
    cp ${pkgs.writeText "frame-cli-nixpkgs.json" (builtins.toJSON pin)} "$out/share/frame-cli/nixpkgs.json"
    ln -s ${lib.escapeShellArg (toString source)} "$out/share/frame-cli/nixpkgs"
    ${lib.concatMapStringsSep "\n" (record:
      "ln -s ${lib.escapeShellArg record.path} \"$out/share/frame-cli/outputs/${record.reference}\""
    ) outputManifest}
    ${lib.concatMapStringsSep "\n" (record:
      "ln -s ${lib.escapeShellArg record.path} \"$out/share/frame-cli/assets/${record.reference}\""
    ) (lib.concatMap (record: [ record ] ++ (record.companions or [ ])) assetManifest.fonts)}
    ln -s ${lib.escapeShellArg ocean.outPath} "$out/share/frame-cli/assets/bell"
    ${lib.optionalString (overrideText != null) ''
      cp ${pkgs.writeText "frame-cli-overrides.nix" overrideText} "$out/share/frame-cli/overrides.nix"
    ''}
  '';
  # Profile priorities are local metadata; the original package outputs stay rooted.
  # GCC wins cc/c++ and shared compiler files; clang and clang++ remain available.
  profilePackage = package:
    let priority = if package.outPath == pkgs.gcc.outPath then 4
      else if package.outPath == pkgs.clang.outPath then 6
      else package.meta.priority or 5;
    in lib.setPrio priority (package // {
      meta = (package.meta or { }) // { outputsToInstall = [ (package.outputName or "out") ]; };
    });
  profile = pkgs.buildEnv {
    name = "frame-cli";
    paths = builtins.map profilePackage selectedCliOutputs ++ [ metadata ];
    pathsToLink = [
      "/bin" "/sbin" "/share/man" "/share/fish" "/share/info"
      "/etc/ssl/certs" "/include" "/lib/pkgconfig" "/share/pkgconfig" "/share/frame-cli"
    ];
    ignoreCollisions = false;
  };
in
assert builtins.elem system [ "aarch64-linux" "x86_64-linux" ] || fail "unsupported system ${system}";
profile.overrideAttrs (old: {
  passthru = (old.passthru or { }) // {
    inherit profile pkgs source pin cliPackages fontPackages runtimePackages
      defaultCliPackages defaultFontPackages outputManifest assetManifest buildInfo;
  };
})
