#!/bin/sh

# Function to echo error messages
error() {
    echo "Error: $1" >&2
    exit 1
}

# Check if the script is run as root
if [ "$(id -u)" -ne 0 ]; then
    error "This script must be run as root"
fi

# Check if an argument is provided
if [ $# -eq 0 ]; then
    error "Usage: $0 [load|unload]"
fi

# Function to load NVIDIA drivers
load_nvidia() {
    echo "Loading NVIDIA drivers..."
    echo 0000:4c:00.0 > /sys/bus/pci/drivers/vfio-pci/unbind || error "Failed to unbind 0000:4c:00.0"
    echo 0000:4c:00.1 > /sys/bus/pci/drivers/vfio-pci/unbind || error "Failed to unbind 0000:4c:00.1"
    modprobe nvidia || error "Failed to load nvidia module"
    echo 10de 2204 > /sys/bus/pci/drivers/nvidia/new_id || error "Failed to add new NVIDIA device ID"
    systemctl restart nvidia-container-toolkit-cdi-generator.service || error "Failed to restart nvidia-container-toolkit-cdi-generator service"
    systemctl start comfyui || error "Failed to start comfyui service"
    echo "NVIDIA drivers loaded successfully."
}

# Function to unload NVIDIA drivers
unload_nvidia() {
    echo "Unloading NVIDIA drivers..."
    systemctl stop comfyui || error "Failed to stop comfyui service"
    echo 0000:4c:00.0 > /sys/bus/pci/drivers/nvidia/unbind || error "Failed to unbind 0000:4c:00.0 from nvidia"
    modprobe -r nvidia_drm || error "Failed to remove nvidia_drm module"
    modprobe -r nvidia_modeset || error "Failed to remove nvidia_modeset module"
    modprobe -r nvidia_uvm || error "Failed to remove nvidia_uvm module"
    modprobe -r nvidia || error "Failed to remove nvidia module"
    echo 0000:4c:00.0 > /sys/bus/pci/drivers/vfio-pci/bind || error "Failed to bind 0000:4c:00.0 to vfio-pci"
    echo 0000:4c:00.1 > /sys/bus/pci/drivers/vfio-pci/bind || error "Failed to bind 0000:4c:00.1 to vfio-pci"
    echo "NVIDIA drivers unloaded successfully."
}

# Main script logic
case "$1" in
    load)
        load_nvidia
        ;;
    unload)
        unload_nvidia
        ;;
    *)
        error "Invalid argument. Usage: $0 [load|unload]"
        ;;
esac

exit 0
