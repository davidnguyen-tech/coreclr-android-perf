#!/bin/bash

# Collects a .nettrace file for a given (app, build-config) tuple.
# Uses dotnet-dsrouter + dotnet-trace to bridge diagnostics from an Android
# device/emulator to the host, inspired by dotnet-optimization's
# DotNet_Maui_Android_Base scenario.

source "$(dirname "$0")/../init.sh"
source "$(dirname "$0")/../tools/validate-nettrace.sh"

# ---------------------------------------------------------------------------
# Validate prerequisites
# ---------------------------------------------------------------------------
if [ ! -f "$LOCAL_DOTNET" ]; then
    echo "Error: $LOCAL_DOTNET does not exist. Please run ./prepare.sh first."
    exit 1
fi

DSROUTER_DLL="$TOOLS_DIR/.store/dotnet-dsrouter/10.0.716101/dotnet-dsrouter/10.0.716101/tools/net8.0/any/dotnet-dsrouter.dll"
DOTNET_TRACE_DLL="$TOOLS_DIR/.store/dotnet-trace/10.0.716101/dotnet-trace/10.0.716101/tools/net8.0/any/dotnet-trace.dll"

# Prefer running via 'dotnet <tool>.dll' over the native apphost wrapper.
# On macOS, the apphost binaries acquire com.apple.provenance, and amfid
# can SIGKILL them during long-running operations.  Running through the
# already-signed dotnet binary avoids this.
if [ -f "$DSROUTER_DLL" ]; then
    DSROUTER="$LOCAL_DOTNET $DSROUTER_DLL"
else
    DSROUTER="$TOOLS_DIR/dotnet-dsrouter"
fi

if [ -f "$DOTNET_TRACE_DLL" ]; then
    DOTNET_TRACE="$LOCAL_DOTNET $DOTNET_TRACE_DLL"
else
    DOTNET_TRACE="$TOOLS_DIR/dotnet-trace"
fi

if [ ! -f "$DSROUTER_DLL" ] && [ ! -f "$TOOLS_DIR/dotnet-dsrouter" ]; then
    echo "Error: dotnet-dsrouter not found. Run ./prepare.sh to install it."
    exit 1
fi

if [ ! -f "$DOTNET_TRACE_DLL" ] && [ ! -f "$TOOLS_DIR/dotnet-trace" ]; then
    echo "Error: dotnet-trace not found. Run ./prepare.sh to install it."
    exit 1
fi

if ! command -v adb &> /dev/null; then
    echo "Error: adb is required but not found in PATH."
    exit 1
fi

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------
print_usage() {
    echo "Usage: $0 <app> <build-config> [options]"
    echo ""
    echo "Collects a .nettrace startup trace for the given (app, build-config) tuple."
    echo ""
    echo "Apps:     dotnet-new-android, dotnet-new-maui, dotnet-new-maui-samplecontent"
    echo "Configs:  MONO_JIT, CORECLR_JIT, MONO_AOT, MONO_PAOT, R2R, R2R_COMP, R2R_COMP_PGO"
    echo ""
    echo "Options:"
    echo "  --platform <android|android-emulator>  Target platform (default: android)"
    echo "  --duration N             Trace duration in seconds (default: 60)"
    echo "  --force                  Accepted for backwards compatibility; now a no-op"
    echo "                           (each run writes a unique timestamped file)"
    echo "  --pgo-instrumentation    Include PGO instrumentation env vars for higher-quality traces"
    echo "  --pgo-mibc-dir <path>    Directory containing *.mibc files for R2R_COMP_PGO builds"
    echo ""
    echo "Output: traces/<app>_<config>/<app>-android-<config>-<YYYYMMDD-HHMMSS>.nettrace"
    exit 1
}

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
if [[ -z "$1" || -z "$2" ]]; then
    print_usage
fi

SAMPLE_APP=$1
BUILD_CONFIG=$2
shift 2

PLATFORM="android"
DURATION=60
PGO_INSTRUMENTATION=false
PGO_MIBC_DIR=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --platform)
            if [[ -z "$2" || "$2" == --* ]]; then
                echo "Error: --platform requires a value (android, android-emulator)"
                exit 1
            fi
            PLATFORM="$2"
            shift 2
            ;;
        --duration)
            if [[ -z "$2" || "$2" == --* ]]; then
                echo "Error: --duration requires a numeric value"
                exit 1
            fi
            if ! [[ "$2" =~ ^[0-9]+$ ]]; then
                echo "Error: --duration requires a positive integer, got '$2'"
                exit 1
            fi
            DURATION=$2
            shift 2
            ;;
        --force)
            # No-op: each run now writes a unique timestamped file, so --force is
            # no longer needed.  Accepted silently for backwards compatibility.
            shift
            ;;
        --pgo-instrumentation)
            PGO_INSTRUMENTATION=true
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
        *)
            echo "Unknown option: $1"
            print_usage
            ;;
    esac
