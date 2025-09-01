{ pkgs, comfyuiPort, comfyuiTargetPort, utils }:
let
  # ComfyUI Docker image configuration
  comfyuiImageName = "comfyui-custom";
  comfyuiImageTag = "latest";
  comfyuiImage = "${comfyuiImageName}:${comfyuiImageTag}";

  # Script to rebuild ComfyUI Docker image
  comfyuiRebuildScript = pkgs.writeShellApplication {
    name = "comfyui-rebuild";
    runtimeInputs = [ pkgs.git pkgs.docker ];
    text = ''
      set -e

      COMFYUI_DIR="/mnt/ssd2/ai/ComfyUI"
      cd "$COMFYUI_DIR"

      # Configure Git to trust this directory
      ${pkgs.git}/bin/git config --global --add safe.directory "$COMFYUI_DIR"

      echo "Building/updating ComfyUI Docker image..."

      # Pull latest changes
      ${pkgs.git}/bin/git fetch origin
      ${pkgs.git}/bin/git pull origin master

      # Remove old image if it exists
      if docker image inspect ${comfyuiImage} >/dev/null 2>&1; then
        echo "Removing old ComfyUI image..."
        docker rmi ${comfyuiImage}
      fi

      # Create temporary Dockerfile
      cat << EOF > /tmp/Dockerfile
      FROM pytorch/pytorch:2.6.0-cuda12.6-cudnn9-devel

      # Install dependencies
      RUN apt-get update && apt-get install -y git libgl1-mesa-glx libglib2.0-0

      # Set up workspace
      WORKDIR /workspace

      # Copy requirements.txt
      COPY requirements.txt .

      # Install Python dependencies
      RUN pip install -r requirements.txt

      # Set entrypoint
      ENTRYPOINT ["python", "main.py", "--listen", "--enable-cors-header"]
      EOF

      # Build the image
      docker build -t ${comfyuiImage} -f /tmp/Dockerfile .

      # Clean up
      rm /tmp/Dockerfile

      echo "ComfyUI Docker image rebuilt successfully!"
    '';
  };

  # Script to run ComfyUI service (static version, no rebuild)
  comfyuiScript = pkgs.writeShellApplication {
    name = "comfyui-service";
    runtimeInputs = [ pkgs.docker ];
    text = ''
      set -e

      COMFYUI_DIR="/mnt/ssd2/ai/ComfyUI"
      cd "$COMFYUI_DIR"

      # Check if image exists
      if ! docker image inspect ${comfyuiImage} >/dev/null 2>&1; then
        echo "Error: ComfyUI Docker image not found. Please run 'sudo comfyui-rebuild' first."
        exit 1
      fi

      echo "Starting ComfyUI with existing Docker image..."

      # Run ComfyUI
      exec docker run --rm --name comfyui \
        --device nvidia.com/gpu=all \
        -v "$COMFYUI_DIR:/workspace" \
        -p ${toString comfyuiTargetPort}:${toString comfyuiPort} \
        ${comfyuiImage}
    '';
  };

  # ComfyUI service configuration
  service = utils.mkService {
    name = "ComfyUI";
    listenPort = comfyuiPort;
    targetPort = comfyuiTargetPort;
    command = "${comfyuiScript}/bin/comfyui-service";
    args = "";
    killCommand = "docker kill comfyui";
    healthcheck = {
      command = "curl --fail http://localhost:${toString comfyuiTargetPort}/system_stats";
      intervalMilliseconds = 200;
    };
    restartOnConnectionFailure = true;
    shutDownAfterInactivitySeconds = 30;
    resourceRequirements = {
      "VRAM-GPU-1" = 20000;
      RAM = 16000;
    };
  };
in
{
  inherit comfyuiScript comfyuiRebuildScript comfyuiPort comfyuiTargetPort service;
}
