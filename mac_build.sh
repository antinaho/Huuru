#!/bin/bash

set -o pipefail

# ---- Usage check ----
if [ $# -ne 1 ]; then
    echo "Usage: $0 <shader_directory>"
    exit 1
fi

SHADER_DIR="$1"

if [ ! -d "$SHADER_DIR" ]; then
    echo "ERROR: '$SHADER_DIR' is not a directory."
    exit 1
fi

SDK="macosx"

AIR_FILE="$SHADER_DIR/shaders.air"
METALLIB_FILE="$SHADER_DIR/shaders.metallib"

echo "=== Metal shader build ==="
echo "Directory: $SHADER_DIR"

# ---- Check for metal tool ----
if ! xcrun --sdk $SDK --find metal >/dev/null 2>&1; then
    echo "ERROR: Metal compiler not found."
    echo "Make sure Xcode is installed and selected:"
    echo "  sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer"
    echo ""
    echo "If needed:"
    echo "  xcodebuild -downloadComponent MetalToolchain"
    exit 1
fi

# ---- Collect .metal files ----
METAL_FILES=("$SHADER_DIR"/*.metal)

if [ ! -e "${METAL_FILES[0]}" ]; then
    echo "ERROR: No .metal files found in $SHADER_DIR"
    exit 1
fi

# ---- Compile ----
echo "Compiling Metal shaders..."
if ! xcrun --sdk $SDK metal -c "${METAL_FILES[@]}" -o "$AIR_FILE"; then
    echo "ERROR: Metal shader compilation failed."
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
