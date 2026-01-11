#!/bin/bash

set -o pipefail

SDK="macosx"
SOURCE_DIR=""
OUTPUT_DIR=""

usage() {
    echo "Usage: $0 -s <source_dir> -o <output_dir>"
    echo ""
    echo "Options:"
    echo "  -s    Directory containing .metal files"
    echo "  -o    Output directory for .air and .metallib"
    exit 1
}

# ---- Parse flags ----
while getopts "s:o:" opt; do
    case $opt in
        s) SOURCE_DIR="$OPTARG" ;;
        o) OUTPUT_DIR="$OPTARG" ;;
        *) usage ;;
    esac
done

# ---- Validate ----
if [ -z "$SOURCE_DIR" ] || [ -z "$OUTPUT_DIR" ]; then
    usage
fi

if [ ! -d "$SOURCE_DIR" ]; then
    echo "ERROR: Source directory '$SOURCE_DIR' does not exist."
    exit 1
fi

mkdir -p "$OUTPUT_DIR" || {
    echo "ERROR: Could not create output directory '$OUTPUT_DIR'."
    exit 1
}

# ---- Check for metal tool ----
if ! xcrun --sdk $SDK --find metal >/dev/null 2>&1; then
    echo "ERROR: Metal compiler not found."
    echo "Try:"
    echo "  sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer"
    echo "or:"
    echo "  xcodebuild -downloadComponent MetalToolchain"
    exit 1
fi

# ---- Collect sources ----
METAL_FILES=("$SOURCE_DIR"/*.metal)

if [ ! -e "${METAL_FILES[0]}" ]; then
    echo "ERROR: No .metal files found in '$SOURCE_DIR'."
    exit 1
fi

AIR_FILE="$OUTPUT_DIR/shaders.air"
METALLIB_FILE="$OUTPUT_DIR/shaders.metallib"

echo "=== Metal shader build ==="
echo "Source: $SOURCE_DIR"
echo "Output: $OUTPUT_DIR"

# ---- Compile ----
echo "Compiling shaders..."
if ! xcrun --sdk $SDK metal -c "${METAL_FILES[@]}" -o "$AIR_FILE"; then
    echo "ERROR: Metal compilation failed."
    exit 1
fi

# ---- Link ----
echo "Linking metallib..."
if ! xcrun --sdk $SDK metallib "$AIR_FILE" -o "$METALLIB_FILE"; then
    echo "ERROR: metallib linking failed."
    exit 1
fi

echo "✔ Shaders compiled successfully:"
echo "  $METALLIB_FILE"
