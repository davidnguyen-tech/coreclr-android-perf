#!/bin/bash

# Measures iOS physical device startup time using SpringBoard Watchdog events.
#
# This script measures iOS device app startup by installing the app via
# `xcrun devicectl`, launching it via `xcrun devicectl device process launch`,
# and collecting device logs post-hoc via `sudo log collect --device`.
# It then parses SpringBoard Watchdog events from the collected logarchive
# to extract precise time-to-main and time-to-first-draw measurements.
#
# This approach is adapted from dotnet/performance's runner.py, which uses
# the same `sudo log collect --device` + SpringBoard Watchdog event parsing
# technique for iOS device startup measurement in CI.
#
# The script uses a warmup iteration (iteration 0) to establish a device-side
# time reference, avoiding host-device clock drift issues.
#
# Prerequisites:
#   - Physical iOS device connected via USB (WiFi may work but is less reliable)
#   - Device must be trusted and have Developer Mode enabled
#   - Valid code signing identity (Xcode-managed or manual provisioning profile)
#   - Xcode 15+ (for xcrun devicectl)
#   - Passwordless sudo configured for `log collect` (device log collection)

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

# Note: This script requires passwordless sudo for /usr/bin/log.
# The 'collect_device_logs' function runs 'sudo log collect --device-udid ...'
# and will fail with a clear error if sudo is not configured.
# See ios/README.md for setup instructions.

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------
print_usage() {
    echo "Usage: $0 <app-name> <build-config> [options]"
    echo ""
    echo "Measures iOS physical device startup time using SpringBoard Watchdog events."
    echo "Requires passwordless sudo for 'log collect --device'."
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
info_json=$(mktemp /tmp/devicectl_info.XXXXXX.json)
xcrun devicectl list devices --json-output "$info_json" >/dev/null 2>&1
# Parse the device info from the JSON file, filtering by DEVICE_UDID
DEVICE_INFO=$(python3 -c "
import json, sys
try:
    data = json.load(open('$info_json'))
    devices = data.get('result', {}).get('devices', [])
    for d in devices:
        if d.get('identifier', '') == '$DEVICE_UDID':
            dp = d.get('deviceProperties', {})
            hw = d.get('hardwareProperties', {})
            name = dp.get('name', 'Unknown')
            model = hw.get('marketingName', hw.get('productType', 'Unknown'))
            version = dp.get('osVersionNumber', 'Unknown')
            print(f'{name} ({model}, iOS {version})')
            sys.exit(0)
    print('Unknown Device')
except Exception:
    print('Unknown Device')
" 2>/dev/null)
rm -f "$info_json"
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
# Cleanup function
# ---------------------------------------------------------------------------
cleanup() {
    echo ""
    echo "--- Cleaning up ---"
    # Remove any leftover logarchives from this run
    rm -rf /tmp/ios_startup_iteration_*.logarchive
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
# Uses the same approach as dotnet/performance's runner.py:
#   - Iteration 0 is a warmup to establish device-side time reference
#   - Subsequent iterations measure startup via SpringBoard Watchdog events
#   - Inter-iteration wait is 3s (uninstall/reinstall provides additional settling)
#   - Each iteration: launch → wait 3s → collect logs → terminate → parse events
#
# NOTE: Unlike runner.py which keeps the app installed between iterations (warm starts),
# we uninstall/reinstall each iteration to measure cold-start performance consistently.
# This matches the behavior of the simulator measurement script (ios/measure_simulator_startup.sh).
echo ""
echo "=== Measuring startup ($ITERATIONS iterations + 1 warmup) ==="
echo ""

TIMES=()
FAILED_COUNT=0

# NEXT_COLLECT_START tracks the device-side reference timestamp for --start.
# Initialized with a generous 30-second lookback from host time.
# The warmup iteration updates it to a device-side timestamp.
NEXT_COLLECT_START=""

# APP_PID tracks the PID of the launched app for reliable termination.
APP_PID=""

for ((i = 0; i <= ITERATIONS; i++)); do
    # Clean state: terminate any running instance (using PID from previous iteration)
    terminate_app_on_device "$DEVICE_UDID" "$BUNDLE_ID" "$APP_PID"
    APP_PID=""

    # Wait between iterations — 3s is sufficient since uninstall/reinstall
    # provides additional settling time (~4-7s of I/O).
    if [ $i -gt 0 ]; then
        sleep 3
    else
        # Shorter wait before warmup
        sleep 2
    fi

    # Uninstall and reinstall for a cold start
    uninstall_app_from_device "$DEVICE_UDID" "$BUNDLE_ID"

    INSTALL_OUTPUT=$(install_app_on_device "$DEVICE_UDID" "$APP_BUNDLE" 2>&1)
    if [ $? -ne 0 ]; then
        if [ $i -eq 0 ]; then
            echo "Error: Warmup failed — could not install app on device."
            echo "  $INSTALL_OUTPUT" | head -3
            exit 1
        fi
        echo "  [$i/$ITERATIONS] FAILED — could not install app on device"
        echo "    $INSTALL_OUTPUT" | head -3
        FAILED_COUNT=$((FAILED_COUNT + 1))
        continue
    fi

    # Determine the --start timestamp for log collection.
    # For warmup (i=0), use a generous lookback from host time.
    # For subsequent iterations, use the device-side reference from the previous iteration.
    if [ $i -eq 0 ] || [ -z "$NEXT_COLLECT_START" ]; then
        COLLECT_START=$(date -v-30S '+%Y-%m-%d %H:%M:%S%z')
    else
        COLLECT_START="$NEXT_COLLECT_START"
    fi

    # Launch the app on the device — capture PID from stdout for later termination
    APP_PID=$(launch_app_on_device "$DEVICE_UDID" "$BUNDLE_ID" 2>/tmp/ios_launch_stderr.txt)
    LAUNCH_RESULT=$?

    if [ $LAUNCH_RESULT -ne 0 ]; then
        LAUNCH_ERRORS=$(cat /tmp/ios_launch_stderr.txt 2>/dev/null)
        if [ $i -eq 0 ]; then
            echo "Error: Warmup failed — could not launch app on device."
            echo "  $LAUNCH_ERRORS" | head -3
            exit 1
        fi
        echo "  [$i/$ITERATIONS] FAILED — devicectl launch returned $LAUNCH_RESULT"
        echo "    $LAUNCH_ERRORS" | head -3
        FAILED_COUNT=$((FAILED_COUNT + 1))
        APP_PID=""
        continue
    fi

    # Wait for the app to fully start — 3s is sufficient for apps that start
    # in ~250ms, allowing time for the OS to emit all Watchdog events.
    sleep 3

    # Collect device logs for this iteration
    LOGARCHIVE="/tmp/ios_startup_iteration_${i}.logarchive"
    COLLECT_OUTPUT=$(collect_device_logs "$DEVICE_UDID" "$COLLECT_START" "$LOGARCHIVE" 2>&1)
    COLLECT_RESULT=$?

    # Terminate the app now that logs are collected (using captured PID)
    terminate_app_on_device "$DEVICE_UDID" "$BUNDLE_ID" "$APP_PID"
    APP_PID=""

    if [ $COLLECT_RESULT -ne 0 ]; then
        if [ $i -eq 0 ]; then
            echo "Error: Warmup failed — could not collect device logs."
            echo "  $COLLECT_OUTPUT" | head -3
            exit 1
        fi
        echo "  [$i/$ITERATIONS] FAILED — log collect returned $COLLECT_RESULT"
        echo "    $COLLECT_OUTPUT" | head -3
        FAILED_COUNT=$((FAILED_COUNT + 1))
        rm -rf "$LOGARCHIVE"
        continue
    fi

    # --- Warmup iteration: establish device time reference ---
    if [ $i -eq 0 ]; then
        LAST_TS=$(get_last_watchdog_timestamp "$LOGARCHIVE" "$BUNDLE_ID")
        if [ -z "$LAST_TS" ]; then
            echo "Error: Warmup failed — no SpringBoard Watchdog events found in device logs."
            echo "This could mean:"
            echo "  - The app crashed on launch"
            echo "  - The host and device clocks are too far out of sync"
            echo "  - The app bundle ID '$BUNDLE_ID' doesn't match what SpringBoard sees"
            rm -rf "$LOGARCHIVE"
            exit 1
        fi

        NEXT_COLLECT_START=$(advance_timestamp "$LAST_TS" 1)
        echo "  [warmup] OK — device time reference established"

        # Try to show warmup timing for debugging
        WARMUP_TIMING=$(parse_watchdog_timing "$LOGARCHIVE" "$BUNDLE_ID" 2>/dev/null) || true
        if [ -n "$WARMUP_TIMING" ]; then
            WARMUP_MAIN=$(echo "$WARMUP_TIMING" | sed -n '2p')
            WARMUP_DRAW=$(echo "$WARMUP_TIMING" | sed -n '3p')
            echo "           (time-to-main: ${WARMUP_MAIN} ms, time-to-draw: ${WARMUP_DRAW} ms)"
        fi

        rm -rf "$LOGARCHIVE"
        continue
    fi

    # --- Real measurement iteration ---
    # parse_watchdog_timing returns 4 lines: total_ms, main_ms, draw_ms, last_timestamp
    # This avoids a separate get_last_watchdog_timestamp() call (saving 1-3s per iteration).
    TIMING=$(parse_watchdog_timing "$LOGARCHIVE" "$BUNDLE_ID" 2>&1)
    PARSE_RESULT=$?

    if [ $PARSE_RESULT -ne 0 ]; then
        echo "  [$i/$ITERATIONS] FAILED — could not parse Watchdog events"
        echo "    $TIMING" | head -3
        FAILED_COUNT=$((FAILED_COUNT + 1))
        rm -rf "$LOGARCHIVE"
        continue
    fi

    TOTAL_MS=$(echo "$TIMING" | sed -n '1p')
    TIME_TO_MAIN=$(echo "$TIMING" | sed -n '2p')
    TIME_TO_DRAW=$(echo "$TIMING" | sed -n '3p')
    LAST_TS=$(echo "$TIMING" | sed -n '4p')

    # Update device-side reference for next iteration (from parse_watchdog_timing line 4)
    if [ -n "$LAST_TS" ]; then
        NEXT_COLLECT_START=$(advance_timestamp "$LAST_TS" 1)
    fi

    TIMES+=("$TOTAL_MS")
    echo "  [$i/$ITERATIONS] ${TOTAL_MS} ms (main: ${TIME_TO_MAIN}, draw: ${TIME_TO_DRAW})"

    # Cleanup logarchive
    rm -rf "$LOGARCHIVE"
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
