#!/bin/bash

source "$(dirname "$0")/../init.sh"

# Check if the build directory exists
if [[ ! -d "$BUILD_DIR" ]]; then
    echo "Build directory does not exist: $BUILD_DIR"
    exit 1
fi

# Initialize the unzip variable to false
unzip=false

# Check if a parameter is provided and if it is "-unzipped"
if [[ "$#" -gt 0 && "$1" != "-unzipped" ]]; then
    echo "Invalid argument: $1"
    echo "Usage: $0 [-unzipped]"
    exit 1
elif [[ "$1" == "-unzipped" ]]; then
    unzip=true
fi

# Iterate through each folder in the build directory
find "$BUILD_DIR" -type f -name "*-Signed.apk" | while read -r apk_file; do
    # Get the size of the APK file
    apk_size=$(stat -f%z "$apk_file")
    # Print the full path and size
    echo "File: $apk_file, Size: $apk_size bytes"
    
    if [[ "$unzip" == true ]]; then
        # Create an output directory based on the APK file's directory
        output_dir="$(dirname "$apk_file")/unpacked"
        if ! apktool d -f -o "$output_dir" "$apk_file" > /dev/null 2>&1; then
            echo "Error unpacking $apk_file with apktool" >&2
            exit 1
        fi
        # Calculate and print the size of the unpacked directory
        unpacked_size=$(du -sk "$output_dir" | cut -f1)
        echo "Unpacked size of $output_dir: $unpacked_size KB"
    fi
done