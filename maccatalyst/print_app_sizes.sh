#!/bin/bash

source "$(dirname "$0")/../init.sh"

# Check if the build directory exists
if [[ ! -d "$BUILD_DIR" ]]; then
    echo "Build directory does not exist: $BUILD_DIR"
    exit 1
fi

# Check for optional -detailed flag
detailed=false
if [[ "$#" -gt 0 && "$1" != "-detailed" ]]; then
    echo "Invalid argument: $1"
    echo "Usage: $0 [-detailed]"
    exit 1
elif [[ "$1" == "-detailed" ]]; then
    detailed=true
fi

# Find .app bundles under the build directory (excluding obj/ directories)
find "$BUILD_DIR" -type d -name "*.app" -not -path "*/obj/*" | while read -r app_dir; do
    # Get the total size of the .app bundle using du
    app_size_kb=$(du -sk "$app_dir" | cut -f1)
    app_size_bytes=$((app_size_kb * 1024))
    # Print the full path and size
    echo "Bundle: $app_dir, Size: ${app_size_kb} KB (${app_size_bytes} bytes)"

    if [[ "$detailed" == true ]]; then
        # List the contents of the .app bundle with sizes
        echo "  Contents:"
        find "$app_dir" -type f -exec stat -f "  %z %N" {} \; 2>/dev/null | sort -rn | head -20
        echo ""
    fi
done
