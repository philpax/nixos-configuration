{ pkgs, comfyuiDir, port, baseImage ? "pytorch/pytorch:2.10.0-cuda13.0-cudnn9-devel" }:
let
  imageName = "comfyui-custom";
  imageTag = "latest";
  image = "${imageName}:${imageTag}";
in
{
  comfyuiRebuildScript = pkgs.writeShellApplication {
    name = "comfyui-rebuild";
    runtimeInputs = [ pkgs.git pkgs.docker ];
    text = ''
      set -e

      COMFYUI_DIR="${comfyuiDir}"

      echo "Building/updating ComfyUI Docker image..."

      if [ ! -d "$COMFYUI_DIR/.git" ]; then
        echo "Cloning ComfyUI repository..."
        TMPDIR=$(mktemp -d)
        ${pkgs.git}/bin/git clone https://github.com/comfyanonymous/ComfyUI.git "$TMPDIR/ComfyUI"
        # Move git content into existing directory (preserving files like models/)
        cp -rn "$TMPDIR/ComfyUI/." "$COMFYUI_DIR/"
        mv "$TMPDIR/ComfyUI/.git" "$COMFYUI_DIR/.git"
        rm -rf "$TMPDIR"
      fi

      cd "$COMFYUI_DIR"

      # Configure Git to trust this directory
      ${pkgs.git}/bin/git config --global --add safe.directory "$COMFYUI_DIR"

      # Pull latest changes
      ${pkgs.git}/bin/git fetch origin
      ${pkgs.git}/bin/git pull origin master

      # Remove old image if it exists
      if docker image inspect ${image} >/dev/null 2>&1; then
        echo "Removing old ComfyUI image..."
        docker rmi ${image}
      fi

      # Create temporary Dockerfile
      cat << EOF > /tmp/Dockerfile
      FROM ${baseImage}

      # Install dependencies
      RUN apt-get update && apt-get install -y git libgl1 libglib2.0-0

      # Set up workspace
      WORKDIR /workspace

      # Copy requirements.txt
      COPY requirements.txt .

      # Install Python dependencies
      RUN pip install --break-system-packages -r requirements.txt

      # Set entrypoint
      ENTRYPOINT ["python", "main.py", "--listen", "--enable-cors-header"]
      EOF

      # Build the image
      docker build -t ${image} -f /tmp/Dockerfile .

      # Clean up
      rm /tmp/Dockerfile

      echo "ComfyUI Docker image rebuilt successfully!"
    '';
  };

  comfyuiStartScript = pkgs.writeShellApplication {
    name = "comfyui-start";
    runtimeInputs = [ pkgs.docker ];
    text = ''
      set -e

      COMFYUI_DIR="${comfyuiDir}"
      cd "$COMFYUI_DIR"

      # Check if image exists
      if ! docker image inspect ${image} >/dev/null 2>&1; then
        echo "Error: ComfyUI Docker image not found. Please run 'sudo comfyui-rebuild' first."
        exit 1
      fi

      # Default to the nix-configured port; let callers override with
      # `--port N`.
      FOREGROUND=false
      PORT=${toString port}
      while [ $# -gt 0 ]; do
        case "$1" in
          --foreground) FOREGROUND=true ;;
          --port)
            shift
            if [ $# -eq 0 ]; then
              echo "Error: --port requires a value" >&2
              exit 2
            fi
            PORT="$1"
            ;;
          --port=*) PORT="''${1#--port=}" ;;
          *)
            echo "Error: unknown argument '$1'" >&2
            exit 2
            ;;
        esac
        shift
      done

      # Ananke sets CUDA_VISIBLE_DEVICES on us with the GPU id(s) it picked.
      # CDI's `nvidia.com/gpu=N` accepts a comma-separated index list, so we
      # forward it directly: the container only sees the picked GPU(s) and
      # Comfy's `cuda:0` actually maps to it. Falls back to `all` when the
      # script is invoked outside ananke (e.g. via `sudo comfyui-start`).
      GPU_DEVICES="''${CUDA_VISIBLE_DEVICES:-all}"

      # Place the container under a known systemd slice so ananke's
      # snapshotter can attribute VRAM to this service via cgroup
      # membership. Without this, the container's cgroup
      # (`docker-<id>.scope`) lives under `system.slice/docker.service`
      # — entirely outside ananke's view of the daemon's children — and
      # ananke's pledge book would stay frozen at `min_vram_gb` no
      # matter how much VRAM the workload was actually using. Mirrors
      # `tracking.cgroup_parent` in the daemon's service config.
      CGROUP_PARENT="ananke-comfyui.slice"

      if [ "$FOREGROUND" = true ]; then
        echo "Starting ComfyUI in foreground on port $PORT (GPUs: $GPU_DEVICES, slice: $CGROUP_PARENT)..."
        exec docker run --rm --name comfyui \
          --device "nvidia.com/gpu=$GPU_DEVICES" \
          --cgroup-parent "$CGROUP_PARENT" \
          -v "$COMFYUI_DIR:/workspace" \
          -p "$PORT:8188" \
          ${image}
      else
        echo "Starting ComfyUI (detached) on port $PORT (GPUs: $GPU_DEVICES, slice: $CGROUP_PARENT)..."
        docker run -d --rm --name comfyui \
          --device "nvidia.com/gpu=$GPU_DEVICES" \
          --cgroup-parent "$CGROUP_PARENT" \
          -v "$COMFYUI_DIR:/workspace" \
          -p "$PORT:8188" \
          ${image}
        echo "ComfyUI started. Access at http://localhost:$PORT"
      fi
    '';
  };

  comfyuiStopScript = pkgs.writeShellApplication {
    name = "comfyui-stop";
    runtimeInputs = [ pkgs.docker ];
    text = ''
      docker kill comfyui
      echo "ComfyUI stopped."
    '';
  };
}
