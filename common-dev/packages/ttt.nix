{ lib, buildGoModule, fetchFromGitHub }:

buildGoModule rec {
  # Tracks HEAD of main rather than a tagged release; bump rev and both hashes
  # to the current commit when updating.
  pname = "ttt";
  version = "unstable-2026-10-26";

  src = fetchFromGitHub {
    owner = "eugenioenko";
    repo = "ttt";
    rev = "a78ce492370d23f46715f08ab1a465efe18c28a7";
    hash = "sha256-recObA4jwbfsntDhwoiq6k49usqtJLTTuncs47u43t8=";
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
