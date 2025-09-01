#!/usr/bin/env bash

set -euo pipefail

# Set the repository directory
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Set the source directories
NIXOS_SOURCE="$REPO_DIR/nixos"
DOTFILES_SOURCE="$REPO_DIR/dotfiles"

# Set the target directories
NIXOS_TARGET="/etc/nixos"
DOTFILES_TARGET="$HOME"

# Usage information
usage() {
    echo "Usage: $0 <folder_name>"
    echo ""
    echo "Creates all symlinks for NixOS and dotfiles, then creates a symlink"
    echo "from /etc/nixos/configuration.nix to \$NIXOS_SOURCE/<folder_name>/configuration.nix"
    echo ""
    echo "Available targets:"
    list_available_targets
    echo ""
    echo "Examples:"
    echo "  $0 <target>   # Create all symlinks + <target> configuration"
}

# Function to list available targets (folders in NIXOS_SOURCE)
list_available_targets() {
    if [ ! -d "$NIXOS_SOURCE" ]; then
        echo "  Error: NIXOS_SOURCE directory not found at $NIXOS_SOURCE"
        return 1
    fi

    local targets=$(find "$NIXOS_SOURCE" -maxdepth 1 -type d -name "*" | grep -v "^$NIXOS_SOURCE$" | sort)

    if [ -z "$targets" ]; then
        echo "  No targets found in $NIXOS_SOURCE"
        return 1
    fi

    echo "$targets" | while read -r target; do
        local target_name=$(basename "$target")
        local config_file="$target/configuration.nix"
        if [ -f "$config_file" ]; then
            echo "  $target_name"
        else
            echo "  $target_name (no configuration.nix)"
        fi
    done
}

# Function to create a symlink to a folder's configuration.nix
create_config_symlink() {
    local folder_name="$1"

    if [ -z "$folder_name" ]; then
        echo "Error: Please provide a folder name"
        usage
        exit 1
    fi

    local source_path="$NIXOS_SOURCE/$folder_name/configuration.nix"
    local target_path="$NIXOS_TARGET/configuration.nix"

    # Check if source file exists
    if [ ! -f "$source_path" ]; then
        echo "Error: Configuration file not found at $source_path"
        exit 1
    fi

    # Create the symlink (this will overwrite any existing symlink)
    echo "Creating symlink: $target_path -> $source_path"
    sudo ln -sf "$source_path" "$target_path"
    echo "Symlink created successfully!"
}

# Function to build a list of symlinks
build_symlink_list() {
    local source_dir="$1"
    local target_dir="$2"

    find "$source_dir" -type f | while read -r source_path; do
        local relative_path="${source_path#$source_dir/}"
        local target_path="$target_dir/$relative_path"
        echo "$target_path -> $source_path"
    done
}

# Function to create or update symlinks
create_or_update_symlinks() {
    local symlink_list="$1"
    local use_sudo="$2"

    echo "$symlink_list" | while read -r line; do
        local target_path="${line% -> *}"
        local source_path="${line#* -> }"
        local target_dir_path="$(dirname "$target_path")"

        if [ "$use_sudo" = true ]; then
            sudo mkdir -p "$target_dir_path"
            if [ -L "$target_path" ]; then
                sudo rm -f "$target_path"
            elif [ -e "$target_path" ]; then
                echo "Warning: $target_path already exists and is not a symlink. Skipping."
                continue
            fi
            sudo ln -s "$source_path" "$target_path"
        else
            mkdir -p "$target_dir_path"
            if [ -L "$target_path" ]; then
                rm -f "$target_path"
            elif [ -e "$target_path" ]; then
                echo "Warning: $target_path already exists and is not a symlink. Skipping."
                continue
            fi
            ln -s "$source_path" "$target_path"
        fi
        echo "Created/Updated symlink: $target_path -> $source_path"
    done
}

# Check command line arguments first
if [ $# -eq 0 ]; then
    # No arguments provided - show usage and exit
    usage
    exit 1
fi

# Store the folder name for later use
FOLDER_NAME="$1"

# Build the lists of proposed symlinks
nixos_symlinks=$(build_symlink_list "$NIXOS_SOURCE" "$NIXOS_TARGET")
dotfiles_symlinks=$(build_symlink_list "$DOTFILES_SOURCE" "$DOTFILES_TARGET")

# Display the proposed symlinks
echo "Proposed symlinks for NixOS configuration:"
echo "$nixos_symlinks"
echo

echo "Proposed symlinks for dotfiles:"
echo "$dotfiles_symlinks"
echo

# Ask for confirmation
read -p "Are these symlinks OK? (y/n) " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]
then
    # Create/Update symlinks for NixOS configuration
    echo "Creating/Updating symlinks for NixOS configuration..."
    create_or_update_symlinks "$nixos_symlinks" true

    # Create/Update symlinks for dotfiles
    echo "Creating/Updating symlinks for dotfiles..."
    create_or_update_symlinks "$dotfiles_symlinks" false

    echo "Symlinking complete!"

    # Now create the configuration.nix symlink
    echo "Creating configuration.nix symlink..."
    create_config_symlink "$FOLDER_NAME"
else
    echo "Operation cancelled."
fi
