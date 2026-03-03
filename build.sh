#!/bin/bash

source "$(dirname "$0")/init.sh"

# Extract --platform flag from arguments, default to android
PLATFORM="android"
POSITIONAL_ARGS=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --platform)
            PLATFORM="$2"
            shift 2
            ;;
        --platform=*)
            PLATFORM="${1#*=}"
            shift
            ;;
        *)
            POSITIONAL_ARGS+=("$1")
            shift
            ;;
    esac
done
set -- "${POSITIONAL_ARGS[@]}"

resolve_platform_config "$PLATFORM"

if [ ! -f "$LOCAL_DOTNET" ]; then
    echo "Error: $LOCAL_DOTNET does not exist. Please run ./prepare.sh first."
    exit 1
fi

if [[ -z "$1" || -z "$2" ]]; then
    echo "Usage: $0 [--platform <android|ios>] <app-name> <build-config> <build|run> <ntimes> [additional_args]"
    echo "  --platform: target platform (default: android)"
    echo "  build-config: MONO_JIT, CORECLR_JIT, MONO_AOT, MONO_PAOT, R2R, R2R_COMP, R2R_COMP_PGO"
    exit 1
fi

VALID_CONFIGS="MONO_JIT CORECLR_JIT MONO_AOT MONO_PAOT R2R R2R_COMP R2R_COMP_PGO"
if [[ ! " $VALID_CONFIGS " =~ " $2 " ]]; then
    echo "Invalid build config '$2'. Allowed values are: $VALID_CONFIGS"
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
BUILD_CONFIG=$2
APP_DIR="$APPS_DIR/$SAMPLE_APP"

if [ ! -d "$APP_DIR" ]; then
    echo "Error: App directory $APP_DIR does not exist. Run ./prepare.sh first."
    exit 1
fi

MSBUILD_ARGS="-p:_BuildConfig=$BUILD_CONFIG"

if [[ -z "$4" || ! "$4" =~ ^[0-9]+$ ]]; then
    echo "Invalid fourth parameter. Please provide a positive integer indicating how many times the build will be repeated."
    exit 1
fi

REPEAT_COUNT=$4

if [[ -n "$5" ]]; then
    MSBUILD_ARGS="$MSBUILD_ARGS $5"
fi

echo "Building $SAMPLE_APP with config $BUILD_CONFIG $REPEAT_COUNT times"

for ((i=1; i<=REPEAT_COUNT; i++)); do
    echo "Build iteration $i of $REPEAT_COUNT"
    rm -rf "${APP_DIR:?}/bin"
    rm -rf "${APP_DIR:?}/obj"

    timestamp=$(date +"%Y%m%d%H%M%S")
    logfile="$APP_DIR/msbuild_$timestamp.binlog"
    SAVE_OUTPUT_PATH="$BUILD_DIR/${SAMPLE_APP}_${timestamp}"

    echo "Building $SAMPLE_APP with config $BUILD_CONFIG via: ${LOCAL_DOTNET} build -c Release -f $PLATFORM_TFM -r $PLATFORM_RID -bl:$logfile $APP_DIR/$SAMPLE_APP.csproj $MSBUILD_ARGS $RUN_TARGET"
    ${LOCAL_DOTNET} build -c Release -f "$PLATFORM_TFM" -r "$PLATFORM_RID" -bl:"$logfile" "$APP_DIR/$SAMPLE_APP.csproj" $MSBUILD_ARGS $RUN_TARGET

    mkdir -p "$SAVE_OUTPUT_PATH"
    cp -r "$APP_DIR/bin" "$SAVE_OUTPUT_PATH/"
    cp -r "$APP_DIR/obj" "$SAVE_OUTPUT_PATH/"
    cp -r "$logfile" "$SAVE_OUTPUT_PATH/"
done