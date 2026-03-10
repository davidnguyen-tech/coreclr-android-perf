#!/bin/bash

# Measures iOS physical device startup time using device log stream monitoring.
#
# This script measures iOS device app startup by installing the app via
# `xcrun devicectl`, launching it via `xcrun devicectl device process launch`,
# and monitoring `log stream --device` for the first runtime log event emitted
# by the app process. This captures the startup pipeline: process creation,
# dyld loading, runtime initialization, and framework setup.
#
# The script bypasses dotnet/performance's test.py (which uses
# `sudo log collect --device` that hangs on modern macOS) and uses
# direct device interaction via Xcode's devicectl.
#
# Prerequisites:
#   - Physical iOS device connected via USB (WiFi may work but is less reliable)
#   - Device must be trusted and have Developer Mode enabled
#   - Valid code signing identity (Xcode-managed or manual provisioning profile)
#   - Xcode 15+ (for xcrun devicectl)

source "$(dirname "$0")/../init.sh"
source "$SCRIPT_DIR/tools/apple_measure_lib.sh"

# ---------------------------------------------------------------------------
# Validate prerequisites
# ---------------------------------------------------------------------------
if [ ! -f "$LOCAL_DOTNET" ]; then
    echo "Error: $LOCAL_DOTNET does not exist. Please run ./prepare.sh first."
    exit 1
fi

if ! command -v xcrun &> /dev/null; then
    echo "Error: xcrun is required but not found. Please install Xcode."
    exit 1
fi

if ! command -v python3 &> /dev/null; then
    echo "Error: python3 is required but not found."
    exit 1
fi

if ! xcrun devicectl --version &> /dev/null; then
    echo "Error: xcrun devicectl is required but not available."
    echo "Please install Xcode 15 or later."
    exit 1
fi

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------
print_usage() {
    echo "Usage: $0 <app-name> <build-config> [options]"
    echo ""
    echo "Measures iOS physical device startup time using device log stream monitoring."
    echo ""
    echo "Apps:     dotnet-new-ios, dotnet-new-maui, dotnet-new-maui-samplecontent"
    echo "Configs:  MONO_JIT, CORECLR_JIT, MONO_AOT, MONO_PAOT, R2R_COMP, R2R_COMP_PGO"
    echo ""
    echo "Options:"
    echo "  --startup-iterations N   Number of startup iterations (default: 10)"
    echo "  --device-udid UDID       Target device UDID (auto-detected if omitted)"
    echo "  --no-build               Skip building, use existing .app bundle"
    echo "  --package-path PATH      Path to a pre-built .app bundle (implies --no-build)"
    echo "  --collect-trace           Collect a .nettrace EventPipe trace (extra iteration)"
    echo "  --help                   Show this help message"
    echo ""
    echo "Examples:"
    echo "  $0 dotnet-new-ios CORECLR_JIT"
    echo "  $0 dotnet-new-maui MONO_JIT --startup-iterations 5"
    echo "  $0 dotnet-new-ios R2R_COMP --device-udid XXXXXXXX-XXXX"
    echo "  $0 dotnet-new-ios CORECLR_JIT --package-path /path/to/MyApp.app"
    exit 1
}

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
if [[ -z "$1" || "$1" == --* ]]; then
    print_usage
fi

if [[ -z "$2" || "$2" == --* ]]; then
    echo "Error: build-config is required as the second argument."
    print_usage
fi

SAMPLE_APP=$1
BUILD_CONFIG=$2
shift 2

ITERATIONS=10
DEVICE_UDID=""
SKIP_BUILD=false
PACKAGE_PATH=""
COLLECT_TRACE=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --startup-iterations)
            if [[ -z "$2" || "$2" == --* ]]; then
                echo "Error: --startup-iterations requires a numeric value"
                exit 1
            fi
            if ! [[ "$2" =~ ^[0-9]+$ ]] || [[ "$2" -eq 0 ]]; then
                echo "Error: --startup-iterations requires a positive integer, got '$2'"
                exit 1
            fi
            ITERATIONS=$2
            shift 2
            ;;
        --device-udid)
            if [[ -z "$2" || "$2" == --* ]]; then
                echo "Error: --device-udid requires a value"
                exit 1
            fi
            DEVICE_UDID="$2"
            shift 2
            ;;
        --no-build)
            SKIP_BUILD=true
            shift
            ;;
        --package-path)
            if [[ -z "$2" || "$2" == --* ]]; then
                echo "Error: --package-path requires a path to a .app bundle"
                exit 1
            fi
            PACKAGE_PATH="$2"
            shift 2
            ;;
        --collect-trace)
            COLLECT_TRACE=true
            shift
            ;;
        --help)
            print_usage
            ;;
        *)
            echo "Unknown option: $1"
            print_usage
            ;;
    esac
