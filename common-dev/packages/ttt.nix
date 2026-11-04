{ lib, buildGoModule, fetchFromGitHub }:

buildGoModule rec {
  # Tracks HEAD of main rather than a tagged release; bump rev and both hashes
  # to the current commit when updating.
  pname = "ttt";
  version = "unstable-2026-11-04";

  src = fetchFromGitHub {
    owner = "eugenioenko";
    repo = "ttt";
    rev = "82bb3eeae6210a99d755ef828241f38f802005ff";
    hash = "sha256-JzWi95+3LuBFuhA9NLnT+PUoDGE8emjw37VfFxOEino=";
  };

  vendorHash = "sha256-Rlv/akRDQwbbpGblCaVoWRPQnspg0Ijt7bpm3jYmDeE=";
  subPackages = [ "cmd/ttt" ];
  env.CGO_ENABLED = "0";
  ldflags = [ "-s" "-w" "-X main.version=${version}" ];

  meta = {
    description = "Terminal text editor with IDE features";
    homepage = "https://github.com/eugenioenko/ttt";
    license = lib.licenses.mit;
    mainProgram = "ttt";
    platforms = lib.platforms.linux;
  };
}
