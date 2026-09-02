# AudioMuse-AI: sonic analysis and playlist generation for Navidrome.
# https://github.com/NeptuneHub/AudioMuse-AI
#
# Runs as containers on a private Podman network, mirroring upstream's
# docker-compose-nvidia.yaml: the Flask web app, a scalable pool of RQ
# analysis workers, and dedicated postgres/redis instances. The app fetches
# audio through Navidrome's Subsonic API (no direct music-folder access
# needed) as the dedicated `audiomuse` Navidrome user, which navidrome.nix
# provisions declaratively.
#
# The flask app and the workers get a GPU each via CDI, workers alternating
# across both cards for CLAP embeddings and clustering.
{ config, lib, pkgs, ... }:

let
  folders = import ../folders.nix;
  secrets = import ../secrets/audiomuse.nix;

  image = "ghcr.io/neptunehub/audiomuse-ai:3.1.1-nvidia";
  # Host port; the container listens on 8000, but that's taken on the host by
  # the ad-hoc `python -m http.server` allowance in configuration.nix.
  port = 8800;

  pgEnv = {
    POSTGRES_USER = "audiomuse";
    POSTGRES_PASSWORD = secrets.postgresPassword;
    POSTGRES_DB = "audiomusedb";
  };

  appEnv = pgEnv // {
    POSTGRES_HOST = "audiomuse-postgres";
    POSTGRES_PORT = "5432";
    REDIS_URL = "redis://audiomuse-redis:6379/0";
    TEMP_DIR = "/app/temp_audio";
    # Declarative Navidrome hookup. NOTE: env vars here are first-boot seed
    # material only — the media-server creds land in the music_servers table
    # and every other tunable in app_config, and from then on the DB rows
    # override env on every start. Changing values below therefore does NOT
    # propagate until you clear the stale snapshot:
    #   podman exec audiomuse-postgres psql -U audiomuse audiomusedb \
    #     -c "truncate app_config;"   # then restart the containers
    # (music_servers needs the web UI or a postgres wipe instead.)
    # host.containers.internal resolves via the --add-host mapping below.
    MEDIASERVER_TYPE = "navidrome";
    NAVIDROME_URL = "http://host.containers.internal:4533";
    NAVIDROME_USER = "audiomuse";
    NAVIDROME_PASSWORD = secrets.navidromePassword;
    # All three must be set to disable AudioMuse's unauthenticated "legacy
    # mode": without them the web UI (and its first-run setup wizard, which
    # can read and rewrite the stored Navidrome credentials) is open to the
    # whole LAN. The API token is what the Navidrome plugin authenticates with.
    AUDIOMUSE_USER = secrets.webUser;
    AUDIOMUSE_PASSWORD = secrets.webPassword;
    API_TOKEN = secrets.apiToken;
    # LLM playlist naming via ananke's default model. The URL must be the
    # full chat-completions path; the key just has to be non-empty.
    AI_MODEL_PROVIDER = "OPENAI";
    OPENAI_SERVER_URL = "http://host.containers.internal:${toString config.ai.ananke.openaiPort}/v1/chat/completions";
    OPENAI_MODEL_NAME = config.ai.ananke.defaultModel;
    OPENAI_API_KEY = "ananke-no-auth";
    # Analysis throughput. The reload default trades 2-3s/track for low VRAM
    # (pointless on 24GB cards).
    PER_SONG_MODEL_RELOAD = "false";
    # Lyrics come from the API slots below; the internal CPU-bound Whisper
    # ONNX fallback stays off so true instrumentals get the instrumental
    # sentinel instead of a 23-core transcription attempt.
    LYRICS_ASR_ENABLE = "false";
    # Slot 1: LRCLIB, for tracks whose real lyrics exist online.
    LYRICS_API_1_URL_TEMPLATE = "https://lrclib.net/api/get";
    LYRICS_API_1_ARTIST_PARAM = "artist_name";
    LYRICS_API_1_TITLE_PARAM = "track_name";
    LYRICS_API_1_LYRICS_FIELD = "plainLyrics";
    LYRICS_API_1_TIMEOUT = "5";
    # Slot 2: the whisper-lyrics GPU transcription sidecar (see
    # services/whisper-lyrics.nix). The long timeout absorbs queueing when
    # several workers hit it at once.
    LYRICS_API_2_URL_TEMPLATE = "http://host.containers.internal:8801/lyrics";
    LYRICS_API_2_ARTIST_PARAM = "artist";
    LYRICS_API_2_TITLE_PARAM = "title";
    LYRICS_API_2_LYRICS_FIELD = "lyrics";
    LYRICS_API_2_APIKEY_PARAM = "key";
    LYRICS_API_2_APIKEY_VALUE = secrets.lyricsApiKey;
    LYRICS_API_2_TIMEOUT = "600";
  };

  appExtraOptions = gpu: [
    "--network=audiomuse"
    "--add-host=host.containers.internal:host-gateway"
    "--device=nvidia.com/gpu=${toString gpu}"
    "--userns=keep-id"
  ];

  workerCount = config.redline.audiomuse.workerCount;
  # One container (and unit) per worker. A pooled 2-container design (N rq
  # workers sharing a container via a custom launcher) was tried on
  # 2026-08-05 and abandoned: CUDA-EP work-horses segfault en masse when
  # multiple workers share a container's namespaces, at densities that are
  # rock-solid as separate containers — even with private TEMP_DIR/
  # PLUGINS_DIR per process and 8g /dev/shm. Root cause never isolated.
  workerIds = lib.range 1 workerCount;
  workerName = i: "audiomuse-worker-${toString i}";
  workerGpu = i: lib.mod i 2;

  containerNames = [ "audiomuse-postgres" "audiomuse-redis" "audiomuse" ]
    ++ map workerName workerIds;
