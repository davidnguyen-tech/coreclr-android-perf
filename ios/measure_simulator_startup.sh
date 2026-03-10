#!/bin/bash

# Measures iOS Simulator startup time using OS log event timing.
#
# This script measures iOS Simulator app startup by launching the app via
# `xcrun simctl launch` and monitoring `log stream` for the first runtime
# log event emitted by the app process. This captures the startup pipeline:
# process creation, dyld loading, runtime initialization, and framework setup.
#
# The script bypasses dotnet/performance's test.py (which only supports
# physical iOS devices) and uses direct simulator interaction.

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

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------
print_usage() {
    echo "Usage: $0 <app-name> <build-config> [options]"
    echo ""
    echo "Measures iOS Simulator startup time using OS log event timing."
    echo ""
    echo "Apps:     dotnet-new-ios, dotnet-new-maui, dotnet-new-maui-samplecontent"
    echo "Configs:  MONO_JIT, CORECLR_JIT, MONO_AOT, MONO_PAOT, R2R_COMP, R2R_COMP_PGO"
    echo ""
    echo "Options:"
    echo "  --startup-iterations N   Number of startup iterations (default: 10)"
    echo "  --simulator-name NAME    Simulator name (e.g. 'iPhone 16')"
    echo "  --simulator-udid UDID    Simulator UDID (overrides --simulator-name)"
    echo "  --no-build               Skip building, use existing .app bundle"
    echo "  --package-path PATH      Path to a pre-built .app bundle (implies --no-build)"
    echo "  --collect-trace           Collect a .nettrace EventPipe trace (extra iteration, excluded from timing)"
    echo "  --help                   Show this help message"
    echo ""
    echo "Examples:"
    echo "  $0 dotnet-new-ios CORECLR_JIT"
    echo "  $0 dotnet-new-maui MONO_JIT --startup-iterations 5"
    echo "  $0 dotnet-new-ios R2R_COMP --simulator-name 'iPhone 16' --no-build"
    echo "  $0 dotnet-new-ios CORECLR_JIT --package-path /path/to/MyApp.app"
    echo "  $0 dotnet-new-ios CORECLR_JIT --collect-trace"
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
SIM_NAME=""
SIM_UDID=""
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
        --simulator-name)
            if [[ -z "$2" || "$2" == --* ]]; then
                echo "Error: --simulator-name requires a value"
                exit 1
            fi
            SIM_NAME="$2"
            shift 2
            ;;
        --simulator-udid)
            if [[ -z "$2" || "$2" == --* ]]; then
                echo "Error: --simulator-udid requires a value"
                exit 1
            fi
            SIM_UDID="$2"
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
resolve_platform_config "ios-simulator" || exit 1

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
    echo "Run ./generate-apps.sh --platform ios-simulator first."
    exit 1
fi

# ---------------------------------------------------------------------------
# Simulator detection / boot
# ---------------------------------------------------------------------------
get_booted_simulator_udid() {
    xcrun simctl list devices booted -j 2>/dev/null | python3 -c "
import sys, json
data = json.load(sys.stdin)
for runtime, device_list in data.get('devices', {}).items():
    for d in device_list:
        if d.get('state') == 'Booted':
            print(d['udid'])
            sys.exit(0)
" 2>/dev/null
}

find_simulator_by_name() {
    local name="$1"
    xcrun simctl list devices available -j 2>/dev/null | python3 -c "
import sys, json
name = sys.argv[1]
data = json.load(sys.stdin)
for runtime, device_list in data.get('devices', {}).items():
    for d in device_list:
        if d.get('name') == name and d.get('isAvailable', False):
            print(d['udid'])
            sys.exit(0)
sys.exit(1)
" "$name" 2>/dev/null
}