done

# ---------------------------------------------------------------------------
# Validate --package-path (if provided)
# ---------------------------------------------------------------------------
if [ -n "$PACKAGE_PATH" ]; then
    # --package-path implies --no-build
    SKIP_BUILD=true

    if [ ! -d "$PACKAGE_PATH" ]; then
        echo "Error: --package-path '$PACKAGE_PATH' does not exist or is not a directory."
        exit 1
    fi

    if [[ "$PACKAGE_PATH" != *.app ]]; then
        echo "Error: --package-path must point to a .app bundle directory, got '$PACKAGE_PATH'"
        exit 1
    fi
fi

# ---------------------------------------------------------------------------
# Resolve platform configuration
# ---------------------------------------------------------------------------
resolve_platform_config "ios" || exit 1

# Validate build config (Apple platforms: no non-composite R2R)
VALID_CONFIGS="MONO_JIT CORECLR_JIT MONO_AOT MONO_PAOT R2R_COMP R2R_COMP_PGO"
if [[ ! " $VALID_CONFIGS " =~ " $BUILD_CONFIG " ]]; then
    echo "Invalid build config '$BUILD_CONFIG'. Allowed values are: $VALID_CONFIGS"
    exit 1
fi

# Validate app directory (only needed when not using --package-path)
APP_DIR="$APPS_DIR/$SAMPLE_APP"
if [ -z "$PACKAGE_PATH" ] && [ ! -d "$APP_DIR" ]; then
    echo "Error: App directory $APP_DIR does not exist."
    echo "Run ./generate-apps.sh --platform ios first."
    exit 1
fi

# ---------------------------------------------------------------------------
# Device detection
# ---------------------------------------------------------------------------
echo "--- Detecting connected device ---"

if [ -n "$DEVICE_UDID" ]; then
    echo "Using provided device UDID: $DEVICE_UDID"
else
    echo "Auto-detecting connected iOS device..."
    DEVICE_UDID=$(get_connected_device_udid)
    if [ -z "$DEVICE_UDID" ]; then
        echo "Error: No connected iOS device found."
        echo ""
        echo "Ensure:"
        echo "  1. A physical iPhone/iPad is connected via USB"
        echo "  2. The device is unlocked and trusted"
        echo "  3. Developer Mode is enabled (Settings > Privacy & Security > Developer Mode)"
        echo ""
        echo "To list connected devices: xcrun devicectl list devices"
        exit 1
    fi
fi

