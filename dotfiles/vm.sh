#!/bin/sh

# Function to echo error messages
error() {
    echo "Error: $1" >&2
    exit 1
}

# Check if an argument is provided
if [ $# -eq 0 ]; then
    error "Usage: $0 [on|off]"
fi

# Check if the script is run as root
if [ "$(id -u)" -ne 0 ]; then
    error "This script must be run as root"
fi

case "$1" in
    off)
        echo "Checking if VM 'win11' is running..."
        if virsh list --name | grep -q "^win11$"; then
            echo "Shutting down VM 'win11'..."
            virsh shutdown win11 || error "Failed to shutdown VM 'win11'"

            # Wait for VM to shutdown
            printf "Waiting for VM to shutdown..."
            while virsh list --name | grep -q "^win11$"; do
                sleep 1
                printf "."
            done
            printf "\n"
        else
            echo "VM 'win11' is not running"
        fi

        echo "Loading GPU drivers for host..."
        ./gpu.sh load || error "Failed to load GPU drivers"
        echo "Successfully switched to host mode"
        ;;

    on)
        echo "Checking if VM 'win11' is running..."
        if virsh list --name | grep -q "^win11$"; then
            error "VM 'win11' is already running"
        fi

        echo "Unloading GPU drivers for guest..."
        ./gpu.sh unload || error "Failed to unload GPU drivers"

        echo "Starting VM 'win11'..."
        virsh start win11 || error "Failed to start VM 'win11'"
        echo "Successfully switched to guest mode"
        ;;

    *)
        error "Invalid argument. Usage: $0 [on|off]"
        ;;
esac

exit 0
