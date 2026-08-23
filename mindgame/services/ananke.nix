# Runs under the interactive user rather than redline's dedicated `ai`
# user — mindgame is a personal desktop.
#
# Every service runs its workload in a container ananke drives itself
# (`[service.container]`): ananke creates, starts, follows logs, reads the
# exit status, signals, removes, and reconciles leftovers on restart.
{ config, pkgs, ... }:

let
  lib = pkgs.lib;
  anankeLib = import ../../common-all/ananke-lib.nix { inherit lib; };
  inherit (anankeLib) flagArgs roMount;
  inherit (import ../../common-all/container-images.nix { inherit pkgs lib; })
    mkSourceImage mkImageService;

  home = config.users.users.${config.mainUser}.home;
  anankeDir = "${home}/programming/ananke";

  hfCache = "${home}/.cache/huggingface";

  # Where ninfer's artifacts land inside the container.
  artifactsIn = "/artifacts";

  images = {
    # Built from ninfer's own Dockerfile — a CUDA source build, so the
    # first run after a bump takes a while. Pinned rather than pointed at
    # a working tree, so the tag says which commit is running.
    #
    # This revision is the floor for the Qwen3.8 NVFP4 profile: the binder
    # and FP8 execution leaves it selects landed in 5d2c1f5, so the older
    # pin loads every other artifact here but not that one.
    ninfer = mkSourceImage {
      name = "ninfer";
      src = pkgs.fetchFromGitHub {
        owner = "Neroued";
        repo = "ninfer";
        rev = "5f45a26f81b6a15805a3d4d09d5c3d60f420b210";
        hash = "sha256-fGyHdZOkKRTsarkHkUxYigZT2v1J+Fq/t3V3eOpAdL8=";
      };
    };
  };

  # The model roster, hoisted so both `mkAnankeConfig` (below) and
  # `clientModels` (further below) can reference it.
  models = [
    # Vision freezes at startup, so each model has a separate text/vision
    # pair; DFlash is 35B-A3B-only and text-only, so its vision pair uses
    # MTP instead. Context and vram figures come from empirical
    # --max-concurrency 1 sizing trials on this GPU.
    {
      kind = "ninfer";
      name = "qwen3.6-27b-ninfer-mtp3";
      upstreamModel = "qwen3.6-27b";
      artifact = "qwen3_6_27b_nvfp4.ninfer";
      vramGb = 25;
      perGpuMib = 25500;
      maxContext = 196608;
      spec = "mtp";
      draftTokens = 3;
      description = "Qwen3.6-27B (NVFP4) served by ninfer (MTP=3, 196608 ctx, text-only).";
      client = {
        class = "medium";
        roles = [ "full" "mini" ];
        reasoning = { type = "thinking"; };
        max_output_tokens = 32768;
      };
    }
    {
      kind = "ninfer";
      name = "qwen3.6-27b-ninfer-mtp3-vision";
      upstreamModel = "qwen3.6-27b";
      artifact = "qwen3_6_27b_nvfp4.ninfer";
      vramGb = 26;
      perGpuMib = 26500;
      maxContext = 147456;
      spec = "mtp";
      draftTokens = 3;
      vision = true;
      description = "Qwen3.6-27B (NVFP4) served by ninfer (MTP=3, 147456 ctx, vision).";
      client = {
        class = "medium";
        reasoning = { type = "thinking"; };
        max_output_tokens = 32768;
      };
    }
    {
      kind = "ninfer";
      name = "qwen3.6-35b-a3b-ninfer-dflash7";
      upstreamModel = "qwen3.6-35b-a3b";
      artifact = "qwen3_6_35b_a3b.ninfer";
      vramGb = 26;
      perGpuMib = 26500;
      maxContext = 262144;
      spec = "dflash";
      draftTokens = 7;
      description = "Qwen3.6-35B-A3B served by ninfer (DFlash=7, 262144 ctx, text-only).";
      client = {
        class = "medium";
        roles = [ "nano" ];
        reasoning = { type = "thinking"; };
        max_output_tokens = 32768;
      };
    }
    {
      kind = "ninfer";
      name = "qwen3.6-35b-a3b-ninfer-mtp3-vision";
      upstreamModel = "qwen3.6-35b-a3b";
      artifact = "qwen3_6_35b_a3b.ninfer";
      vramGb = 26;
      perGpuMib = 26500;
      maxContext = 163840;
      spec = "mtp";
      draftTokens = 3;
      vision = true;
      description = "Qwen3.6-35B-A3B served by ninfer (MTP=3, 163840 ctx, vision).";
      client = {
        class = "medium";
        reasoning = { type = "thinking"; };
        max_output_tokens = 32768;
      };
    }
    # The NVFP4 weight profile of the Qwen3.8-27B target: 20.02 GiB of
    # weights against the groupwise-int build's 16.96, and 26 GiB is
    # already the ceiling this desktop leaves, so the extra comes out of
    # context.
    #
    # Both contexts are the largest that loaded against a ~4.3 GiB desktop
    # baseline. ninfer sizes its reservation up front, so if the desktop
    # grows these refuse to start rather than failing partway through.
    {
      kind = "ninfer";
      name = "qwen3.8-27b-nvfp4-ninfer-mtp3";
      upstreamModel = "qwen3.8-27b";
      artifact = "qwen3_8_27b_nvfp4.ninfer";
      vramGb = 26;
      perGpuMib = 26500;
      maxContext = 180224;
      spec = "mtp";
      draftTokens = 3;
      description = "Qwen3.8-27B (NVFP4) served by ninfer (MTP=3, 180224 ctx, text-only).";
      client = {
        class = "medium";
        reasoning = { type = "thinking"; };
        max_output_tokens = 32768;
      };
    }
    {
      kind = "ninfer";
      name = "qwen3.8-27b-nvfp4-ninfer-mtp3-vision";
      upstreamModel = "qwen3.8-27b";
      artifact = "qwen3_8_27b_nvfp4.ninfer";
      vramGb = 26;
      perGpuMib = 26500;
      maxContext = 122880;
      spec = "mtp";
      draftTokens = 3;
      vision = true;
      description = "Qwen3.8-27B (NVFP4) served by ninfer (MTP=3, 122880 ctx, vision).";
      client = {
        class = "medium";
        reasoning = { type = "thinking"; };
        max_output_tokens = 32768;
      };
    }
  ];

  inherit (anankeLib.mkAnankeConfig {
    inherit pkgs anankeDir;
    openaiPort = anankeLib.ports.openai;
    managementPort = anankeLib.ports.management;
    services = anankeLib.mkIndexedServices {
      basePort = 8200;
      builders = {
        ninfer = port: m: anankeLib.mkContainerCommandService {
          inherit (m) name vramGb perGpuMib description upstreamModel;
          inherit port;
          image = images.ninfer.tag;
          # Per-model so one service can exercise a second runtime while the
          # rest stay on Docker.
          runtime = m.runtime or "docker";
          # Replaces the image's CMD, so the executable leads.
          # `--kv-capacity` tracks the context exactly, keeping the static
          # reservation honest.
          command = [ "ninfer-serve" "${artifactsIn}/${m.artifact}" ] ++ flagArgs {
            "--host" = "\${listen_host}";
            "--port" = "\${listen_port}";
            "--max-context" = m.maxContext;
            "--kv-capacity" = m.maxContext;
            "--kv-dtype" = "int8";
            "--max-concurrency" = 1;
            "--vision" = m.vision or false;
            "--spec" = m.spec;
            "--draft-tokens" = m.draftTokens;
            "--lm-head-draft" = true;
          };
          network = "host";
          mounts = [ (roMount "${home}/ai/ninfer" artifactsIn) ];
        };
      };
      inherit models;
    };
  }) configFile;

  # The subset of `models` exposed to Maki/Polytoken clients, projected into
  # the client-facing shape by `anankeLib.mkClientModel` (which derives
  # `context_window` and `supports_vision` from the runtime fields). Consumed
  # by `update-ai.py` via `nix eval`.
  clientModels = builtins.map anankeLib.mkClientModel (builtins.filter (m: m ? client) models);
