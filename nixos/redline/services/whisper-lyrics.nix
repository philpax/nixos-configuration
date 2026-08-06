# GPU transcription sidecar for AudioMuse-AI's lyrics pipeline: fills its
# external-lyrics-API slot so its internal CPU-bound Whisper decoder never
# runs. See services/whisper-lyrics/server.py for the protocol.
#
# The model (~1.6GB) is downloaded from HuggingFace into the state dir on
# first start, so the first activation needs network and a few minutes.
{ config, lib, pkgs, ... }:

let
  secrets = import ../secrets/audiomuse.nix;
  port = 8801;

  ctranslate2Cuda = pkgs.ctranslate2.override {
    withCUDA = true;
    withCuDNN = true;
  };
  pyEnv = pkgs.python3.withPackages (ps: [
    (ps.faster-whisper.override {
      ctranslate2 = ps.ctranslate2.override { ctranslate2-cpp = ctranslate2Cuda; };
    })
  ]);
in
{
  systemd.services.whisper-lyrics = {
    description = "faster-whisper lyrics transcription service";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    wantedBy = [ "multi-user.target" ];
    environment = {
      NAVIDROME_URL = "http://127.0.0.1:4533";
      NAVIDROME_USER = "audiomuse";
      NAVIDROME_PASSWORD = secrets.navidromePassword;
      API_KEY = secrets.lyricsApiKey;
      WHISPER_MODEL = "large-v3-turbo";
      PORT = toString port;
      # GPU 1: audiomuse's own containers pin GPU 0 (flask) and alternate
      # workers; transcription is bursty and coexists fine with ComfyUI.
      CUDA_VISIBLE_DEVICES = "1";
      HF_HOME = "/var/lib/whisper-lyrics/hf";
      # libcuda (the driver stub) lives outside the nix store on NixOS.
      LD_LIBRARY_PATH = "/run/opengl-driver/lib";
    };
    serviceConfig = {
      ExecStart = "${pyEnv}/bin/python ${./whisper-lyrics/server.py}";
      DynamicUser = true;
      StateDirectory = "whisper-lyrics";
      Restart = "on-failure";
      RestartSec = 10;
      # Model load (and first-start download) happens before the port binds.
      TimeoutStartSec = "15m";
    };
  };

  # Reached by the audiomuse containers via host.docker.internal, which
  # traverses the host firewall; the API key gates actual use.
  networking.firewall.allowedTCPPorts = [ port ];
}