done

# Resolve platform-specific configuration
resolve_platform_config "$PLATFORM" || exit 1

# Validate app name
APP_DIR="$APPS_DIR/$SAMPLE_APP"
if [ ! -d "$APP_DIR" ]; then
    echo "Error: App '$SAMPLE_APP' not found in $APPS_DIR"
    print_usage
fi

# Helper: remove in-tree obj/bin to avoid duplicate attribute conflicts
# from IDE-generated source files (e.g., VS Code C# Dev Kit).
clean_app_dir() {
    local dir="$1"

    if [ ! -e "$dir" ]; then
        return 0
    fi

    rm -rf "$dir" 2>/dev/null || true
    if [ ! -e "$dir" ]; then
        return 0
    fi

    local fallback_root
    fallback_root=$(mktemp -d /tmp/collect_nettrace_cleanup.XXXXXX)
    if [ $? -ne 0 ] || [ -z "$fallback_root" ]; then
        echo "Error: Failed to create fallback cleanup directory for $dir"
        return 1
    fi

    local fallback_path="$fallback_root/$(basename "$dir")"
    mv "$dir" "$fallback_path" 2>/dev/null
    if [ $? -ne 0 ] || [ -e "$dir" ]; then
        echo "Error: Failed to clean $dir (rm -rf and fallback move both failed)"
        return 1
    fi

    echo "Moved stubborn $(basename "$dir") directory to $fallback_path"
    return 0
}

clean_app_dirs() {
    clean_app_dir "$APP_DIR/obj" || return 1
    clean_app_dir "$APP_DIR/bin" || return 1
}

# Validate build config
VALID_CONFIGS="MONO_JIT CORECLR_JIT MONO_AOT MONO_PAOT R2R R2R_COMP R2R_COMP_PGO"
if [[ ! " $VALID_CONFIGS " =~ " $BUILD_CONFIG " ]]; then
    echo "Invalid build config '$BUILD_CONFIG'. Allowed values are: $VALID_CONFIGS"
    exit 1
fi

# ---------------------------------------------------------------------------
# Set up trace output path (timestamped so repeated runs never overwrite)
# ---------------------------------------------------------------------------
TRACE_DIR="$TRACES_DIR/${SAMPLE_APP}_${BUILD_CONFIG}"
TRACE_TIMESTAMP=$(date +%Y%m%d-%H%M%S)
TRACE_FILE="$TRACE_DIR/${SAMPLE_APP}-android-${BUILD_CONFIG}-${TRACE_TIMESTAMP}.nettrace"

mkdir -p "$TRACE_DIR"

# ---------------------------------------------------------------------------
# Build MSBuild arguments
# ---------------------------------------------------------------------------
if [ "$PLATFORM" = "android" ]; then
    DIAG_ADDRESS="127.0.0.1"
else
    DIAG_ADDRESS="10.0.2.2"
fi

# EventSourceSupport=false and MetricsSupport=false must match normal (non-diagnostic) build settings.
# Without these, diagnostic properties trigger AndroidEnableProfiler=true which prevents
# EventSourceSupport from being trimmed, causing PGO profile mismatch and R2R_COMP_PGO crash.
MSBUILD_ARGS="-p:_BuildConfig=$BUILD_CONFIG -p:DiagnosticAddress=$DIAG_ADDRESS -p:DiagnosticPort=9000 -p:DiagnosticSuspend=true -p:DiagnosticListenMode=connect -p:EventSourceSupport=false -p:MetricsSupport=false"

if [ "$PGO_INSTRUMENTATION" = true ]; then
    MSBUILD_ARGS="$MSBUILD_ARGS -p:CollectNetTrace=true"
fi

if [ -n "$PGO_MIBC_DIR" ]; then
    if [ ! -d "$PGO_MIBC_DIR" ]; then
        echo "Error: PGO MIBC directory does not exist: $PGO_MIBC_DIR"
        exit 1
    fi
    MSBUILD_ARGS="$MSBUILD_ARGS -p:_CUSTOM_MIBC_DIR=$PGO_MIBC_DIR"
fi

# Determine package name
PACKAGE_NAME=$(grep -o '<ApplicationId>[^<]*' "$APP_DIR/$SAMPLE_APP.csproj" | sed 's/<ApplicationId>//')
if [ -z "$PACKAGE_NAME" ]; then
    PACKAGE_NAME="com.companyname.$(echo "$SAMPLE_APP" | tr '-' '_')"
