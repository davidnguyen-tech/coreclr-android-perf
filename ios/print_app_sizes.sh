#!/bin/bash

source "$(dirname "$0")/../init.sh"

# Check if the apps directory exists
if [[ ! -d "$APPS_DIR" ]]; then
    echo "Apps directory does not exist: $APPS_DIR"
    exit 1
fi

# Iterate through each .app bundle in the apps directory
find "$APPS_DIR" -type d -name "*.app" -path "*/Release/*" | while read -r app_dir; do
    # Get the total size of the .app directory
    app_size=$(du -sk "$app_dir" | awk '{print $1 * 1024}')
    # Print the full path and size
    echo "File: $app_dir, Size: $app_size bytes"
done