find_any_available_iphone() {
    xcrun simctl list devices available -j 2>/dev/null | python3 -c "
import sys, json
data = json.load(sys.stdin)
# Prefer newer runtimes (sorted reverse) and iPhone devices
for runtime in sorted(data.get('devices', {}).keys(), reverse=True):
    for d in data['devices'][runtime]:
        if d.get('isAvailable', False) and 'iPhone' in d.get('name', ''):
            print(d['udid'])
            sys.exit(0)
sys.exit(1)
" 2>/dev/null
}

get_simulator_info() {
    local udid="$1"
    xcrun simctl list devices -j 2>/dev/null | python3 -c "
import sys, json
udid = sys.argv[1]
data = json.load(sys.stdin)
for runtime, device_list in data.get('devices', {}).items():
    for d in device_list:
        if d['udid'] == udid:
            print(d.get('name', 'Unknown'))
            print(d.get('state', 'Unknown'))
            sys.exit(0)
print('Unknown')
print('Unknown')
" "$udid" 2>/dev/null
}

echo "--- Detecting simulator ---"

if [ -n "$SIM_UDID" ]; then
    echo "Using provided simulator UDID: $SIM_UDID"
elif [ -n "$SIM_NAME" ]; then
    echo "Looking for simulator named '$SIM_NAME'..."
    SIM_UDID=$(find_simulator_by_name "$SIM_NAME")
    if [ -z "$SIM_UDID" ]; then
        echo "Error: No available simulator found with name '$SIM_NAME'."
        echo "Available simulators:"
        xcrun simctl list devices available | grep -i iphone | head -10
        exit 1
    fi
    echo "Found simulator: $SIM_UDID"
else
    echo "Auto-detecting booted simulator..."
    SIM_UDID=$(get_booted_simulator_udid)
    if [ -z "$SIM_UDID" ]; then
        echo "No booted simulator found. Looking for an available iPhone simulator..."
        SIM_UDID=$(find_any_available_iphone)
        if [ -z "$SIM_UDID" ]; then
            echo "Error: No available iPhone simulator found."
            echo "Create one with: xcrun simctl create 'iPhone 16' 'com.apple.CoreSimulator.SimDeviceType.iPhone-16'"
            exit 1
        fi
    fi
fi

# Read simulator name and state
SIM_INFO=$(get_simulator_info "$SIM_UDID")
SIM_NAME_RESOLVED=$(echo "$SIM_INFO" | sed -n '1p')
SIM_STATE=$(echo "$SIM_INFO" | sed -n '2p')

# Boot if needed
if [ "$SIM_STATE" != "Booted" ]; then
    echo "Simulator '$SIM_NAME_RESOLVED' is not booted (state: $SIM_STATE). Booting..."
    xcrun simctl boot "$SIM_UDID"
    if [ $? -ne 0 ]; then
        echo "Error: Failed to boot simulator $SIM_UDID"
        exit 1
    fi
    echo "Waiting for simulator to boot..."
    # Wait until SpringBoard is running — indicates the simulator is usable
    xcrun simctl bootstatus "$SIM_UDID" -b 2>/dev/null || sleep 10
fi

echo "Simulator: $SIM_NAME_RESOLVED ($SIM_UDID)"

