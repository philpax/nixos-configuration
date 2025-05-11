{ pkgs, comfyuiPort, comfyuiTargetPort }:
let
  # ComfyUI Docker image configuration
  comfyuiImageName = "comfyui-custom";
  comfyuiImageTag = "latest";
  comfyuiImage = "${comfyuiImageName}:${comfyuiImageTag}";

  # Script to manage ComfyUI Docker image and run the service
  comfyuiScript = pkgs.writeShellApplication {
    name = "comfyui-service";
    runtimeInputs = [ pkgs.git pkgs.docker ];
    text = ''
      set -e

      COMFYUI_DIR="/mnt/ssd2/ai/ComfyUI"
      cd "$COMFYUI_DIR"

      # Function to check if we need to rebuild
      needs_rebuild() {
        # Get current commit hash
        CURRENT_COMMIT=$(${pkgs.git}/bin/git rev-parse HEAD)

        # Pull latest changes
        ${pkgs.git}/bin/git fetch origin
        LATEST_COMMIT=$(${pkgs.git}/bin/git rev-parse origin/master)

        # If commits differ, we need to rebuild
        if [ "$CURRENT_COMMIT" != "$LATEST_COMMIT" ]; then
          echo "Pulling latest changes: $CURRENT_COMMIT -> $LATEST_COMMIT"
          ${pkgs.git}/bin/git pull origin master
          return 0
        fi

        # If image doesn't exist, we need to build
        if ! docker image inspect ${comfyuiImage} >/dev/null 2>&1; then
          return 0
        fi

        return 1
      }

      # Check if we need to rebuild and do so if necessary
      if needs_rebuild; then
        echo "Building/updating ComfyUI Docker image..."

        # Remove old image if it exists
        if docker image inspect ${comfyuiImage} >/dev/null 2>&1; then
          echo "Removing old ComfyUI image..."
          docker rmi ${comfyuiImage}
        fi

        # Create temporary Dockerfile
        cat << EOF > /tmp/Dockerfile
      FROM pytorch/pytorch:2.6.0-cuda12.6-cudnn9-devel

      # Install git
      RUN apt-get update && apt-get install -y git

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
      else
        echo "Using existing ComfyUI Docker image"
      fi

      # Run ComfyUI
      exec docker run --rm --name comfyui \
        --device nvidia.com/gpu=all \
        -v "$COMFYUI_DIR:/workspace" \
        -p ${toString comfyuiTargetPort}:${toString comfyuiPort} \
        ${comfyuiImage}
    '';
  };
in
{
  inherit comfyuiScript comfyuiPort comfyuiTargetPort;
}