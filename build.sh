#!/bin/bash

source "$(dirname "$0")/init.sh"

# Extract flags from arguments, default to android
PLATFORM="android"
PGO_MIBC_DIR=""
CSPROJ_PATH=""
POSITIONAL_ARGS=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --platform)
            if [[ -z "$2" || "$2" == --* ]]; then
                echo "Error: --platform requires a value (android, android-emulator, ios, ios-simulator, osx, maccatalyst)"
                exit 1
            fi
            PLATFORM="$2"
            shift 2
            ;;
        --platform=*)
            PLATFORM="${1#*=}"
            shift
            ;;
        --pgo-mibc-dir)
            if [[ -z "$2" || "$2" == --* ]]; then
                echo "Error: --pgo-mibc-dir requires a directory path"
                exit 1
            fi
            PGO_MIBC_DIR="$2"
            shift 2
            ;;
        --csproj)
            if [[ -z "$2" || "$2" == --* ]]; then
                echo "Error: --csproj requires a path to a .csproj file"
                exit 1
            fi
            if [ ! -f "$2" ]; then
                echo "Error: csproj file not found: $2"
                exit 1
            fi
            CSPROJ_PATH="$(cd "$(dirname "$2")" && pwd)/$(basename "$2")"
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

# When --csproj is provided, derive app name from filename and shift positional args.
# With --csproj:  positional args are <build-config> <build|run> <ntimes> [additional_args]
# Without:        positional args are <app-name> <build-config> <build|run> <ntimes> [additional_args]
if [ -n "$CSPROJ_PATH" ]; then
    SAMPLE_APP="$(basename "$CSPROJ_PATH" .csproj)"
    APP_DIR="$(dirname "$CSPROJ_PATH")"

    if [[ -z "$1" ]]; then
        echo "Usage: $0 --csproj <path> [--platform <platform>] <build-config> <build|run> <ntimes> [--pgo-mibc-dir <path>] [additional_args]"
        echo "  --csproj: path to an external .csproj file"
        echo "  --platform: target platform (android, android-emulator, ios, ios-simulator, osx, maccatalyst) (default: android)"
        echo "  build-config: MONO_JIT, CORECLR_JIT, MONO_AOT, MONO_PAOT, R2R, R2R_COMP, R2R_COMP_PGO"
        echo "  --pgo-mibc-dir: directory containing *.mibc files for R2R_COMP_PGO builds"
        exit 1
    fi

    BUILD_CONFIG="$1"
    BUILD_OR_RUN="$2"
    REPEAT_COUNT_ARG="$3"
    POSITIONAL_SHIFT=3
else
    if [[ -z "$1" || -z "$2" ]]; then
        echo "Usage: $0 [--platform <android|android-emulator|ios|ios-simulator|osx|maccatalyst>] [--csproj <path>] <app-name> <build-config> <build|run> <ntimes> [--pgo-mibc-dir <path>] [additional_args]"
        echo "  --csproj: path to an external .csproj file (makes <app-name> optional)"
        echo "  --platform: target platform (android, android-emulator, ios, ios-simulator, osx, maccatalyst) (default: android)"
        echo "  build-config: MONO_JIT, CORECLR_JIT, MONO_AOT, MONO_PAOT, R2R, R2R_COMP, R2R_COMP_PGO"
        echo "  --pgo-mibc-dir: directory containing *.mibc files for R2R_COMP_PGO builds"
        exit 1
    fi

    SAMPLE_APP="$1"
    BUILD_CONFIG="$2"
    BUILD_OR_RUN="$3"
    REPEAT_COUNT_ARG="$4"
    APP_DIR="$APPS_DIR/$SAMPLE_APP"
    POSITIONAL_SHIFT=4

    if [ ! -d "$APP_DIR" ]; then
        echo "Error: App directory $APP_DIR does not exist. Run ./prepare.sh first."
        exit 1
    fi
fi

VALID_CONFIGS="MONO_JIT CORECLR_JIT MONO_AOT MONO_PAOT R2R R2R_COMP R2R_COMP_PGO"
if [[ ! " $VALID_CONFIGS " =~ " $BUILD_CONFIG " ]]; then
    echo "Invalid build config '$BUILD_CONFIG'. Allowed values are: $VALID_CONFIGS"
    exit 1
fi

if [[ -z "$BUILD_OR_RUN" || ( "$BUILD_OR_RUN" != "run" && "$BUILD_OR_RUN" != "build" ) ]]; then
    echo "Invalid parameter '$BUILD_OR_RUN'. Allowed values are: run, build"
    exit 1
else
    if [[ "$BUILD_OR_RUN" == "run" ]]; then
        RUN_TARGET="-t:Run"
    else
        RUN_TARGET=""
    fi
fi

if [[ -z "$REPEAT_COUNT_ARG" || ! "$REPEAT_COUNT_ARG" =~ ^[0-9]+$ ]]; then
    echo "Invalid repeat count '$REPEAT_COUNT_ARG'. Please provide a positive integer indicating how many times the build will be repeated."
    exit 1
fi

REPEAT_COUNT=$REPEAT_COUNT_ARG

MSBUILD_ARGS="-p:_BuildConfig=$BUILD_CONFIG"

if [ -n "$PGO_MIBC_DIR" ]; then
    if [ ! -d "$PGO_MIBC_DIR" ]; then
        echo "Error: PGO MIBC directory does not exist: $PGO_MIBC_DIR"
        exit 1
    fi
    MSBUILD_ARGS="$MSBUILD_ARGS -p:_CUSTOM_MIBC_DIR=$PGO_MIBC_DIR"
fi

# Append any remaining positional args as additional MSBuild args
shift $POSITIONAL_SHIFT
for arg in "$@"; do
    MSBUILD_ARGS="$MSBUILD_ARGS $arg"
done

# Determine the build target (csproj path)
if [ -n "$CSPROJ_PATH" ]; then
    BUILD_CSPROJ="$CSPROJ_PATH"
else
    BUILD_CSPROJ="$APP_DIR/$SAMPLE_APP.csproj"
fi

echo "Building $SAMPLE_APP with config $BUILD_CONFIG $REPEAT_COUNT times"

for ((i=1; i<=REPEAT_COUNT; i++)); do
    echo "Build iteration $i of $REPEAT_COUNT"
    rm -rf "${APP_DIR:?}/bin"
    rm -rf "${APP_DIR:?}/obj"

    timestamp=$(date +"%Y%m%d%H%M%S")
    logfile="$APP_DIR/msbuild_$timestamp.binlog"
    SAVE_OUTPUT_PATH="$BUILD_DIR/${SAMPLE_APP}_${timestamp}"

    echo "Building $SAMPLE_APP with config $BUILD_CONFIG via: ${LOCAL_DOTNET} build -c Release -f $PLATFORM_TFM -r $PLATFORM_RID -bl:$logfile $BUILD_CSPROJ $MSBUILD_ARGS $RUN_TARGET"
    ${LOCAL_DOTNET} build -c Release -f "$PLATFORM_TFM" -r "$PLATFORM_RID" -bl:"$logfile" "$BUILD_CSPROJ" $MSBUILD_ARGS $RUN_TARGET

    mkdir -p "$SAVE_OUTPUT_PATH"
    cp -r "$APP_DIR/bin" "$SAVE_OUTPUT_PATH/"
    cp -r "$APP_DIR/obj" "$SAVE_OUTPUT_PATH/"
    cp -r "$logfile" "$SAVE_OUTPUT_PATH/"
done