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
    echo "Creates symlinks for NixOS (only 'common-*' and '<folder_name>' folders) and dotfiles"
    echo "(only 'common-*' and '<folder_name>' folders), then creates a symlink from"
    echo "/etc/nixos/configuration.nix to \$NIXOS_SOURCE/<folder_name>/configuration.nix"
    echo ""
    echo "Note: Only the 'common-*' and specified '<folder_name>' folders will be symlinked"
    echo "from both the NixOS and dotfiles source directories to avoid symlinking other machines' configurations."
    echo ""
    echo "Available targets:"
    list_available_targets
    echo ""
    echo "Examples:"
    echo "  $0 <target>   # Create symlinks for 'common-*' + '<target>' for NixOS and dotfiles"
}

# Function to list available targets (folders in NIXOS_SOURCE)
list_available_targets() {
    if [ ! -d "$NIXOS_SOURCE" ]; then
        echo "  Error: NIXOS_SOURCE directory not found at $NIXOS_SOURCE"
        return 1
    fi

    local targets=$(find "$NIXOS_SOURCE" -maxdepth 1 -type d -name "*" | grep -v "^$NIXOS_SOURCE$" | grep -v "^$NIXOS_SOURCE/common" | sort)

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
    local folder_name="$3"

    find "$source_dir" -type f | while read -r source_path; do
        local relative_path="${source_path#$source_dir/}"
        local target_path

        # For NixOS and dotfiles sources, only include files from 'common-*' and the specified folder
        if [ "$source_dir" = "$NIXOS_SOURCE" ] || [ "$source_dir" = "$DOTFILES_SOURCE" ]; then
            local first_dir=$(echo "$relative_path" | cut -d'/' -f1)
            if [[ "$first_dir" != common-* ]] && [ "$first_dir" != "$folder_name" ]; then
                continue
            fi

            # For dotfiles, remove the first directory (common-* or machine name) from the path
            if [ "$source_dir" = "$DOTFILES_SOURCE" ]; then
                relative_path="${relative_path#*/}"
            fi
        fi

        target_path="$target_dir/$relative_path"
        echo "$target_path -> $source_path"
    done
}

# Function to find existing non-symlink files that would be overwritten
find_conflicts() {
    local symlink_list="$1"

    echo "$symlink_list" | while read -r line; do
        local target_path="${line% -> *}"
        if [ -e "$target_path" ] && [ ! -L "$target_path" ]; then
            echo "  $target_path"
        fi
    done
}

# Function to create or update symlinks
create_or_update_symlinks() {
    local symlink_list="$1"
    local use_sudo="$2"
    local force="$3"

    echo "$symlink_list" | while read -r line; do
        local target_path="${line% -> *}"
        local source_path="${line#* -> }"
        local target_dir_path="$(dirname "$target_path")"

        if [ "$use_sudo" = true ]; then
            sudo mkdir -p "$target_dir_path"
            if [ -L "$target_path" ]; then
                sudo rm -f "$target_path"
            elif [ -e "$target_path" ]; then
                if [ "$force" = true ]; then
                    sudo rm -f "$target_path"
                else
                    echo "Warning: $target_path already exists and is not a symlink. Skipping."
                    continue
                fi
            fi
            sudo ln -s "$source_path" "$target_path"
        else
            mkdir -p "$target_dir_path"
            if [ -L "$target_path" ]; then
                rm -f "$target_path"
            elif [ -e "$target_path" ]; then
                if [ "$force" = true ]; then
                    rm -f "$target_path"
                else
                    echo "Warning: $target_path already exists and is not a symlink. Skipping."
                    continue
                fi
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

# Parse flags
FORCE=false
FOLDER_NAME=""
for arg in "$@"; do
    case "$arg" in
        --force|-f)
            FORCE=true
            ;;
        *)
            if [ -z "$FOLDER_NAME" ]; then
                FOLDER_NAME="$arg"
            else
                echo "Error: Unexpected argument '$arg'"
                usage
                exit 1
            fi
            ;;
    esac
done

if [ -z "$FOLDER_NAME" ]; then
    echo "Error: No folder name provided"
    usage
    exit 1
fi

# Build the lists of proposed symlinks
nixos_symlinks=$(build_symlink_list "$NIXOS_SOURCE" "$NIXOS_TARGET" "$FOLDER_NAME")
dotfiles_symlinks=$(build_symlink_list "$DOTFILES_SOURCE" "$DOTFILES_TARGET" "$FOLDER_NAME")

# Display the proposed symlinks
echo "Proposed symlinks for NixOS configuration:"
echo "$nixos_symlinks"
echo

echo "Proposed symlinks for dotfiles:"
echo "$dotfiles_symlinks"
echo

# Show conflicts
nixos_conflicts=$(find_conflicts "$nixos_symlinks")
dotfiles_conflicts=$(find_conflicts "$dotfiles_symlinks")
all_conflicts="${nixos_conflicts}${dotfiles_conflicts}"

if [ -n "$all_conflicts" ]; then
    echo "The following existing files (not symlinks) would be overwritten:"
    echo "$all_conflicts"
    echo
    if [ "$FORCE" = false ]; then
        echo "Use --force / -f to overwrite them. Without it, these files will be skipped."
        echo
    fi
fi

# Ask for confirmation
read -p "Are these symlinks OK? (y/n) " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]
then
    # Create/Update symlinks for NixOS configuration (only 'common-*' and specified folder)
    echo "Creating/Updating symlinks for NixOS configuration (common-* + $FOLDER_NAME)..."
    create_or_update_symlinks "$nixos_symlinks" true "$FORCE"

    # Create/Update symlinks for dotfiles (only 'common-*' and specified folder)
    echo "Creating/Updating symlinks for dotfiles (common-* + $FOLDER_NAME)..."
    create_or_update_symlinks "$dotfiles_symlinks" false "$FORCE"

    echo "Symlinking complete!"

    # Now create the configuration.nix symlink
    echo "Creating configuration.nix symlink..."
    create_config_symlink "$FOLDER_NAME"
else
    echo "Operation cancelled."
fi
