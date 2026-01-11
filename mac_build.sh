#!/bin/bash

set -o pipefail

SDK="macosx"
SOURCE_DIR=""
OUTPUT_DIR=""

usage() {
    echo "Usage: $0 -s <source_dir> -o <output_dir>"
    exit 1
}

while getopts "s:o:" opt; do
    case $opt in
        s) SOURCE_DIR="$OPTARG" ;;
        o) OUTPUT_DIR="$OPTARG" ;;
        *) usage ;;
    esac
done

if [ -z "$SOURCE_DIR" ] || [ -z "$OUTPUT_DIR" ]; then
    usage
fi

if [ ! -d "$SOURCE_DIR" ]; then
    echo "ERROR: Source directory '$SOURCE_DIR' does not exist."
    exit 1
fi

mkdir -p "$OUTPUT_DIR" || exit 1

if ! xcrun --sdk $SDK --find metal >/dev/null 2>&1; then
    echo "ERROR: Metal compiler not found."
    exit 1
fi

AIR_DIR="$OUTPUT_DIR/air"
METALLIB_FILE="$OUTPUT_DIR/shaders.metallib"

mkdir -p "$AIR_DIR"

echo "=== Metal shader build ==="
echo "Source: $SOURCE_DIR"
echo "AIR out: $AIR_DIR"
echo "Metallib: $METALLIB_FILE"

AIR_FILES=()

# ---- Compile each .metal file individually ----
for METAL_FILE in "$SOURCE_DIR"/*.metal; do
    [ -e "$METAL_FILE" ] || {
        echo "ERROR: No .metal files found in '$SOURCE_DIR'"
        exit 1
    }

    BASENAME=$(basename "$METAL_FILE" .metal)
    AIR_FILE="$AIR_DIR/$BASENAME.air"

    echo "Compiling $(basename "$METAL_FILE")..."
    if ! xcrun --sdk $SDK metal -c "$METAL_FILE" -o "$AIR_FILE"; then
        echo "ERROR: Failed compiling $METAL_FILE"
        exit 1
    fi

    AIR_FILES+=("$AIR_FILE")
done

# ---- Link all .air files ----
echo "Linking metallib..."
if ! xcrun --sdk $SDK metallib "${AIR_FILES[@]}" -o "$METALLIB_FILE"; then
    echo "ERROR: metallib linking failed."
    exit 1
fi

echo "Shaders compiled successfully"
