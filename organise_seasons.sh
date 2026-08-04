#!/bin/bash

# Script to organize TV season files into subfolders
# Files matching pattern S##E##.* will be moved to "Season ##" folders

set -e

DRY_RUN=false
TARGET_DIR="."

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -n|--dry-run)
            DRY_RUN=true
            shift
            ;;
        *)
            # Non-flag argument is the target directory
            if [[ ! "$1" =~ ^- ]]; then
                TARGET_DIR="$1"
            fi
            shift
            ;;
    esac
done

# Resolve the target directory to an absolute path
WORK_DIR="$(cd "$TARGET_DIR" && pwd)"

if [[ "$DRY_RUN" == true ]]; then
    echo "DRY RUN: No changes will be made"
fi

echo "Organizing files in: $WORK_DIR"
echo

# Change to the work directory
cd "$WORK_DIR"

# Find all S##E## pattern files and extract unique seasons
seasons=()
while IFS= read -r -d '' file; do
    if [[ -f "$file" ]]; then
        # Extract season number (S##)
        season=$(echo "$file" | grep -oE 'S[0-9][0-9]' | head -1)
        season_num=${season#S}
        # Remove leading zero for folder name
        season_num=$((10#$season_num))

        # Add to seasons array if not already present
        if [[ ! " ${seasons[*]} " =~ " $season_num " ]]; then
            seasons+=("$season_num")
        fi
    fi
done < <(find "$WORK_DIR" -maxdepth 1 -name "S[0-9][0-9]E[0-9][0-9]*" -print0 2>/dev/null)

# Sort seasons numerically
IFS=$'\n' sorted_seasons=($(sort -n <<<"${seasons[*]}")); unset IFS

if [[ ${#sorted_seasons[@]} -eq 0 ]]; then
    echo "No files matching S##E## pattern found."
    exit 0
fi

echo "Found seasons: ${sorted_seasons[*]}"
echo

# Create folders and move files
for season_num in "${sorted_seasons[@]}"; do
    folder_name="Season $season_num"

    # Create folder if it doesn't exist
    if [[ ! -d "$folder_name" ]]; then
        if [[ "$DRY_RUN" == true ]]; then
            echo "DRY RUN: Would create folder: $folder_name"
        else
            echo "Creating folder: $folder_name"
            mkdir -p "$folder_name"
        fi
    fi

    # Move files for this season to the folder
    moved_count=0
    # Use find to get all matching files, then filter by season
    while IFS= read -r -d '' file; do
        if [[ -f "$file" ]]; then
            # Extract season number from filename (S##)
            file_season=$(echo "$file" | grep -oE 'S[0-9][0-9]' | head -1)
            file_season_num=${file_season#S}
            # Remove leading zero for comparison
            file_season_num=$((10#$file_season_num))

            # Check if this file belongs to current season
            if [[ $file_season_num -eq $season_num ]]; then
                if [[ "$DRY_RUN" == true ]]; then
                    echo "DRY RUN: Would move: $file -> $folder_name/"
                else
                    echo "  Moving: $file -> $folder_name/"
                    mv "$file" "$folder_name/"
                fi
                moved_count=$((moved_count + 1))
            fi
        fi
    done < <(find "$WORK_DIR" -maxdepth 1 -name "S[0-9][0-9]E[0-9][0-9]*" -print0 2>/dev/null)

    if [[ "$DRY_RUN" == true ]]; then
        echo "  Would move $moved_count file(s) to $folder_name"
    else
        echo "  Moved $moved_count file(s) to $folder_name"
    fi
    echo
done

if [[ "$DRY_RUN" == true ]]; then
    echo "DRY RUN complete - no changes were made!"
else
    echo "Organization complete!"
fi
