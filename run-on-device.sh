#!/bin/bash

# Install and launch an app on an iOS/Android device with console output.
# Useful for checking custom runtime logs without going through the measurement pipeline.
#
# Usage: ./run-on-device.sh [options] <app-name> <build-config>
#
# Examples:
#   ./run-on-device.sh dotnet-new-maui R2R_COMP
#   ./run-on-device.sh --local-runtime ~/repos/runtime dotnet-new-maui CORECLR_JIT
#   ./run-on-device.sh --device 5AE7F3E5-... --timeout 60 dotnet-new-maui R2R_COMP
#   ./run-on-device.sh --skip-build dotnet-new-maui R2R_COMP

source "$(dirname "$0")/init.sh"

print_usage() {
    echo "Usage: $0 [options] <app-name> <build-config>"
    echo ""
    echo "Build configs: MONO_JIT, CORECLR_JIT, MONO_AOT, MONO_PAOT, R2R, R2R_COMP, R2R_COMP_PGO"
    echo ""
    echo "Options:"
    echo "  --platform <android|ios>      Target platform (default: from prepare.sh)"
    echo "  --local-runtime <path>        Path to local dotnet/runtime repo with built shipping packages"
    echo "  --local-runtime-config <cfg>  Runtime build configuration: Release, Debug (default: Release)"
    echo "  --device <udid>               Device UDID (default: first available device)"
    echo "  --timeout <seconds>           How long to capture console output (default: 30)"
    echo "  --skip-build                  Skip build, use existing app from previous build"
    echo "  --output <path>               Log output file (default: /tmp/<app>_<config>.log)"
    exit 1
}

# Defaults
PLATFORM="$(read_prepared_platform)"
LOCAL_RUNTIME_PATH=""
LOCAL_RUNTIME_CONFIG="Release"
DEVICE_UDID=""
TIMEOUT=30
SKIP_BUILD=false
OUTPUT_FILE=""
POSITIONAL_ARGS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --platform)
            [[ -z "$2" || "$2" == --* ]] && { echo "Error: --platform requires a value"; exit 1; }
            PLATFORM="$2"; shift 2 ;;
        --local-runtime)
            [[ -z "$2" || "$2" == --* ]] && { echo "Error: --local-runtime requires a path"; exit 1; }
            LOCAL_RUNTIME_PATH="$2"; shift 2 ;;
        --local-runtime-config)
            [[ -z "$2" || "$2" == --* ]] && { echo "Error: --local-runtime-config requires a value"; exit 1; }
            LOCAL_RUNTIME_CONFIG="$2"; shift 2 ;;
        --device)
            [[ -z "$2" || "$2" == --* ]] && { echo "Error: --device requires a UDID"; exit 1; }
            DEVICE_UDID="$2"; shift 2 ;;
        --timeout)
            [[ -z "$2" || "$2" == --* ]] && { echo "Error: --timeout requires a number"; exit 1; }
            [[ ! "$2" =~ ^[1-9][0-9]*$ ]] && { echo "Error: --timeout must be a positive integer"; exit 1; }
            TIMEOUT="$2"; shift 2 ;;
        --skip-build)
            SKIP_BUILD=true; shift ;;
        --output)
            [[ -z "$2" || "$2" == --* ]] && { echo "Error: --output requires a path"; exit 1; }
            OUTPUT_FILE="$2"; shift 2 ;;
        -h|--help)
            print_usage ;;
        *)
            POSITIONAL_ARGS+=("$1"); shift ;;
    esac
done
set -- "${POSITIONAL_ARGS[@]}"

if [[ -z "$1" || -z "$2" ]]; then
    print_usage
fi

SAMPLE_APP=$1
BUILD_CONFIG=$2

