#!/bin/bash

source "$(dirname "$0")/init.sh"

# Extract --platform and --local-runtime flags from arguments, default to prepared platform
PLATFORM="$(read_prepared_platform)"
LOCAL_RUNTIME_PATH=""
LOCAL_RUNTIME_CONFIG="Release"
POSITIONAL_ARGS=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --platform)
            if [[ -z "$2" || "$2" == --* ]]; then
                echo "Error: --platform requires a value (android, ios)"
                exit 1
            fi
            PLATFORM="$2"
            shift 2
            ;;
        --platform=*)
            PLATFORM="${1#*=}"
            shift
            ;;
        --local-runtime)
            if [[ -z "$2" || "$2" == --* ]]; then
                echo "Error: --local-runtime requires a path to the runtime repo"
                exit 1
            fi
            LOCAL_RUNTIME_PATH="$2"
            shift 2
            ;;
        --local-runtime-config)
            if [[ -z "$2" || "$2" == --* ]]; then
                echo "Error: --local-runtime-config requires a value (Release, Debug)"
                exit 1
            fi
            LOCAL_RUNTIME_CONFIG="$2"
            shift 2
            ;;
        *)
            POSITIONAL_ARGS+=("$1")
            shift
            ;;
    esac
done
set -- "${POSITIONAL_ARGS[@]}"

resolve_platform_config "$PLATFORM" || exit 1

if [ ! -f "$LOCAL_DOTNET" ]; then
    echo "Error: $LOCAL_DOTNET does not exist. Please run ./prepare.sh first."
    exit 1
fi

if [[ -z "$1" || -z "$2" ]]; then
    echo "Usage: $0 [--platform <android|ios>] [--local-runtime <path>] [--local-runtime-config <Release|Debug>] <app-name> <build-config> <build|run> <ntimes> [additional_args]"
    echo "  --platform: target platform (default: android)"
    echo "  --local-runtime: path to local dotnet/runtime repo with built shipping packages"
    echo "  --local-runtime-config: runtime build configuration (default: Release)"
    echo "  build-config: MONO_JIT, CORECLR_JIT, MONO_AOT, MONO_PAOT, R2R, R2R_COMP, R2R_COMP_PGO"
    exit 1
fi

VALID_CONFIGS="MONO_JIT CORECLR_JIT MONO_AOT MONO_PAOT R2R R2R_COMP R2R_COMP_PGO"
if [ "$PLATFORM" == "ios" ]; then
    # Non-composite R2R is not supported on iOS (MachO only supports composite R2R images)
    VALID_CONFIGS="MONO_JIT CORECLR_JIT MONO_AOT MONO_PAOT R2R_COMP R2R_COMP_PGO"
fi
case " $VALID_CONFIGS " in
    *" $2 "*) ;;
    *) echo "Invalid build config '$2' for $PLATFORM. Allowed values are: $VALID_CONFIGS"; exit 1 ;;
esac

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

# Reject app names with path separators to prevent directory traversal
if [[ "$SAMPLE_APP" == */* || "$SAMPLE_APP" == *..* ]]; then
    echo "Error: App name must not contain '/' or '..'"
    exit 1
fi

APP_DIR="$APPS_DIR/$SAMPLE_APP"

if [ ! -d "$APP_DIR" ]; then
    echo "Error: App directory $APP_DIR does not exist. Run ./prepare.sh first."
    exit 1
fi

MSBUILD_ARGS="-p:_BuildConfig=$BUILD_CONFIG"

# Configure local runtime if requested
if [ -n "$LOCAL_RUNTIME_PATH" ]; then
    configure_local_runtime "$LOCAL_RUNTIME_PATH" "$PLATFORM_RID" "$LOCAL_RUNTIME_CONFIG" || exit 1
    generate_local_nuget_config "$APP_DIR" || exit 1
    generate_local_build_props "$APP_DIR" || exit 1
    MSBUILD_ARGS="$MSBUILD_ARGS -p:_UseLocalRuntime=true"
fi

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

    # Clear NuGet cache when using local runtime to ensure fresh packages
    if [ "$LOCAL_RUNTIME_ACTIVE" = true ]; then
        echo "Clearing NuGet package cache ($LOCAL_PACKAGES)..."
        rm -rf "${LOCAL_PACKAGES:?}"
        mkdir -p "$LOCAL_PACKAGES"
    fi

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