in
{
  # Each worker container runs one RQ worker pair (fixed by the image's
  # supervisord), so parallelism = container count; upstream scales the same
  # way via Helm replicas. Exposed as an option so ssd0.nix can gate the
  # generated units without hardcoding the count.
  options.redline.audiomuse.workerCount = lib.mkOption {
    type = lib.types.ints.positive;
    # 4 CUDA-EP processes per GPU is the only density that has never
    # crashed: 6+/GPU segfaults in onnxruntime CUDA session creation
    # (2026-08-05, likely concurrent cudnn EXHAUSTIVE autotune — hardcoded
    # upstream). Raise at your peril.
    default = 8;
    description = "Total AudioMuse-AI analysis worker processes, split across the two worker containers.";
  };

  config = {
    virtualisation.oci-containers.backend = "podman";
    virtualisation.oci-containers.containers = {
      audiomuse-postgres = {
        image = "docker.io/library/postgres:15-alpine";
        environment = pgEnv;
        volumes = [ "${folders.audiomuse}/postgres:/var/lib/postgresql/data:U" ];
        podman.user = "ai";
        extraOptions = [ "--network=audiomuse" "--userns=keep-id" ];
      };

      audiomuse-redis = {
        image = "docker.io/library/redis:7-alpine";
        volumes = [ "${folders.audiomuse}/redis:/data:U" ];
        podman.user = "ai";
        extraOptions = [ "--network=audiomuse" "--userns=keep-id" ];
      };

      audiomuse = {
        inherit image;
        podman.user = "ai";
        environment = appEnv // { SERVICE_TYPE = "flask"; };
        # Published on all interfaces: the Navidrome plugin calls it via
        # 127.0.0.1 and the web UI is used from the LAN; AUDIOMUSE_* auth above
        # is what stands between it and the network. Rootless Podman publishes
        # this port directly, so it is explicitly allowed below in the host
        # firewall.
        ports = [ "${toString port}:8000" ];
        volumes = [
          "${folders.audiomuse}/temp-flask:/app/temp_audio:U"
          "${folders.audiomuse}/plugins-flask:/app/plugin/installed:U"
        ];
        dependsOn = [ "audiomuse-postgres" "audiomuse-redis" ];
        extraOptions = appExtraOptions 0;
      };
    } // lib.listToAttrs (map (i: lib.nameValuePair (workerName i) {
      inherit image;
      podman.user = "ai";
      environment = appEnv // {
        SERVICE_TYPE = "worker";
        USE_GPU_CLUSTERING = "true";
      };
      volumes = [
        "${folders.audiomuse}/temp-${workerName i}:/app/temp_audio:U"
        "${folders.audiomuse}/plugins-${workerName i}:/app/plugin/installed:U"
      ];
      dependsOn = [ "audiomuse-postgres" "audiomuse-redis" ];
      extraOptions = appExtraOptions (workerGpu i) ++ [ "--cpus=6" ];
    }) workerIds);

    # The ssd0 dirs are gated so the kill switch's "nothing touches ssd0"
    # invariant holds — unconditional rules would recreate them on the root fs
    # under the unmounted mountpoint. The dump dir lives on the ZFS pool and is
    # exempt from the switch.
    systemd.tmpfiles.rules =
      lib.optionals config.redline.ssd0.enable ([
        "d ${folders.audiomuse} 0755 ai ai -"
        "d ${folders.audiomuse}/postgres 0700 ai ai -"
        "d ${folders.audiomuse}/redis 0755 ai ai -"
        "d ${folders.audiomuse}/temp-flask 0755 ai ai -"
        "d ${folders.audiomuse}/plugins-flask 0755 ai ai -"
      ]
      ++ lib.concatMap (i: [
        "d ${folders.audiomuse}/temp-${workerName i} 0755 ai ai -"
        "d ${folders.audiomuse}/plugins-${workerName i} 0755 ai ai -"
      ]) workerIds)
      ++ [ "d ${folders.backup}/audiomuse 0755 ai ai -" ];

    systemd.services = {
      # oci-containers does not manage Podman networks; create ours once.
      podman-network-audiomuse = {
        description = "Podman network for AudioMuse-AI";
        after = [ "network-online.target" ];
        wants = [ "network-online.target" ];
        wantedBy = [ "multi-user.target" ];
        before = map (n: "podman-${n}.service") containerNames;
        requiredBy = map (n: "podman-${n}.service") containerNames;
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          User = "ai";
          Group = "ai";
          Environment = [ "HOME=/home/ai" ];
        };
        path = [ pkgs.podman pkgs.coreutils "/run/wrappers/bin" ];
        script = ''
          export XDG_RUNTIME_DIR="/run/user/$(${pkgs.coreutils}/bin/id -u)"
          podman network exists audiomuse || podman network create audiomuse
        '';
      };

      # Nightly dump of the analysis database into the restic-covered backup dir
      # (services.restic.backups.external snapshots ${folders.backup} daily, so
      # history/pruning comes for free). Restoring beats re-crunching ~20k tracks.
      audiomuse-pgdump = {
        description = "Dump AudioMuse-AI postgres database for backup";
        after = [ "podman-audiomuse-postgres.service" ];
        requires = [ "podman-audiomuse-postgres.service" ];
        serviceConfig = {
          Type = "oneshot";
          User = "ai";
          Group = "ai";
          Environment = [ "HOME=/home/ai" ];
        };
        path = [ pkgs.podman pkgs.gzip pkgs.coreutils "/run/wrappers/bin" ];
        script = ''
          set -euo pipefail
          export XDG_RUNTIME_DIR="/run/user/$(${pkgs.coreutils}/bin/id -u)"
          dump="${folders.backup}/audiomuse/audiomusedb.sql.gz"
          podman exec audiomuse-postgres \
            pg_dump -U audiomuse audiomusedb | gzip > "$dump.tmp"
          mv "$dump.tmp" "$dump"
        '';
      };

      # Ordering-only edges for first-activation ergonomics: let the Navidrome
      # user exist before the app tries to authenticate with it, and give the app
      # containers breathing room against postgres's first-run initdb (the
      # postgres unit is "started" the moment `podman run` execs, long before it
      # accepts connections; without RestartSec the default 100ms restart cadence
      # can trip the start-rate limiter and wedge the unit in `failed`).
      podman-audiomuse = {
        after = [ "navidrome-audiomuse-user.service" ];
        serviceConfig.RestartSec = 15;
      };
    } // lib.listToAttrs (map (i: lib.nameValuePair "podman-${workerName i}" {
      # Ordering only: the user oneshot for first-boot auth, and flask for
      # boot-time schema migrations (racing them deadlocked postgres once).
      after = [ "navidrome-audiomuse-user.service" "podman-audiomuse.service" ];
      serviceConfig.RestartSec = 15;
    }) workerIds);

    systemd.timers.audiomuse-pgdump = {
      description = "Nightly AudioMuse-AI database dump";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        # restic's daily run (OnCalendar=daily = midnight) picks up
        # ${folders.backup}; dump an hour before it so every snapshot carries a
        # fresh dump rather than yesterday's.
        OnCalendar = "*-*-* 23:00:00";
        Persistent = true;
        RandomizedDelaySec = "15m";
      };
    };

    # Rootless Podman publishes this port without Docker's firewall DNAT path.
    networking.firewall.allowedTCPPorts = [ port ];
  };
}
