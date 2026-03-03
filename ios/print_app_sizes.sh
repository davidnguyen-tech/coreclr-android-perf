#!/bin/bash

source "$(dirname "$0")/../init.sh"

# Check if the build directory exists
if [[ ! -d "$BUILD_DIR" ]]; then
    echo "Build directory does not exist: $BUILD_DIR"
    exit 1
fi

# Iterate through each .app bundle in the build directory
find "$BUILD_DIR" -type d -name "*.app" | while read -r app_dir; do
    # Get the total size of the .app directory
    app_size=$(du -sk "$app_dir" | awk '{print $1 * 1024}')
    # Print the full path and size
    echo "File: $app_dir, Size: $app_size bytes"
done
