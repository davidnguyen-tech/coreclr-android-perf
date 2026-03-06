#!/bin/bash

# Measures iOS Simulator startup time using wall-clock timing.
#
# This script bypasses the dotnet/performance test.py (which only supports
# physical iOS devices with hardcoded --target ios-device and sudo log collect
# --device) and uses xcrun simctl for simulator-based measurement.
#
# Startup time is measured as the wall-clock duration of `xcrun simctl launch`,
# which returns after the app process has started. This is a proxy for process
# startup time — it does not measure time-to-interactive.

source "$(dirname "$0")/../init.sh"

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
    echo "Measures iOS Simulator startup time using wall-clock timing."
    echo ""
    echo "Apps:     dotnet-new-ios, dotnet-new-maui, dotnet-new-maui-samplecontent"
    echo "Configs:  MONO_JIT, CORECLR_JIT, MONO_AOT, MONO_PAOT, R2R_COMP, R2R_COMP_PGO"
    echo ""
    echo "Options:"
    echo "  --iterations N           Number of startup iterations (default: 10)"
    echo "  --simulator-name NAME    Simulator name (e.g. 'iPhone 16')"
    echo "  --simulator-udid UDID    Simulator UDID (overrides --simulator-name)"
    echo "  --no-build               Skip building, use existing .app bundle"
    echo "  --help                   Show this help message"
    echo ""
    echo "Examples:"
    echo "  $0 dotnet-new-ios CORECLR_JIT"
    echo "  $0 dotnet-new-maui MONO_JIT --iterations 5"
    echo "  $0 dotnet-new-ios R2R_COMP --simulator-name 'iPhone 16' --no-build"
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

while [[ $# -gt 0 ]]; do
    case $1 in
        --iterations)
            if [[ -z "$2" || "$2" == --* ]]; then
                echo "Error: --iterations requires a numeric value"
                exit 1
            fi
            if ! [[ "$2" =~ ^[0-9]+$ ]] || [[ "$2" -eq 0 ]]; then
                echo "Error: --iterations requires a positive integer, got '$2'"
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
# Resolve platform configuration
# ---------------------------------------------------------------------------
resolve_platform_config "ios-simulator" || exit 1

# Validate build config (Apple platforms: no non-composite R2R)
VALID_CONFIGS="MONO_JIT CORECLR_JIT MONO_AOT MONO_PAOT R2R_COMP R2R_COMP_PGO"
if [[ ! " $VALID_CONFIGS " =~ " $BUILD_CONFIG " ]]; then
    echo "Invalid build config '$BUILD_CONFIG'. Allowed values are: $VALID_CONFIGS"
    exit 1
fi

# Validate app directory
APP_DIR="$APPS_DIR/$SAMPLE_APP"
if [ ! -d "$APP_DIR" ]; then
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
else
    echo ""
    echo "=== Skipping build (--no-build) ==="
fi

# ---------------------------------------------------------------------------
# Locate the built .app bundle
# ---------------------------------------------------------------------------
echo ""
echo "--- Locating built app ---"

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

# Record package size (use du -sk for directory bundles)
PACKAGE_SIZE_KB=$(du -sk "$APP_BUNDLE" | cut -f1)
PACKAGE_SIZE_BYTES=$((PACKAGE_SIZE_KB * 1024))
PACKAGE_SIZE_MB=$(python3 -c "print(f'{$PACKAGE_SIZE_BYTES / 1048576:.2f}')")
echo "APP size: ${PACKAGE_SIZE_MB} MB ($PACKAGE_SIZE_BYTES bytes)"

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
    xcrun simctl terminate "$SIM_UDID" "$BUNDLE_ID" 2>/dev/null || true
    xcrun simctl uninstall "$SIM_UDID" "$BUNDLE_ID" 2>/dev/null || true
}

trap cleanup EXIT

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

    # Measure launch time using python3 for sub-millisecond precision
    # (macOS date does not support %N for nanoseconds)
    START_NS=$(python3 -c "import time; print(time.time_ns())")

    xcrun simctl launch "$SIM_UDID" "$BUNDLE_ID" > /dev/null 2>&1
    LAUNCH_RESULT=$?

    END_NS=$(python3 -c "import time; print(time.time_ns())")

    if [ $LAUNCH_RESULT -ne 0 ]; then
        echo "  [$i/$ITERATIONS] FAILED — simctl launch returned $LAUNCH_RESULT"
        FAILED_COUNT=$((FAILED_COUNT + 1))
        continue
    fi

    ELAPSED_MS=$(python3 -c "print(f'{($END_NS - $START_NS) / 1_000_000:.2f}')")
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

# Use python3 for reliable statistics computation
STATS=$(python3 << PYEOF
import statistics
times = [${TIMES[0]}$(printf ', %s' "${TIMES[@]:1}")]
times.sort()
n = len(times)
avg = statistics.mean(times)
median = statistics.median(times)
min_t = min(times)
max_t = max(times)
stdev = statistics.stdev(times) if n > 1 else 0.0
print(f'{avg:.2f}')
print(f'{median:.2f}')
print(f'{min_t:.2f}')
print(f'{max_t:.2f}')
print(f'{stdev:.2f}')
print(f'{n}')
PYEOF
)

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
# Format: Generic Startup | <avg> | <min> | <max>
echo "Generic Startup | ${AVG} | ${MIN} | ${MAX}"
echo "APP size: ${PACKAGE_SIZE_MB} MB ($PACKAGE_SIZE_BYTES bytes)"

# ---------------------------------------------------------------------------
# Save detailed results to CSV
# ---------------------------------------------------------------------------
mkdir -p "$RESULTS_DIR"
RESULT_FILE="$RESULTS_DIR/${SAMPLE_APP}_${BUILD_CONFIG}_simulator.csv"

{
    echo "iteration,time_ms"
    for ((idx = 0; idx < ${#TIMES[@]}; idx++)); do
        echo "$((idx + 1)),${TIMES[$idx]}"
    done
    echo ""
    echo "# summary: avg_ms,median_ms,min_ms,max_ms,stdev_ms,count,app,config,simulator,pkg_size_mb,pkg_size_bytes"
    echo "$AVG,$MEDIAN,$MIN,$MAX,$STDEV,$COUNT,$SAMPLE_APP,$BUILD_CONFIG,$SIM_NAME_RESOLVED,$PACKAGE_SIZE_MB,$PACKAGE_SIZE_BYTES"
} > "$RESULT_FILE"

echo ""
echo "Results saved to: $RESULT_FILE"
