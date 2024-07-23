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
else
    echo "Operation cancelled."
fi
