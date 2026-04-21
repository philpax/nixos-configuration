#!/usr/bin/env bash

set -euo pipefail

# Set the repository directory
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOTFILES_SOURCE="$REPO_DIR/dotfiles"

# Usage information
usage() {
    echo "Usage: $0 [-t <target>] [-d <dotfiles_dir>] <path> [path2 ...]"
    echo ""
    echo "Moves file(s) or directory(ies) into dotfiles/ and creates symlinks back."
    echo ""
    echo "Options:"
    echo "  -t, --target <folder>   Target subdirectory in dotfiles/ (prompts if omitted)"
    echo "  -d, --dotfiles <dir>    Override dotfiles directory (default: ./dotfiles)"
    echo "  -n, --dry-run           Show what would be done without making changes"
    echo "  -f, --force             Overwrite existing files in dotfiles/"
    echo "  -h, --help              Show this help message"
    echo ""
    echo "Examples:"
    echo "  $0 ~/.config/nvim"
    echo "  $0 -t common-all ~/.ssh"
    echo "  $0 -t redline ~/my-custom-config"
    echo "  $0 --dry-run ~/.config/telescope"
}

# Defaults
DRY_RUN=false
FORCE=false
TARGET=""
DOTFILES_DIR="$DOTFILES_SOURCE"
PATHS=()

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        -t|--target)
            TARGET="$2"
            shift 2
            ;;
        -d|--dotfiles)
            DOTFILES_DIR="$2"
            shift 2
            ;;
        -n|--dry-run)
            DRY_RUN=true
            shift
            ;;
        -f|--force)
            FORCE=true
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        -*)
            echo "Error: Unknown option '$1'"
            usage
            exit 1
            ;;
        *)
            PATHS+=("$1")
            shift
            ;;
    esac
done

if [[ ${#PATHS[@]} -eq 0 ]]; then
    echo "Error: No paths provided"
    usage
    exit 1
fi

# Determine target subdirectory
if [[ -z "$TARGET" ]]; then
    if [[ ! -d "$DOTFILES_DIR" ]]; then
        echo "Error: Dotfiles directory not found: $DOTFILES_DIR"
        exit 1
    fi

    # List available targets
    mapfile -t AVAILABLE < <(find "$DOTFILES_DIR" -maxdepth 1 -mindepth 1 -type d -exec basename {} \; | sort)

    if [[ ${#AVAILABLE[@]} -eq 0 ]]; then
        echo "No targets found in $DOTFILES_DIR. Creating 'common-all'."
        TARGET="common-all"
    else
        echo "Available targets:"
        for i in "${!AVAILABLE[@]}"; do
            echo "  $((i+1)). ${AVAILABLE[$i]}"
        done
        echo ""
        read -rp "Choose target [1-${#AVAILABLE[@]}]: " choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#AVAILABLE[@]} )); then
            TARGET="${AVAILABLE[$((choice-1))]}"
        else
            echo "Error: Invalid selection."
            exit 1
        fi
    fi
fi

TARGET_DIR="$DOTFILES_DIR/$TARGET"

# Ensure target directory exists
if [[ "$DRY_RUN" == false ]]; then
    mkdir -p "$TARGET_DIR"
fi

echo "Target directory: $TARGET_DIR"
echo ""

# Function to resolve a path to absolute
resolve_path() {
    local input="$1"
    # Handle ~ expansion
    if [[ "$input" == ~/* || "$input" == ~/ ]]; then
        input="${input/\~/$HOME}"
    fi
    # Make absolute
    if [[ "$input" != /* ]]; then
        input="$(pwd)/$input"
    fi
    # Normalize double slashes
    echo "$input" | sed 's#/\+#/#g'
}

# Function to slurp a single file/directory
slurp_item() {
    local input_path="$1"
    local absolute_path
    absolute_path=$(resolve_path "$input_path")

    # Check source exists
    if [[ ! -e "$absolute_path" && ! -L "$absolute_path" ]]; then
        echo "Error: Path not found: $absolute_path"
        return 1
    fi

    # Determine the relative path from HOME for dotfiles placement
    local home_dir="$HOME"
    local relative_to_home="${absolute_path#$home_dir/}"

    if [[ "$relative_to_home" == "$absolute_path" ]]; then
        # Not under home, use path relative to pwd
        relative_to_home="${absolute_path#$(pwd)/}"
    fi

    # Destination in dotfiles
    local dest_path="$TARGET_DIR/$relative_to_home"
    local dest_dir_path
    dest_dir_path=$(dirname "$dest_path")

    # Check if destination already exists
    if [[ -e "$dest_path" || -L "$dest_path" ]]; then
        if [[ "$FORCE" == false ]]; then
            echo "Warning: Destination already exists: $dest_path"
            echo "  Use --force to overwrite."
            echo ""
            return 1
        else
            echo "Force mode: removing existing destination: $dest_path"
        fi
    fi

    # Check if the original location has other files that would be orphaned
    if [[ -d "$absolute_path" ]]; then
        local contents
        contents=$(find "$absolute_path" -mindepth 1 -maxdepth 1 2>/dev/null | head -20)
        if [[ -n "$contents" ]]; then
            echo "Note: Directory contains items that will be moved:"
            echo "$contents" | while read -r item; do
                echo "  $(basename "$item")"
            done
        fi
    fi

    if [[ "$DRY_RUN" == true ]]; then
        echo "[dry-run] Would move: $absolute_path"
        echo "[dry-run]   -> $dest_path"
        echo "[dry-run] Would create symlink: $absolute_path -> $dest_path (relative)"
        echo ""
        return 0
    fi

    # Create destination directory
    mkdir -p "$dest_dir_path"

    # Move the file/directory
    mv "$absolute_path" "$dest_path"
    echo "Moved: $absolute_path"
    echo "  -> $dest_path"

    # Create symlink back
    # Use relative symlink if source is under HOME, otherwise absolute
    local symlink_target
    if [[ "$dest_path" == "$home_dir/"* ]]; then
        # Calculate relative path from symlink location to destination
        local symlink_dir
        symlink_dir=$(dirname "$absolute_path")
        symlink_target=$(realpath --relative-to="$symlink_dir" "$dest_path")
    else
        symlink_target="$dest_path"
    fi

    ln -s "$symlink_target" "$absolute_path"
    echo "Symlink: $absolute_path -> $symlink_target"
    echo ""
}

# Process all paths
ERRORS=0
for path in "${PATHS[@]}"; do
    if ! slurp_item "$path"; then
        ERRORS=$((ERRORS + 1))
    fi
done

if [[ $ERRORS -gt 0 ]]; then
    echo "Done with $ERRORS error(s)."
    exit 1
fi

echo "Done!"
