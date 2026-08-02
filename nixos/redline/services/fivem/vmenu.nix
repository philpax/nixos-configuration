# vMenu, built from source so that its client-side settings can be given
# server-appropriate starting values, and so saved peds can be a default.
#
# vMenu keeps per-player settings in FiveM's client KVP store. It has no
# convar or ace for any of them, seeds a default only when a key is absent,
# and persists a change only when the player explicitly picks Misc Settings >
# Save Personal Settings. So the only way to set them for people who have
# already run vMenu is to write the store directly, from inside vMenu's own
# resource. The patch does that; see it for the list.
#
# Upstream CI builds on windows-latest only; this builds on Linux and produces
# the same file tree as the published release zip. If a version bump breaks
# that, diffing `ls` against the zip is the fastest way to see how.
{
  lib,
  stdenvNoCC,
  fetchFromGitHub,
  fetchurl,
  linkFarm,
  dotnet-sdk_8,
}:

let
  version = "3.8.50";

  # The complete NuGet closure, from vMenu/obj/project.assets.json.
  nupkgs = [
    {
      pname = "citizenfx.core.client";
      version = "1.0.10188";
      hash = "sha256-3ulHX4J1g0rUyhr6vApkN1Fsl5Y2MNX92nNEW4H+cCc=";
    }
    {
      pname = "citizenfx.core.server";
      version = "1.0.8883";
      hash = "sha256-9fzyRbwLFBZVKNKf13/uvYOH1+VpysTR0eA3QYGbzaM=";
    }
    {
      pname = "menuapi.fivem";
      version = "3.2.4";
      hash = "sha256-iE8/k+6J6lMh3zS5zfo3tFqjgDuRDd+n2fSlfNmYSOI=";
    }
    # Added by the postPatch below; a .NET Framework target cannot be built
    # off-Windows without these.
    {
      pname = "microsoft.netframework.referenceassemblies";
      version = "1.0.3";
      hash = "sha256-FBoJP5DHZF0QHM0xLm9yd4HJZVQOuSpSKA+VQRpphEE=";
    }
    {
      pname = "microsoft.netframework.referenceassemblies.net452";
      version = "1.0.3";
      hash = "sha256-RTPuFG8D7gnwINEoEtAqmVm4oTW8K4Z87v1o4DDeLMI=";
    }
    {
      pname = "microsoft.netframework.referenceassemblies.net462";
      version = "1.0.3";
      hash = "sha256-7mkqhFdDUAkQhV1MMwym6e+HwW4W90DkR00YcYXWbiE=";
    }
  ];

  nugetSource = linkFarm "vmenu-nupkgs" (
    map (p: {
      name = "${p.pname}.${p.version}.nupkg";
      path = fetchurl {
        url = "https://api.nuget.org/v3-flatcontainer/${p.pname}/${p.version}/${p.pname}.${p.version}.nupkg";
        inherit (p) hash;
      };
    }) nupkgs
  );
in
stdenvNoCC.mkDerivation {
  pname = "vmenu";
  inherit version;

  src = fetchFromGitHub {
    owner = "TomGrobbe";
    repo = "vMenu";
    rev = "v${version}";
    hash = "sha256-vkPVVhtJ6o3lSKx2KaU5o1AI+pM97YZsl2mdPcTvpj8=";
  };

  nativeBuildInputs = [ dotnet-sdk_8 ];

  # Three changes, all in one patch:
  #
  # - Forces this server's preferred settings once per client, from a static
  #   constructor on UserDefaults. The list and reasoning live there.
  # - Adds "Set As Default Ped" to the Saved Peds menu, honoured on join and
  #   on death. vMenu's stock default-character feature only covers MP Ped
  #   Customization characters (stored "mp_ped_"-prefixed); saved peds are
  #   arbitrary models under "ped_" and had no default of their own, so a
  #   saved ped as your default also produced an error on every death.
  # - Fixes SetAppearanceOnFirstSpawn consuming its firstSpawn flag before
  #   checking the menus exist. The menus are built after a server round-trip,
  #   so a slow handshake made it skip the whole feature for the session.
  patches = [ ./vmenu-redline.patch ];

  postPatch = ''
    # vMenuClient targets net462 and vMenuServer net452. Neither builds
    # off-Windows without reference assemblies, which upstream gets from the
    # OS and we have to pull from NuGet. Anchored on the closing tag because
    # it is the one element that appears exactly once — substituteInPlace
    # replaces every match, and a duplicated PackageReference is an error.
    for proj in vMenu/vMenuClient.csproj vMenuServer/vMenuServer.csproj; do
      substituteInPlace "$proj" --replace-fail '</Project>' \
        '<ItemGroup><PackageReference Include="Microsoft.NETFramework.ReferenceAssemblies" Version="1.0.3" PrivateAssets="all" /></ItemGroup></Project>'
    done
  '';

  buildPhase = ''
    runHook preBuild

    export HOME="$TMPDIR/home"
    export DOTNET_CLI_TELEMETRY_OPTOUT=1
    export DOTNET_NOLOGO=1
    export DOTNET_SKIP_FIRST_TIME_EXPERIENCE=1
    mkdir -p "$HOME"

    cat > nuget.config <<EOF
    <?xml version="1.0" encoding="utf-8"?>
    <configuration>
      <packageSources>
        <clear />
        <add key="vendored" value="${nugetSource}" />
      </packageSources>
    </configuration>
    EOF

    dotnet restore vMenu.sln \
      --packages "$TMPDIR/nuget-packages" \
      --configfile nuget.config

    dotnet build vMenu.sln \
      --configuration Release \
      --no-restore \
      -p:Version=${version}

    runHook postBuild
  '';

  # Mirrors the copies the upstream release workflow does after building.
  # Without fxmanifest.lua, FXServer won't recognise this as a resource.
  installPhase = ''
    runHook preInstall

    mkdir -p $out
    cp -r build/vMenu/. $out/
    cp README.md LICENSE.md $out/

    substitute assets/fxmanifest.lua $out/fxmanifest.lua \
      --replace-fail versiongoeshere "${version}"

    runHook postInstall
  '';

  meta = {
    description = "Server-sided trainer for FiveM, with redline's client defaults";
    homepage = "https://github.com/TomGrobbe/vMenu";
    license = lib.licenses.mit;
    platforms = lib.platforms.linux;
  };
}
