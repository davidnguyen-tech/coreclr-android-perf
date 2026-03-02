#!/bin/bash

source "$(dirname "$0")/init.sh"

if [[ -z "$1" ]]; then
    echo "Usage: $0 <all|dotnet-new-android|dotnet-new-maui|dotnet-new-maui-samplecontent>"
    exit 1
fi

SAMPLE_APP=$1

if [[ "$SAMPLE_APP" == "all" ]]; then
    APPS=("dotnet-new-android" "dotnet-new-maui" "dotnet-new-maui-samplecontent")
else
    if [[ "$SAMPLE_APP" == "dotnet-new-android" || "$SAMPLE_APP" == "dotnet-new-maui" || "$SAMPLE_APP" == "dotnet-new-maui-samplecontent" ]]; then
        APPS=("$SAMPLE_APP")
    else
        echo "Invalid option: $SAMPLE_APP"
        echo "Usage: $0 <all|dotnet-new-android|dotnet-new-maui|dotnet-new-maui-samplecontent>"
        exit 1
    fi
fi

for app in "${APPS[@]}"; do
    echo "Cleaning $app ..."
    local_app_dir="$APPS_DIR/$app"
    if [ -d "$local_app_dir" ]; then
        rm -rf "$local_app_dir/bin"
        rm -rf "$local_app_dir/obj"
        rm -rf "$local_app_dir/perfdata"
        rm -f "$local_app_dir"/*.binlog
    fi
    find "$BUILD_DIR/" -type d -name "${app}*" -exec rm -rf {} + 2>/dev/null
done
