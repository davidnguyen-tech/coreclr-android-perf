#!/bin/bash
set -euo pipefail

# Measures Mac Catalyst app startup time using wall-clock timing.
#
# This script measures Mac Catalyst (.app bundle) startup by launching the
# app via `open` and timing the wall-clock duration of the launch command.
# Mac Catalyst apps are native macOS .app bundles built from iOS/MAUI code,
# so the launch and measurement mechanism is the same as for native macOS apps.
#
# Startup time is measured as the wall-clock duration of `open /path/to/App.app`,
# which returns after LaunchServices has started the app process. This is a
# proxy for process startup time — it does not measure time-to-interactive.
# This mirrors the iOS simulator script's approach of timing `xcrun simctl launch`.

source "$(dirname "$0")/../init.sh"

# ---------------------------------------------------------------------------
# Validate prerequisites
# ---------------------------------------------------------------------------
if [ ! -f "$LOCAL_DOTNET" ]; then
    echo "Error: $LOCAL_DOTNET does not exist. Please run ./prepare.sh first."
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
    echo "Measures Mac Catalyst app startup time using wall-clock timing."
    echo ""
    echo "Apps:     dotnet-new-maui, dotnet-new-maui-samplecontent"
    echo "Configs:  MONO_JIT, CORECLR_JIT, MONO_AOT, MONO_PAOT, R2R_COMP, R2R_COMP_PGO"
    echo ""
    echo "Options:"
    echo "  --startup-iterations N   Number of startup iterations (default: 10)"
    echo "  --no-build               Skip building, use existing .app bundle"
    echo "  --package-path PATH      Path to a pre-built .app bundle (implies --no-build)"
    echo "  --help                   Show this help message"
    echo ""
    echo "Examples:"
    echo "  $0 dotnet-new-maui CORECLR_JIT"
    echo "  $0 dotnet-new-maui MONO_JIT --startup-iterations 5"
    echo "  $0 dotnet-new-maui-samplecontent R2R_COMP --no-build"
    echo "  $0 dotnet-new-maui CORECLR_JIT --package-path /path/to/MyApp.app"
    exit 1
}

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
if [[ -z "${1:-}" || "${1:-}" == --* ]]; then
    print_usage
fi

if [[ -z "${2:-}" || "${2:-}" == --* ]]; then
    echo "Error: build-config is required as the second argument."
    print_usage
fi

SAMPLE_APP=$1
BUILD_CONFIG=$2
shift 2

ITERATIONS=10
SKIP_BUILD=false
PACKAGE_PATH=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --startup-iterations)
            if [[ -z "${2:-}" || "$2" == --* ]]; then
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
        --no-build)
            SKIP_BUILD=true
            shift
            ;;
        --package-path)
            if [[ -z "${2:-}" || "$2" == --* ]]; then
                echo "Error: --package-path requires a path to a .app bundle"
                exit 1
            fi
            PACKAGE_PATH="$2"
            shift 2
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
resolve_platform_config "maccatalyst" || exit 1

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
    echo "Run ./generate-apps.sh --platform maccatalyst first."
    exit 1
fi

# ---------------------------------------------------------------------------
# Build the app
# ---------------------------------------------------------------------------
if [ "$SKIP_BUILD" = false ]; then
    echo ""
    echo "=== Building $SAMPLE_APP ($BUILD_CONFIG) for maccatalyst ==="

    # Clean previous build artifacts
    rm -rf "${APP_DIR:?}/bin" "${APP_DIR:?}/obj"

    mkdir -p "$BUILD_DIR"

    ${LOCAL_DOTNET} build -c Release \
        -f "$PLATFORM_TFM" -r "$PLATFORM_RID" \
        -tl:off \
        -bl:"$BUILD_DIR/${SAMPLE_APP}_${BUILD_CONFIG}_maccatalyst.binlog" \
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
        echo "Ensure the app has been built with: ./build.sh --platform maccatalyst $SAMPLE_APP $BUILD_CONFIG build 1"
        exit 1
    fi

    echo "Found app bundle: $APP_BUNDLE"
fi

# Record package size (use du -sk for directory bundles)
PACKAGE_SIZE_KB=$(du -sk "$APP_BUNDLE" | cut -f1)
PACKAGE_SIZE_BYTES=$((PACKAGE_SIZE_KB * 1024))
PACKAGE_SIZE_MB=$(python3 -c "print(f'{$PACKAGE_SIZE_BYTES / 1048576:.2f}')")
echo "APP size: ${PACKAGE_SIZE_MB} MB ($PACKAGE_SIZE_BYTES bytes)"

# ---------------------------------------------------------------------------
# Extract app info from Info.plist
# ---------------------------------------------------------------------------
# Mac Catalyst .app bundles have the same structure as macOS apps:
# Contents/MacOS/<executable-name>
# The executable name is in Info.plist as CFBundleExecutable
PLIST_PATH="$APP_BUNDLE/Contents/Info.plist"
EXECUTABLE_NAME=""
BUNDLE_ID=""