fi

# ---------------------------------------------------------------------------
# IPC / dsrouter names
# ---------------------------------------------------------------------------
IPC_NAME="/tmp/dsrouter-$$"

# Cleanup function
DSROUTER_PID=""
cleanup() {
    echo ""
    echo "=== Cleaning up ==="

    # Stop dsrouter
    if [ -n "$DSROUTER_PID" ] && kill -0 "$DSROUTER_PID" 2>/dev/null; then
        echo "Stopping dotnet-dsrouter (PID $DSROUTER_PID)..."
        kill "$DSROUTER_PID" 2>/dev/null
        wait "$DSROUTER_PID" 2>/dev/null
    fi

    # Uninstall app from device
    echo "Uninstalling $PACKAGE_NAME from device..."
    adb shell pm uninstall "$PACKAGE_NAME" 2>/dev/null || true

    # Remove ADB forwarding rules
    adb forward --remove-all 2>/dev/null || true
    adb reverse --remove-all 2>/dev/null || true

    # Remove IPC socket file if it exists
    rm -f "$IPC_NAME" 2>/dev/null

}

trap cleanup EXIT

# ---------------------------------------------------------------------------
# Step 1: Start dsrouter
# ---------------------------------------------------------------------------
echo "=== Collecting .nettrace for $SAMPLE_APP ($BUILD_CONFIG) ==="
echo "Trace duration: ${DURATION}s"
if [ "$PGO_INSTRUMENTATION" = true ]; then
    echo "PGO instrumentation: enabled"
fi
echo ""

# ---------------------------------------------------------------------------
# Pre-flight cleanup: clear stale ADB forwarding and sockets
# ---------------------------------------------------------------------------
echo "--- Pre-flight cleanup ---"
adb forward --remove-all 2>/dev/null || true
adb reverse --remove-all 2>/dev/null || true
rm -f /tmp/dsrouter-* 2>/dev/null || true

if lsof -i :9000 >/dev/null 2>&1; then
    echo "Warning: Port 9000 is in use. Waiting 5 seconds..."
    sleep 5
    if lsof -i :9000 >/dev/null 2>&1; then
        echo "Error: Port 9000 is still in use. Kill the blocking process and retry."
        lsof -i :9000
        exit 1
    fi
fi

# For physical devices, set up adb reverse so device:9000 reaches host:9000
if [ "$PLATFORM" = "android" ]; then
    echo "Setting up adb reverse tcp:9000 tcp:9000 for physical device..."
    adb reverse tcp:9000 tcp:9000
    if [ $? -ne 0 ]; then
        echo "Error: Failed to set up adb reverse port forwarding."
        exit 1
    fi
    echo "ADB reverse: $(adb reverse --list 2>/dev/null)"
fi

echo "--- Building app first (dsrouter will start after build) ---"
echo "Cleaning local app obj/bin directories..."
clean_app_dirs || exit 1

# ---------------------------------------------------------------------------
# Build phase: build the app without deploying (dsrouter not needed yet).
# This avoids amfid killing dsrouter during long R2R builds (~60s+).
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Step 2: Clear logcat buffer
# ---------------------------------------------------------------------------
echo ""
echo "--- Clearing logcat ---"
adb logcat -c

# ---------------------------------------------------------------------------
# Step 3: Build and deploy app with diagnostics
# ---------------------------------------------------------------------------
echo ""
echo "--- Building and deploying app with diagnostics enabled ---"

# Retry the build on failure — the Android SDK tooling can hit transient
# file-system race conditions (e.g., XAJVC7009, XARDF7024) when IDE background
# builds (e.g., VS Code C# Dev Kit) touch the obj/ directory concurrently.
# Start from a clean obj/bin state to avoid stale/generated-file conflicts.

BUILD_ATTEMPTS=0
BUILD_MAX=3
BUILD_OK=false
while [ "$BUILD_ATTEMPTS" -lt "$BUILD_MAX" ]; do
    BUILD_ATTEMPTS=$((BUILD_ATTEMPTS + 1))

    ${LOCAL_DOTNET} build -c Release \
        -f "$PLATFORM_TFM" -r "$PLATFORM_RID" \
        -tl:off \
        /nodereuse:false \
        -p:UseSharedCompilation=false \
        -bl:"$TRACE_DIR/${SAMPLE_APP}_${BUILD_CONFIG}_nettrace.binlog" \
        "$APP_DIR/$SAMPLE_APP.csproj" \
        $MSBUILD_ARGS
    if [ $? -eq 0 ]; then
        BUILD_OK=true
        break
    fi
    if [ "$BUILD_ATTEMPTS" -lt "$BUILD_MAX" ]; then
        echo "Build attempt $BUILD_ATTEMPTS failed, retrying..."
        sleep 2
    fi
