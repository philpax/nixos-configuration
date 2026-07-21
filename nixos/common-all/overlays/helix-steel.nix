# Helix with the Steel plugin system, from mattwparas' fork (upstream tracks it in
# helix-editor/helix#8675). Revert to nixpkgs `helix` if/when Steel lands upstream.
#
# Built by overriding nixpkgs' `helix-unwrapped` rather than vendoring the fork's own
# default.nix: the fork's expression refers to ./runtime, ./contrib and ./languages.toml
# relative to itself (all broken by a .git-less fetchFromGitHub src), and its grammars.nix
# resolves ~200 grammars with eval-time `builtins.fetchTree`, which would hit the network
# on every rebuild. Overriding keeps nixpkgs' hash-pinned, binary-cached grammar farm.
#
# `steel` is already in helix-term's *default* feature set in the fork, so no
# cargoBuildFeatures are needed. `cargo xtask steel` is deliberately not run: it shells out
# to `cargo install` and `forge pkg refresh` (network + ~/.cargo writes, both fatal in the
# sandbox), and its codegen step emits no Rust — the scheme modules are include_str!'d into
# the binary. That codegen only writes .scm stubs into $STEEL_HOME for the language server,
# which is a post-install user concern, not a build input.
final: prev:
let
  rev = "8d189f46e9c620baa685bdfbe39b7c95928475a0";
  shortRev = builtins.substring 0 7 rev;

  src = final.fetchFromGitHub {
    owner = "mattwparas";
    repo = "helix";
    inherit rev;
    hash = "sha256-qYR2f+uSUNsJYbbwSo9bCB+LI7n3NzQDCHXJRmHztDg=";
  };

  unwrapped = prev.helix-unwrapped.overrideAttrs (old: {
    pname = "helix-steel-unwrapped";
    version = "25.7.1-steel-${shortRev}";
    inherit src;

    # The fork takes steel-core as a *git* dependency, so a flat cargoHash can't work.
    # Cargo.lock pulls several steel crates, but all from one repo at one rev, and
    # import-cargo-lock re-keys outputHashes by commit SHA — hence a single entry.
    cargoDeps = final.rustPlatform.importCargoLock {
      lockFile = "${src}/Cargo.lock";
      outputHashes = {
        "steel-core-0.8.2" = "sha256-vR2izfAXC0oidNtyIzdge04BV6C36wrg1qDDzEKAPeg=";
      };
    };

    # nixpkgs' helix-unwrapped patches target its pinned release and don't apply to the fork.
    patches = [ ];
    postPatch = "";

    # Drop the book: it exists only to populate the `doc` output, and building it pulls
    # mdbook into a fork whose book sources have diverged from what that patch expects.
    outputs = [ "out" ];
    postBuild = "";
    # Filter mdbook out rather than rebuilding this list: buildRustPackage injects its
    # cargo hooks through nativeBuildInputs, so replacing it wholesale drops
    # cargoSetupHook/cargoBuildHook/cargoInstallHook and the build silently compiles
    # nothing ("no Makefile or custom buildPhase, doing nothing") while still installing.
    nativeBuildInputs = builtins.filter (p: p != final.mdbook) old.nativeBuildInputs;
    postInstall = ''
      installShellCompletion contrib/completion/hx.{bash,fish,zsh}
      mkdir -p $out/share/{applications,icons/hicolor/256x256/apps}
      cp contrib/Helix.desktop $out/share/applications/Helix.desktop
      cp contrib/helix.png $out/share/icons/hicolor/256x256/apps/helix.png
    '';

    # versionCheckHook greps `hx --version`, which the fork reports as the plain upstream
    # version — it knows nothing about our "-steel-" suffix.
    doInstallCheck = false;
  });
in
{
  # Steel plugins ("cogs") are NOT fetched here — they're git submodules under steel-cogs/
  # in this repo, symlinked into $STEEL_HOME/cogs by sync.py. This overlay only builds the
  # editor.
  helix-steel-unwrapped = unwrapped;

  # The wrapper takes helix-unwrapped as an argument, so overriding it reuses nixpkgs'
  # tree-sitter grammar farm and HELIX_RUNTIME wiring verbatim.
  helix-steel = prev.helix.override { helix-unwrapped = unwrapped; };
}