if [ -f "$PLIST_PATH" ]; then
    EXECUTABLE_NAME=$(/usr/libexec/PlistBuddy -c "Print :CFBundleExecutable" "$PLIST_PATH" 2>/dev/null || true)
    BUNDLE_ID=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$PLIST_PATH" 2>/dev/null || true)
fi

if [ -z "$EXECUTABLE_NAME" ]; then
    # Fallback: use the app bundle name without .app extension
    EXECUTABLE_NAME=$(basename "$APP_BUNDLE" .app)
    echo "Warning: Could not read CFBundleExecutable from Info.plist, using fallback: $EXECUTABLE_NAME"
fi

APP_EXECUTABLE="$APP_BUNDLE/Contents/MacOS/$EXECUTABLE_NAME"
if [ ! -f "$APP_EXECUTABLE" ]; then
    echo "Error: App executable not found at $APP_EXECUTABLE"
    echo "Contents of $APP_BUNDLE/Contents/MacOS/:"
    ls -la "$APP_BUNDLE/Contents/MacOS/" 2>/dev/null || echo "  (directory not found)"
    exit 1
fi

if [ -z "$BUNDLE_ID" ]; then
    # Fallback: derive from csproj or app name
    BUNDLE_ID=$(grep -o '<ApplicationId>[^<]*' "$APP_DIR/$SAMPLE_APP.csproj" 2>/dev/null | sed 's/<ApplicationId>//')
    if [ -z "$BUNDLE_ID" ]; then
        BUNDLE_ID="com.companyname.$(echo "$SAMPLE_APP" | tr '-' '_')"
    fi
    echo "Warning: Could not read bundle ID from Info.plist, using fallback: $BUNDLE_ID"
fi

echo "Executable: $APP_EXECUTABLE"
echo "Bundle ID: $BUNDLE_ID"

# ---------------------------------------------------------------------------
# Helper: find the app's PID by its executable name
# ---------------------------------------------------------------------------
find_app_pid() {
    # Find PID of the running app by matching its executable name.
    # Returns the PID or empty string if not found.
    ps -axo pid,comm 2>/dev/null | grep -F "$EXECUTABLE_NAME" | grep -v grep | awk '{print $1}' | head -1
}

# ---------------------------------------------------------------------------
# Helper: terminate the app by PID
# ---------------------------------------------------------------------------
terminate_app() {
    local pid
    pid=$(find_app_pid)
    if [ -n "$pid" ]; then
        kill "$pid" 2>/dev/null || true
        # Wait briefly for process to exit
        for _ in $(seq 1 10); do
            if ! kill -0 "$pid" 2>/dev/null; then
                return 0
            fi
            sleep 0.1
        done
        # Force kill if still running
        kill -9 "$pid" 2>/dev/null || true
    fi
}

# ---------------------------------------------------------------------------
# Cleanup function
# ---------------------------------------------------------------------------
cleanup() {
    echo ""
    echo "--- Cleaning up ---"
    terminate_app
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
    # Clean state: terminate any running instance
    terminate_app

    # Measure launch time using python3 for sub-millisecond precision
    # (macOS date does not support %N for nanoseconds)
    START_NS=$(python3 -c "import time; print(time.time_ns())")

    open "$APP_BUNDLE" 2>/dev/null
    LAUNCH_RESULT=$?

    END_NS=$(python3 -c "import time; print(time.time_ns())")

    if [ $LAUNCH_RESULT -ne 0 ]; then
        echo "  [$i/$ITERATIONS] FAILED — open returned $LAUNCH_RESULT"
        FAILED_COUNT=$((FAILED_COUNT + 1))
        continue
    fi

    ELAPSED_MS=$(python3 -c "print(f'{($END_NS - $START_NS) / 1_000_000:.2f}')")
    TIMES+=("$ELAPSED_MS")

    echo "  [$i/$ITERATIONS] ${ELAPSED_MS} ms"

    # Terminate the app before next iteration
    terminate_app

    # Brief pause between iterations to let the system settle
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
echo "Platform:   Mac Catalyst (maccatalyst-arm64)"
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
RESULT_FILE="$RESULTS_DIR/${SAMPLE_APP}_${BUILD_CONFIG}_maccatalyst.csv"

{
    echo "iteration,time_ms"
    for ((idx = 0; idx < ${#TIMES[@]}; idx++)); do
        echo "$((idx + 1)),${TIMES[$idx]}"
    done
    echo ""
    echo "# summary: avg_ms,median_ms,min_ms,max_ms,stdev_ms,count,app,config,platform,pkg_size_mb,pkg_size_bytes"
    echo "$AVG,$MEDIAN,$MIN,$MAX,$STDEV,$COUNT,$SAMPLE_APP,$BUILD_CONFIG,maccatalyst,$PACKAGE_SIZE_MB,$PACKAGE_SIZE_BYTES"
} > "$RESULT_FILE"

echo ""
echo "Results saved to: $RESULT_FILE"