# ---------------------------------------------------------------------------
# Build the app
# ---------------------------------------------------------------------------
if [ "$SKIP_BUILD" = false ]; then
    echo ""
    echo "=== Building $SAMPLE_APP ($BUILD_CONFIG) for ios-simulator ==="

    # Clean previous build artifacts
    rm -rf "${APP_DIR:?}/bin" "${APP_DIR:?}/obj"

    mkdir -p "$BUILD_DIR"

    # Capture wall-clock build time as a fallback
    BUILD_START_NS=$(get_timestamp_ns)

    ${LOCAL_DOTNET} build -c Release \
        -f "$PLATFORM_TFM" -r "$PLATFORM_RID" \
        -tl:off \
        -bl:"$BUILD_DIR/${SAMPLE_APP}_${BUILD_CONFIG}_sim.binlog" \
        "$APP_DIR/$SAMPLE_APP.csproj" \
        -p:_BuildConfig="$BUILD_CONFIG"

    if [ $? -ne 0 ]; then
        echo "Error: Build failed."
        exit 1
    fi

    BUILD_END_NS=$(get_timestamp_ns)
    WALLCLOCK_BUILD_MS=$(elapsed_ms "$BUILD_START_NS" "$BUILD_END_NS")

    # Try detailed build time parsing from the binlog
    BINLOG_PATH="$BUILD_DIR/${SAMPLE_APP}_${BUILD_CONFIG}_sim.binlog"
    BUILDTIME_OUTPUT=$(run_buildtime_parser "$BINLOG_PATH" "${SAMPLE_APP}_${BUILD_CONFIG}_sim" 2>&1) || true
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
        echo "Ensure the app has been built with: ./build.sh --platform ios-simulator $SAMPLE_APP $BUILD_CONFIG build 1"
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
    stop_log_stream
    unset_simctl_eventpipe_env
    xcrun simctl terminate "$SIM_UDID" "$BUNDLE_ID" 2>/dev/null || true
    xcrun simctl uninstall "$SIM_UDID" "$BUNDLE_ID" 2>/dev/null || true
}

trap cleanup EXIT

# ---------------------------------------------------------------------------
# Trace collection (extra iteration, excluded from timing)
# ---------------------------------------------------------------------------
TRACE_FILE=""