in
{
  options.ai.ananke = {
    openaiPort = lib.mkOption {
      type = lib.types.port;
      default = anankeLib.ports.openai;
      readOnly = true;
      description = "Port ananke's OpenAI-compatible API listens on.";
    };
    managementPort = lib.mkOption {
      type = lib.types.port;
      default = anankeLib.ports.management;
      readOnly = true;
      description = "Port ananke's management API (including /metrics) listens on.";
    };
    clientModels = lib.mkOption {
      type = lib.types.listOf lib.types.attrs;
      readOnly = true;
      default = clientModels;
      description = "Models exposed to Maki/Polytoken clients, with context_window and supports_vision derived from the runtime config. Consumed by update-ai.py.";
    };
  };

  config = {
    systemd.tmpfiles.rules =
      let owner = config.mainUser; in
      [
        "d ${hfCache} 0755 ${owner} users -"
      ];

    # Runs as the interactive user: Podman's store here is that user's
    # rootless one, and the canary's image has to land in it.
    systemd.services.container-images = mkImageService {
      images = lib.attrValues images;
      podmanImages = [ images.ninfer ];
      user = config.mainUser;
    };

    systemd.services.ananke = anankeLib.mkAnankeSystemdService {
      inherit anankeDir configFile;
      user = config.mainUser;
      group = "users";
      after = [ "docker.service" "network.target" ];
      requires = [ "docker.service" ];
      # ananke invokes the runtime CLIs directly, so both are on its own
      # PATH; the containers get no PATH from here.
      # wrapperDir for rootless Podman's setuid newuidmap/newgidmap.
      path = [ pkgs.docker pkgs.podman pkgs.curl pkgs.bash config.security.wrapperDir ];
      environment.LD_LIBRARY_PATH = "/run/opengl-driver/lib";
    };

    # Per-service ports are loopback-only (allowExternalServices defaults to
    # false); everything goes through openaiPort instead.
    networking.firewall.allowedTCPPorts = [ anankeLib.ports.openai anankeLib.ports.management ];
  };
}