# Reject app names with path separators to prevent directory traversal
if [[ "$SAMPLE_APP" == */* || "$SAMPLE_APP" == *..* ]]; then
    echo "Error: App name must not contain '/' or '..'"
    exit 1
fi

PLATFORM="${PLATFORM:-android}"
resolve_platform_config "$PLATFORM" || exit 1

# Platform-aware config validation (non-composite R2R not supported on iOS)
if [ "$PLATFORM" == "ios" ]; then
    VALID_CONFIGS="MONO_JIT CORECLR_JIT MONO_AOT MONO_PAOT R2R_COMP R2R_COMP_PGO"
else
    VALID_CONFIGS="MONO_JIT CORECLR_JIT MONO_AOT MONO_PAOT R2R R2R_COMP R2R_COMP_PGO"
fi
case " $VALID_CONFIGS " in
    *" $BUILD_CONFIG "*) ;;
    *) echo "Invalid build config '$BUILD_CONFIG' for $PLATFORM. Allowed values are: $VALID_CONFIGS"; exit 1 ;;
esac

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

# Build
if [ "$SKIP_BUILD" == false ]; then
    echo "=== Building $SAMPLE_APP ($BUILD_CONFIG) ==="
    rm -rf "${APP_DIR:?}/bin" "${APP_DIR:?}/obj"

    if [ "$LOCAL_RUNTIME_ACTIVE" = true ]; then
        echo "Clearing NuGet package cache ($LOCAL_PACKAGES)..."
        rm -rf "${LOCAL_PACKAGES:?}"
        mkdir -p "$LOCAL_PACKAGES"
    fi

    ${LOCAL_DOTNET} build -c Release -f "$PLATFORM_TFM" -r "$PLATFORM_RID" \
        -bl:"$BUILD_DIR/${SAMPLE_APP}_${BUILD_CONFIG}.binlog" \
        "$APP_DIR/$SAMPLE_APP.csproj" \
        $MSBUILD_ARGS

    if [ $? -ne 0 ]; then
        echo "Error: Build failed."
        exit 1
    fi
else
    echo "=== Skipping build (--skip-build) ==="
fi

# Find the built package
PACKAGE_PATH=$(find "$APP_DIR/bin" -name "$PLATFORM_PACKAGE_GLOB" -path "*/Release/*" | head -1)
if [ -z "$PACKAGE_PATH" ]; then
    # Fallback: search entire app dir but prefer bin/ over obj/
    PACKAGE_PATH=$(find "$APP_DIR" -name "$PLATFORM_PACKAGE_GLOB" -path "*/bin/Release/*" -not -path "*/obj/*" | head -1)
fi
if [ -z "$PACKAGE_PATH" ]; then
    echo "Error: Could not find $PLATFORM_PACKAGE_LABEL in $APP_DIR/bin. Build the app first."
    exit 1
fi
echo "Package: $PACKAGE_PATH"

# Determine package/bundle ID
PACKAGE_NAME=$(grep -o '<ApplicationId>[^<]*' "$APP_DIR/$SAMPLE_APP.csproj" | sed 's/<ApplicationId>//')
if [ -z "$PACKAGE_NAME" ]; then
    PACKAGE_NAME="com.companyname.$(echo "$SAMPLE_APP" | tr '-' '_')"
fi

# Set default output file
if [ -z "$OUTPUT_FILE" ]; then
    OUTPUT_FILE="/tmp/${SAMPLE_APP}_${BUILD_CONFIG}.log"
fi

# Platform-specific install & launch
if [ "$PLATFORM" = "ios" ]; then
    # Auto-detect device if not specified
    if [ -z "$DEVICE_UDID" ]; then
        # Match both modern 8-16 UDIDs (e.g. 00008101-001A09223E08001E) and
        # legacy 8-4-4-4-12 UUIDs (e.g. 5AE7F3E5-C6A0-5FBE-BF3F-29CD735AAA0B)
        DEVICE_UDID=$(xcrun devicectl list devices 2>/dev/null | awk 'NR>2 && /available/ {for(i=1;i<=NF;i++) if($i ~ /^[0-9a-fA-F]{8}-[0-9a-fA-F]/) {print $i; exit}}')
        if [ -z "$DEVICE_UDID" ]; then
            echo "Error: No available paired iOS device found. Specify --device <udid>."
            exit 1
        fi
        echo "Auto-detected device: $DEVICE_UDID"
    fi

    echo "=== Installing on device ==="
    xcrun devicectl device install app --device "$DEVICE_UDID" "$PACKAGE_PATH"
    if [ $? -ne 0 ]; then
        echo "Error: Install failed."
        exit 1
    fi

    echo "=== Launching with console output (${TIMEOUT}s) ==="
    echo "Output file: $OUTPUT_FILE"
    xcrun devicectl device process launch \
        --device "$DEVICE_UDID" \
        --console \
        --terminate-existing \
        "$PACKAGE_NAME" > "$OUTPUT_FILE" 2>&1 &
    LAUNCH_PID=$!

    sleep "$TIMEOUT"
    kill "$LAUNCH_PID" 2>/dev/null
    wait "$LAUNCH_PID" 2>/dev/null

    echo ""
    echo "=== Done ==="
    echo "Console output saved to: $OUTPUT_FILE"
    echo "Lines captured: $(wc -l < "$OUTPUT_FILE")"

elif [ "$PLATFORM" = "android" ]; then
    # Use specific device if provided
    ADB_DEVICE_ARGS=()
    if [ -n "$DEVICE_UDID" ]; then
        ADB_DEVICE_ARGS=("-s" "$DEVICE_UDID")
    fi

    echo "=== Installing on device ==="
    adb "${ADB_DEVICE_ARGS[@]}" install -r "$PACKAGE_PATH"
    if [ $? -ne 0 ]; then
        echo "Error: Install failed."
        exit 1
    fi

    echo "=== Launching with logcat output (${TIMEOUT}s) ==="
    echo "Output file: $OUTPUT_FILE"

    # Start logcat before launch to capture early startup logs
    adb "${ADB_DEVICE_ARGS[@]}" logcat -c
    adb "${ADB_DEVICE_ARGS[@]}" logcat > "$OUTPUT_FILE" 2>&1 &
    LOGCAT_PID=$!

    adb "${ADB_DEVICE_ARGS[@]}" shell am start -a android.intent.action.MAIN -c android.intent.category.LAUNCHER -p "$PACKAGE_NAME"
    if [ $? -ne 0 ]; then
        echo "Error: App launch failed."
        kill "$LOGCAT_PID" 2>/dev/null
        wait "$LOGCAT_PID" 2>/dev/null
        exit 1
    fi

    sleep "$TIMEOUT"

    # Stop the app and logcat
    adb "${ADB_DEVICE_ARGS[@]}" shell am force-stop "$PACKAGE_NAME"
    kill "$LOGCAT_PID" 2>/dev/null
    wait "$LOGCAT_PID" 2>/dev/null

    echo ""
    echo "=== Done ==="
    echo "Logcat output saved to: $OUTPUT_FILE"
    echo "Lines captured: $(wc -l < "$OUTPUT_FILE")"
fi
