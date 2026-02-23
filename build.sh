#!/bin/bash

source "$(dirname "$0")/init.sh"

if [ ! -f "$LOCAL_DOTNET" ]; then
    echo "Error: $LOCAL_DOTNET does not exist. Please run ./prepare.sh first."
    exit 1
fi

if [[ -z "$1" || -z "$2" ]]; then
    echo "Usage: $0 <dotnet-new-android|dotnet-new-maui|dotnet-new-maui-samplecontent> <mono-coreclr> <build-run> <ntimes> [additional_args]"
    exit 1
fi

if [[ "$1" != "dotnet-new-android" && "$1" != "dotnet-new-maui" && "$1" != "dotnet-new-maui-samplecontent" ]]; then
    echo "Invalid parameter. Allowed values are: dotnet-new-android, dotnet-new-maui, dotnet-new-maui-samplecontent"
    exit 1
fi

if [[ "$2" != "mono" && "$2" != "coreclr" ]]; then
    echo "Invalid parameter. Allowed values are: mono, coreclr"
    exit 1
fi

if [[ -z "$3" || ( "$3" != "run" && "$3" != "build" ) ]]; then
    echo "Invalid third parameter. Allowed values are: run, build"
    exit 1
else
    if [[ "$3" == "run" ]]; then
        RUN_TARGET="-t:Run"
    else
        RUN_TARGET=""
    fi
fi

SAMPLE_APP=$1
RUNTIME=$2

if [[ "$RUNTIME" == "mono" ]]; then
    RUNTIME_SPECIFIC_ARGS="-p:UseMonoRuntime=true"
elif [[ "$RUNTIME" == "coreclr" ]]; then
    RUNTIME_SPECIFIC_ARGS="-p:UseMonoRuntime=false"
fi

if [[ -z "$4" || ! "$4" =~ ^[0-9]+$ ]]; then
    echo "Invalid fourth parameter. Please provide a positive integer indicating how many times the build will be repeated."
    exit 1
fi

REPEAT_COUNT=$4

if [[ -n "$5" ]]; then
    RUNTIME_SPECIFIC_ARGS="$RUNTIME_SPECIFIC_ARGS $5"
fi

echo "Building $SAMPLE_APP with $RUNTIME runtime $REPEAT_COUNT times"

for ((i=1; i<=REPEAT_COUNT; i++)); do
    echo "Build iteration $i of $REPEAT_COUNT"
    rm -rf "$SAMPLE_APP/bin"
    rm -rf "$SAMPLE_APP/obj"

    timestamp=$(date +"%Y%m%d%H%M%S")
    logfile="$SAMPLE_APP/msbuild_$timestamp.binlog"
    SAVE_OUTPUT_PATH="$BUILD_DIR/$SAMPLE_APP"_"$timestamp"

    echo "Building $SAMPLE_APP with $RUNTIME runtime via: ${LOCAL_DOTNET} build -c Release -f net11.0-android -r android-arm64 -bl:$logfile "$SAMPLE_APP/$SAMPLE_APP.csproj" $RUNTIME_SPECIFIC_ARGS $RUN_TARGET"
    ${LOCAL_DOTNET} build -c Release -f net11.0-android -r android-arm64 -bl:$logfile "$SAMPLE_APP/$SAMPLE_APP.csproj" $RUNTIME_SPECIFIC_ARGS $RUN_TARGET

    mkdir -p "$SAVE_OUTPUT_PATH"
    cp -r "$SAMPLE_APP/bin" "$SAVE_OUTPUT_PATH/"
    cp -r "$SAMPLE_APP/obj" "$SAVE_OUTPUT_PATH/"
    cp -r "$logfile" "$SAVE_OUTPUT_PATH/"
done