# Get device info for display
DEVICE_INFO=$(xcrun devicectl list devices --json-output /dev/stdout 2>/dev/null | python3 -c "
import json, sys
udid = sys.argv[1]
data = json.load(sys.stdin)
for d in data.get('result', {}).get('devices', []):
    if d.get('identifier') == udid:
        name = d.get('deviceProperties', {}).get('name', 'Unknown')
        os_ver = d.get('deviceProperties', {}).get('osVersionNumber', 'Unknown')
        print(f'{name} (iOS {os_ver})')
        sys.exit(0)
print('Unknown Device')
" "$DEVICE_UDID" 2>/dev/null)
echo "Device: $DEVICE_INFO ($DEVICE_UDID)"

# ---------------------------------------------------------------------------
# Build the app
# ---------------------------------------------------------------------------
if [ "$SKIP_BUILD" = false ]; then
    echo ""
    echo "=== Building $SAMPLE_APP ($BUILD_CONFIG) for ios ==="

    # Clean previous build artifacts
    rm -rf "${APP_DIR:?}/bin" "${APP_DIR:?}/obj"

    mkdir -p "$BUILD_DIR"

    # Capture wall-clock build time as a fallback
    BUILD_START_NS=$(get_timestamp_ns)

    ${LOCAL_DOTNET} build -c Release \
        -f "$PLATFORM_TFM" -r "$PLATFORM_RID" \
        -tl:off \
        -bl:"$BUILD_DIR/${SAMPLE_APP}_${BUILD_CONFIG}_device.binlog" \
        "$APP_DIR/$SAMPLE_APP.csproj" \
        -p:_BuildConfig="$BUILD_CONFIG"

    if [ $? -ne 0 ]; then
        echo "Error: Build failed."
        exit 1
    fi

    BUILD_END_NS=$(get_timestamp_ns)
    WALLCLOCK_BUILD_MS=$(elapsed_ms "$BUILD_START_NS" "$BUILD_END_NS")

    # Try detailed build time parsing from the binlog
    BINLOG_PATH="$BUILD_DIR/${SAMPLE_APP}_${BUILD_CONFIG}_device.binlog"
    BUILDTIME_OUTPUT=$(run_buildtime_parser "$BINLOG_PATH" "${SAMPLE_APP}_${BUILD_CONFIG}_device" 2>&1) || true
    if echo "$BUILDTIME_OUTPUT" | grep -q "Build time:"; then
        echo "$BUILDTIME_OUTPUT"
    else
        # Fall back to wall-clock build time
        echo "Build time: ${WALLCLOCK_BUILD_MS} ms"
    fi
else
    echo ""
    echo "=== Skipping build (--no-build) ==="
fi

# ---------------------------------------------------------------------------
# Locate the .app bundle
# ---------------------------------------------------------------------------
echo ""
echo "--- Locating app bundle ---"

if [ -n "$PACKAGE_PATH" ]; then
    # Use externally provided .app bundle
    APP_BUNDLE="$PACKAGE_PATH"
    echo "Using pre-built app bundle: $APP_BUNDLE"
else
    # Search in bin/ first, fall back to broader search excluding obj/
    APP_BUNDLE=$(find "$APP_DIR/bin" -type d -name "*.app" -not -path "*/obj/*" 2>/dev/null | head -1)
    if [ -z "$APP_BUNDLE" ]; then
        APP_BUNDLE=$(find "$APP_DIR" -type d -name "*.app" -not -path "*/obj/*" 2>/dev/null | head -1)
    fi
    if [ -z "$APP_BUNDLE" ]; then
        echo "Error: Could not find .app bundle in $APP_DIR"
        echo "Ensure the app has been built with: ./build.sh --platform ios $SAMPLE_APP $BUILD_CONFIG build 1"
        exit 1
    fi

    echo "Found app bundle: $APP_BUNDLE"
fi

# Record package size (use du -sk for directory bundles)
PACKAGE_SIZE_KB=$(du -sk "$APP_BUNDLE" | cut -f1)
PACKAGE_SIZE_BYTES=$((PACKAGE_SIZE_KB * 1024))
PACKAGE_SIZE_MB=$(python3 -c "print(f'{$PACKAGE_SIZE_BYTES / 1048576:.2f}')")
echo "Package size: ${PACKAGE_SIZE_MB} MB ($PACKAGE_SIZE_BYTES bytes)"

# ---------------------------------------------------------------------------
# Extract bundle identifier from Info.plist
# ---------------------------------------------------------------------------
BUNDLE_ID=""
PLIST_PATH="$APP_BUNDLE/Info.plist"
if [ -f "$PLIST_PATH" ]; then
    BUNDLE_ID=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$PLIST_PATH" 2>/dev/null)
fi

if [ -z "$BUNDLE_ID" ]; then
    # Fallback: derive from csproj or app name
    BUNDLE_ID=$(grep -o '<ApplicationId>[^<]*' "$APP_DIR/$SAMPLE_APP.csproj" 2>/dev/null | sed 's/<ApplicationId>//')
    if [ -z "$BUNDLE_ID" ]; then
        BUNDLE_ID="com.companyname.$(echo "$SAMPLE_APP" | tr '-' '_')"
    fi
    echo "Warning: Could not read bundle ID from Info.plist, using fallback: $BUNDLE_ID"
fi

echo "Bundle ID: $BUNDLE_ID"

# ---------------------------------------------------------------------------
# Extract CFBundleExecutable for log stream filtering
# ---------------------------------------------------------------------------
EXECUTABLE_NAME=""
if [ -f "$PLIST_PATH" ]; then
    EXECUTABLE_NAME=$(/usr/libexec/PlistBuddy -c "Print :CFBundleExecutable" "$PLIST_PATH" 2>/dev/null || true)
fi
if [ -z "$EXECUTABLE_NAME" ]; then
    EXECUTABLE_NAME=$(basename "$APP_BUNDLE" .app)
    echo "Warning: Could not read CFBundleExecutable, using fallback: $EXECUTABLE_NAME"
fi
echo "Executable: $EXECUTABLE_NAME"

# ---------------------------------------------------------------------------
# Cleanup function
# ---------------------------------------------------------------------------
cleanup() {
    echo ""
    echo "--- Cleaning up ---"
    stop_device_log_stream
    # Uninstall the app from the device
    uninstall_app_from_device "$DEVICE_UDID" "$BUNDLE_ID"
}

trap cleanup EXIT

# ---------------------------------------------------------------------------
# Trace collection (deferred — not yet supported for physical devices)
# ---------------------------------------------------------------------------
if [ "$COLLECT_TRACE" = true ]; then
    echo ""
    echo "Warning: --collect-trace is not yet supported for iOS physical devices."
    echo "Device trace collection requires dotnet-dsrouter. Use ios/collect_nettrace.sh instead."
    echo ""
fi

# ---------------------------------------------------------------------------
# Measurement loop
# ---------------------------------------------------------------------------
echo ""
echo "=== Measuring startup ($ITERATIONS iterations) ==="
echo ""

TIMES=()
FAILED_COUNT=0

for ((i = 1; i <= ITERATIONS; i++)); do
    # Clean state: terminate any running instance and uninstall
    terminate_app_on_device "$DEVICE_UDID" "$BUNDLE_ID"
    uninstall_app_from_device "$DEVICE_UDID" "$BUNDLE_ID"

    # Fresh install
    INSTALL_OUTPUT=$(install_app_on_device "$DEVICE_UDID" "$APP_BUNDLE" 2>&1)
    if [ $? -ne 0 ]; then
        echo "  [$i/$ITERATIONS] FAILED — could not install app on device"
        echo "    $INSTALL_OUTPUT" | head -3
        FAILED_COUNT=$((FAILED_COUNT + 1))
        continue
    fi

    # Start device log stream BEFORE launching the app
    start_device_log_stream "process == \"$EXECUTABLE_NAME\""

    # Capture start timestamp
    START_NS=$(get_timestamp_ns)

    # Launch the app on the device
    LAUNCH_OUTPUT=$(launch_app_on_device "$DEVICE_UDID" "$BUNDLE_ID" 2>&1)
    LAUNCH_RESULT=$?

    if [ $LAUNCH_RESULT -ne 0 ]; then
        stop_device_log_stream
        echo "  [$i/$ITERATIONS] FAILED — devicectl launch returned $LAUNCH_RESULT"
        echo "    $LAUNCH_OUTPUT" | head -3
        FAILED_COUNT=$((FAILED_COUNT + 1))
        continue
    fi

    # Wait for the app's first device log event (indicates runtime initialization)
    if ! wait_for_device_log_event "$EXECUTABLE_NAME" 60 > /dev/null; then
        END_NS=$(get_timestamp_ns)
        stop_device_log_stream
        echo "  [$i/$ITERATIONS] FAILED — no device log events within 60s"
        terminate_app_on_device "$DEVICE_UDID" "$BUNDLE_ID"
        FAILED_COUNT=$((FAILED_COUNT + 1))
        continue
    fi

    END_NS=$(get_timestamp_ns)
    stop_device_log_stream

    ELAPSED_MS=$(elapsed_ms "$START_NS" "$END_NS")
    TIMES+=("$ELAPSED_MS")

    echo "  [$i/$ITERATIONS] ${ELAPSED_MS} ms"

    # Terminate the app before next iteration
    terminate_app_on_device "$DEVICE_UDID" "$BUNDLE_ID"

    # Brief pause between iterations to let the device settle
    sleep 2
done

# ---------------------------------------------------------------------------
# Compute statistics
# ---------------------------------------------------------------------------
echo ""

if [ ${#TIMES[@]} -eq 0 ]; then
    echo "Error: No successful measurements out of $ITERATIONS iterations."
    exit 1
fi

# Use shared library for reliable statistics computation
STATS=$(compute_stats "${TIMES[@]}")

AVG=$(echo "$STATS" | sed -n '1p')
MEDIAN=$(echo "$STATS" | sed -n '2p')
MIN=$(echo "$STATS" | sed -n '3p')
MAX=$(echo "$STATS" | sed -n '4p')
STDEV=$(echo "$STATS" | sed -n '5p')
COUNT=$(echo "$STATS" | sed -n '6p')

echo "=== Results ==="
echo ""
echo "App:        $SAMPLE_APP"
echo "Config:     $BUILD_CONFIG"
echo "Device:     $DEVICE_INFO ($DEVICE_UDID)"
echo "Iterations: $COUNT / $ITERATIONS ($(( FAILED_COUNT )) failed)"
echo ""
echo "  Avg:    ${AVG} ms"
echo "  Median: ${MEDIAN} ms"
echo "  Min:    ${MIN} ms"
echo "  Max:    ${MAX} ms"
echo "  StdDev: ${STDEV} ms"
echo ""

# Output parseable summary line compatible with measure_all.sh parsing
print_measurement_summary "$AVG" "$MIN" "$MAX" "$PACKAGE_SIZE_MB" "$PACKAGE_SIZE_BYTES"

# ---------------------------------------------------------------------------
# Save detailed results to CSV
# ---------------------------------------------------------------------------
mkdir -p "$RESULTS_DIR"
RESULT_FILE="$RESULTS_DIR/${SAMPLE_APP}_${BUILD_CONFIG}_device.csv"
save_results_csv "$RESULT_FILE" "$SAMPLE_APP" "$BUILD_CONFIG" "device" \
    "$PACKAGE_SIZE_MB" "$PACKAGE_SIZE_BYTES" \
    "$AVG" "$MEDIAN" "$MIN" "$MAX" "$STDEV" "$COUNT" "${TIMES[@]}"

echo ""
echo "Results saved to: $RESULT_FILE"