if [ "$COLLECT_TRACE" = true ]; then
    echo ""
    echo "=== Collecting .nettrace trace (extra iteration, excluded from timing) ==="

    # Ensure results directory exists
    mkdir -p "$RESULTS_DIR"
    TRACE_OUTPUT_PATH="/tmp/${SAMPLE_APP}_${BUILD_CONFIG}_sim_$$.nettrace"
    TRACE_FILE="$RESULTS_DIR/${SAMPLE_APP}_${BUILD_CONFIG}_simulator.nettrace"

    # Clean state
    xcrun simctl terminate "$SIM_UDID" "$BUNDLE_ID" 2>/dev/null || true
    xcrun simctl uninstall "$SIM_UDID" "$BUNDLE_ID" 2>/dev/null || true

    # Fresh install
    xcrun simctl install "$SIM_UDID" "$APP_BUNDLE" 2>/dev/null
    if [ $? -ne 0 ]; then
        echo "  [trace] Warning: Could not install app for trace collection"
        TRACE_FILE=""
    else
        # Set SIMCTL_CHILD_ prefixed env vars so the simulator passes them to the app
        setup_simctl_eventpipe_env "$TRACE_OUTPUT_PATH"

        echo "  [trace] Launching $EXECUTABLE_NAME with EventPipe enabled..."
        echo "  [trace] Trace output: $TRACE_OUTPUT_PATH"

        # Start log stream to detect startup
        start_log_stream "process == \"$EXECUTABLE_NAME\""

        # Launch the app
        xcrun simctl launch "$SIM_UDID" "$BUNDLE_ID" > /dev/null 2>&1
        LAUNCH_RESULT=$?

        if [ $LAUNCH_RESULT -ne 0 ]; then
            stop_log_stream
            echo "  [trace] Warning: simctl launch failed ($LAUNCH_RESULT)"
            TRACE_FILE=""
        else
            # Wait for the app to start
            if wait_for_log_event "$EXECUTABLE_NAME" 60 > /dev/null; then
                echo "  [trace] App started — waiting for trace events to flush..."
                # Give time for events to be written
                sleep 3
            else
                echo "  [trace] Warning: No log events within 60s, continuing anyway"
                sleep 5
            fi
            stop_log_stream

            # Terminate the app — triggers trace file flush
            xcrun simctl terminate "$SIM_UDID" "$BUNDLE_ID" 2>/dev/null || true
        fi

        # Unset SIMCTL_CHILD_ env vars immediately
        unset_simctl_eventpipe_env

        # Wait briefly for the trace file to be fully written
        sleep 1

        # Find the trace file. It may be at the output path directly, or
        # inside the simulator's app data container.
        SEARCH_DIRS="/tmp"
        APP_DATA_CONTAINER=$(xcrun simctl get_app_container "$SIM_UDID" "$BUNDLE_ID" data 2>/dev/null || true)
        if [ -n "$APP_DATA_CONTAINER" ]; then
            SEARCH_DIRS="$SEARCH_DIRS $APP_DATA_CONTAINER"
        fi

        if [ -n "$TRACE_FILE" ]; then
            if collect_nettrace "$TRACE_OUTPUT_PATH" "$TRACE_FILE" "$SEARCH_DIRS"; then
                echo "  [trace] Success"
            else
                echo "  [trace] Warning: Could not collect .nettrace file"
                TRACE_FILE=""
            fi
        fi

        # Uninstall after trace collection
        xcrun simctl uninstall "$SIM_UDID" "$BUNDLE_ID" 2>/dev/null || true
    fi

    # Brief pause before timing iterations
    sleep 1
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
    xcrun simctl terminate "$SIM_UDID" "$BUNDLE_ID" 2>/dev/null || true
    xcrun simctl uninstall "$SIM_UDID" "$BUNDLE_ID" 2>/dev/null || true

    # Fresh install
    xcrun simctl install "$SIM_UDID" "$APP_BUNDLE" 2>/dev/null
    if [ $? -ne 0 ]; then
        echo "  [$i/$ITERATIONS] FAILED — could not install app"
        FAILED_COUNT=$((FAILED_COUNT + 1))
        continue
    fi

    # Start log stream BEFORE launching the app
    start_log_stream "process == \"$EXECUTABLE_NAME\""

    # Capture start timestamp
    START_NS=$(get_timestamp_ns)

    # Launch the app
    xcrun simctl launch "$SIM_UDID" "$BUNDLE_ID" > /dev/null 2>&1
    LAUNCH_RESULT=$?

    if [ $LAUNCH_RESULT -ne 0 ]; then
        stop_log_stream
        echo "  [$i/$ITERATIONS] FAILED — simctl launch returned $LAUNCH_RESULT"
        FAILED_COUNT=$((FAILED_COUNT + 1))
        continue
    fi

    # Wait for the app's first log event (indicates runtime initialization)
    if ! wait_for_log_event "$EXECUTABLE_NAME" 30 > /dev/null; then
        END_NS=$(get_timestamp_ns)
        stop_log_stream
        echo "  [$i/$ITERATIONS] FAILED — no log events within 30s"
        xcrun simctl terminate "$SIM_UDID" "$BUNDLE_ID" 2>/dev/null || true
        FAILED_COUNT=$((FAILED_COUNT + 1))
        continue
    fi

    END_NS=$(get_timestamp_ns)
    stop_log_stream

    ELAPSED_MS=$(elapsed_ms "$START_NS" "$END_NS")
    TIMES+=("$ELAPSED_MS")

    echo "  [$i/$ITERATIONS] ${ELAPSED_MS} ms"

    # Terminate the app before next iteration
    xcrun simctl terminate "$SIM_UDID" "$BUNDLE_ID" 2>/dev/null || true

    # Brief pause between iterations to let the simulator settle
    sleep 1
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
echo "Simulator:  $SIM_NAME_RESOLVED ($SIM_UDID)"
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
RESULT_FILE="$RESULTS_DIR/${SAMPLE_APP}_${BUILD_CONFIG}_simulator.csv"
save_results_csv "$RESULT_FILE" "$SAMPLE_APP" "$BUILD_CONFIG" "$SIM_NAME_RESOLVED" \
    "$PACKAGE_SIZE_MB" "$PACKAGE_SIZE_BYTES" \
    "$AVG" "$MEDIAN" "$MIN" "$MAX" "$STDEV" "$COUNT" "${TIMES[@]}"

echo ""
echo "Results saved to: $RESULT_FILE"

# Report trace file location if collected
if [ -n "$TRACE_FILE" ] && [ -f "$TRACE_FILE" ]; then
    echo "Trace saved to: $TRACE_FILE"
fi
