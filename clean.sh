#!/bin/bash

source "$(dirname "$0")/init.sh"

if [[ -z "$1" ]]; then
    echo "Usage: $0 <all|APP_NAME>"
    echo "  all        Clean all apps found in $APPS_DIR"
    echo "  APP_NAME   Clean a specific app by directory name"
    exit 1
fi

SAMPLE_APP=$1

if [[ "$SAMPLE_APP" == "all" ]]; then
    APPS=()
    for d in "$APPS_DIR"/*/; do
        [ -d "$d" ] && APPS+=("$(basename "$d")")
    done
    if [[ ${#APPS[@]} -eq 0 ]]; then
        echo "No apps found in $APPS_DIR"
        exit 0
    fi
else
    if [[ -d "$APPS_DIR/$SAMPLE_APP" ]]; then
        APPS=("$SAMPLE_APP")
    else
        echo "App not found: $APPS_DIR/$SAMPLE_APP"
        echo "Usage: $0 <all|APP_NAME>"
        exit 1
    fi
fi

for app in "${APPS[@]}"; do
    echo "Cleaning $app ..."
    local_app_dir="$APPS_DIR/$app"
    if [ -d "$local_app_dir" ]; then
        rm -rf "${local_app_dir:?}/bin"
        rm -rf "${local_app_dir:?}/obj"
        rm -rf "${local_app_dir:?}/perfdata"
        rm -f "$local_app_dir"/*.binlog
    fi
    find "$BUILD_DIR/" -type d -name "${app}*" -exec rm -rf {} + 2>/dev/null
done
