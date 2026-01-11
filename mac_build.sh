#!/bin/bash

set -o pipefail

METAL_SOURCE="shaders.metal"
AIR_FILE="shaders.air"
METALLIB_FILE="shaders.metallib"

SDK="macosx"

echo "=== Metal shader build ==="

# ---- Check that metal tool exists ----
if ! xcrun --sdk $SDK --find metal >/dev/null 2>&1; then
    echo "ERROR: Metal compiler not found."
    echo "Make sure Xcode is installed and selected:"
    echo "  sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer"
    echo ""
    echo "If Xcode is present but tools are missing, try:"
    echo "  xcodebuild -downloadComponent MetalToolchain"
    exit 1
fi

# ---- Compile .metal -> .air ----
echo "Compiling $METAL_SOURCE..."
if ! xcrun --sdk $SDK metal -c "$METAL_SOURCE" -o "$AIR_FILE"; then
    echo "ERROR: Metal shader compilation failed."
    exit 1
fi

# ---- Link .air -> .metallib ----
echo "Linking $METALLIB_FILE..."
if ! xcrun --sdk $SDK metallib "$AIR_FILE" -o "$METALLIB_FILE"; then
    echo "ERROR: metallib linking failed."
    exit 1
fi

echo "Shaders compiled successfully:"
echo "$METALLIB_FILE"