done

if [ "$BUILD_OK" = false ]; then
    echo "Error: Build failed after $BUILD_MAX attempts."
    exit 1
fi

# ---------------------------------------------------------------------------
# Step 3b: Start dsrouter and deploy the app
# ---------------------------------------------------------------------------
# dsrouter is started AFTER the build to avoid amfid killing it during long
# R2R builds. The app needs dsrouter running when it starts to connect for
# diagnostic tracing.
echo ""
echo "--- Starting dotnet-dsrouter ---"
DSROUTER_ARGS="server-server -ipcs $IPC_NAME -tcps 127.0.0.1:9000"
if [ "$PLATFORM" = "android-emulator" ]; then
    DSROUTER_ARGS="$DSROUTER_ARGS --forward-port Android"
fi
$DSROUTER $DSROUTER_ARGS < /dev/null &
DSROUTER_PID=$!
echo "dotnet-dsrouter started with PID: $DSROUTER_PID"
sleep 3

if ! kill -0 "$DSROUTER_PID" 2>/dev/null; then
    echo "Error: dotnet-dsrouter exited unexpectedly."
    exit 1
fi

echo "--- Installing and running app ---"
${LOCAL_DOTNET} build -t:Run -c Release \
    -f "$PLATFORM_TFM" -r "$PLATFORM_RID" \
    -tl:off \
    /nodereuse:false \
    -p:UseSharedCompilation=false \
    "$APP_DIR/$SAMPLE_APP.csproj" \
    $MSBUILD_ARGS
if [ $? -ne 0 ]; then
    echo "Error: Failed to deploy and run app."
    exit 1
fi

# Give the app time to connect to dsrouter and suspend
echo "Waiting for app to connect to dsrouter and suspend..."
sleep 5

# ---------------------------------------------------------------------------
# Step 4: Collect trace with dotnet-trace
# ---------------------------------------------------------------------------
echo ""
echo "--- Collecting .nettrace (${DURATION}s) ---"

# Event providers matching dotnet-optimization's configuration:
# Microsoft-Windows-DotNETRuntime with JIT, Loader, GC, Exception, ThreadPool, Interop events
PROVIDERS="Microsoft-Windows-DotNETRuntime:0x5F000080018:5,Microsoft-Windows-DotNETRuntime:0x4c14fccbd:5,Microsoft-Windows-DotNETRuntimePrivate:0x4002000b:5"

$DOTNET_TRACE collect \
    --output "$TRACE_FILE" \
    --diagnostic-port "$IPC_NAME,connect" \
    --duration "$(printf '%02d:%02d:%02d' $((DURATION / 3600)) $(((DURATION % 3600) / 60)) $((DURATION % 60)))" \
    --providers "$PROVIDERS"

TRACE_RESULT=$?

# ---------------------------------------------------------------------------
# Step 5: Validate trace file
# ---------------------------------------------------------------------------
echo ""
if [ $TRACE_RESULT -ne 0 ]; then
    echo "Warning: dotnet-trace exited with code $TRACE_RESULT"
fi

if [ -f "$TRACE_FILE" ]; then
    TRACE_SIZE=$(wc -c < "$TRACE_FILE" | tr -d ' ')
    echo "Trace file: $TRACE_FILE ($TRACE_SIZE bytes)"

    if ! validate_nettrace "$TRACE_FILE"; then
        echo "ERROR: Trace file failed validation."
        echo "The app likely did not connect to dsrouter. Verify:"
        echo "  1. A device is connected:  adb devices"
        echo "  2. Port 9000 is not blocked:  lsof -i :9000"
        echo "  3. adb reverse is active:  adb reverse --list"
        exit 1
    fi
else
    echo "ERROR: No trace file was produced."
    exit 1
fi

# ---------------------------------------------------------------------------
# Step 6: Dump logcat for diagnostics
# ---------------------------------------------------------------------------
LOGCAT_FILE="$TRACE_DIR/logcat.txt"
echo "Saving logcat to $LOGCAT_FILE..."
adb logcat -d > "$LOGCAT_FILE" 2>/dev/null || true

echo ""
echo "=== .nettrace collection complete ==="
echo "Trace: $TRACE_FILE"
echo "Logcat: $LOGCAT_FILE"
