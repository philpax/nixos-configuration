{ lib, buildGoModule, fetchFromGitHub }:

buildGoModule rec {
  pname = "ttt";
  version = "1.7.1";

  src = fetchFromGitHub {
    owner = "eugenioenko";
    repo = "ttt";
    rev = "v${version}";
    hash = "sha256-LcSmUntNXmw+2jA8NLMgnAKObSlF2wknLinAuJxD5aw=";
  };

  vendorHash = "sha256-+mbwJO7J6t584r3rhPsxj9eVfKFOffoWydKJrFNwA2c=";
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
