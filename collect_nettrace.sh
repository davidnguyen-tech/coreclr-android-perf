#!/bin/bash

# Collects a .nettrace file for a given (app, build-config) tuple.
# Uses dotnet-dsrouter + dotnet-trace to bridge diagnostics from an Android
# device/emulator to the host, inspired by dotnet-optimization's
# DotNet_Maui_Android_Base scenario.

source "$(dirname "$0")/init.sh"

# ---------------------------------------------------------------------------
# Validate prerequisites
# ---------------------------------------------------------------------------
if [ ! -f "$LOCAL_DOTNET" ]; then
    echo "Error: $LOCAL_DOTNET does not exist. Please run ./prepare.sh first."
    exit 1
fi

DSROUTER="$TOOLS_DIR/dotnet-dsrouter"
DOTNET_TRACE="$TOOLS_DIR/dotnet-trace"

if [ ! -f "$DSROUTER" ]; then
    echo "Error: dotnet-dsrouter not found at $DSROUTER. Run ./prepare.sh to install it."
    exit 1
fi

if [ ! -f "$DOTNET_TRACE" ]; then
    echo "Error: dotnet-trace not found at $DOTNET_TRACE. Run ./prepare.sh to install it."
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
    echo "Configs:  MONO_JIT, CORECLR_JIT, AOT, PAOT, R2R, R2R_COMP, R2R_COMP_PGO"
    echo ""
    echo "Options:"
    echo "  --duration N             Trace duration in seconds (default: 60)"
    echo "  --force                  Re-collect even if trace already exists"
    echo "  --pgo-instrumentation    Include PGO instrumentation env vars for higher-quality traces"
    echo ""
    echo "Output: traces/<app>_<config>/android-startup.nettrace"
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

DURATION=60
FORCE=false
PGO_INSTRUMENTATION=false

while [[ $# -gt 0 ]]; do
    case $1 in
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
            FORCE=true
            shift
            ;;
        --pgo-instrumentation)
            PGO_INSTRUMENTATION=true
            shift
            ;;
        *)
            echo "Unknown option: $1"
            print_usage
            ;;
    esac
done

# Validate app name
if [[ "$SAMPLE_APP" != "dotnet-new-android" && "$SAMPLE_APP" != "dotnet-new-maui" && "$SAMPLE_APP" != "dotnet-new-maui-samplecontent" ]]; then
    echo "Invalid app: $SAMPLE_APP"
    print_usage
fi

# Validate build config
VALID_CONFIGS="MONO_JIT CORECLR_JIT AOT PAOT R2R R2R_COMP R2R_COMP_PGO"
if [[ ! " $VALID_CONFIGS " =~ " $BUILD_CONFIG " ]]; then
    echo "Invalid build config '$BUILD_CONFIG'. Allowed values are: $VALID_CONFIGS"
    exit 1
fi

APP_DIR="$APPS_DIR/$SAMPLE_APP"
if [ ! -d "$APP_DIR" ]; then
    echo "Error: App directory $APP_DIR does not exist. Run ./prepare.sh first."
    exit 1
fi

# ---------------------------------------------------------------------------
# Check if trace already exists
# ---------------------------------------------------------------------------
TRACE_DIR="$TRACES_DIR/${SAMPLE_APP}_${BUILD_CONFIG}"
TRACE_FILE="$TRACE_DIR/android-startup.nettrace"

if [ -f "$TRACE_FILE" ] && [ "$FORCE" = false ]; then
    TRACE_SIZE=$(wc -c < "$TRACE_FILE" | tr -d ' ')
    echo "Trace already exists: $TRACE_FILE ($TRACE_SIZE bytes)"
    echo "Use --force to re-collect."
    exit 0
fi

mkdir -p "$TRACE_DIR"

# ---------------------------------------------------------------------------
# Build MSBuild arguments
# ---------------------------------------------------------------------------
MSBUILD_ARGS="-p:AndroidEnableProfiler=true -p:_BuildConfig=$BUILD_CONFIG"

if [ "$PGO_INSTRUMENTATION" = true ]; then
    MSBUILD_ARGS="$MSBUILD_ARGS -p:CollectNetTrace=true"
fi

# Determine package name
PACKAGE_NAME=$(grep -o '<ApplicationId>[^<]*' "$APP_DIR/$SAMPLE_APP.csproj" | sed 's/<ApplicationId>//')
if [ -z "$PACKAGE_NAME" ]; then
    PACKAGE_NAME="com.companyname.$(echo "$SAMPLE_APP" | tr '-' '_')"
fi

# ---------------------------------------------------------------------------
# IPC / dsrouter names
# ---------------------------------------------------------------------------
IPC_NAME="$TRACE_DIR/dotnet-dsrouter-android"

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

echo "--- Starting dotnet-dsrouter ---"
"$DSROUTER" server-server \
    -ipcs "$IPC_NAME" \
    -tcps 127.0.0.1:9000 \
    --forward-port Android &
DSROUTER_PID=$!
echo "dotnet-dsrouter started with PID: $DSROUTER_PID"

# Give dsrouter time to set up the ADB port forwarding
sleep 3

if ! kill -0 "$DSROUTER_PID" 2>/dev/null; then
    echo "Error: dotnet-dsrouter exited unexpectedly."
    exit 1
fi

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
${LOCAL_DOTNET} build -t:Run -c Release \
    -f net11.0-android -r android-arm64 \
    -tl:off \
    -bl:"$TRACE_DIR/${SAMPLE_APP}_${BUILD_CONFIG}_nettrace.binlog" \
    "$APP_DIR/$SAMPLE_APP.csproj" \
    $MSBUILD_ARGS

if [ $? -ne 0 ]; then
    echo "Error: Build and deploy failed."
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
PROVIDERS="Microsoft-Windows-DotNETRuntime:0x1F000080018:5,Microsoft-Windows-DotNETRuntime:0x4c14fccbd:5,Microsoft-Windows-DotNETRuntimePrivate:0x4002000b:5"

"$DOTNET_TRACE" collect \
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

    if [ "$TRACE_SIZE" -lt 1000 ]; then
        echo "WARNING: Trace file is suspiciously small ($TRACE_SIZE bytes)."
        echo "The app may not have connected to dsrouter properly."
        echo "Check that a device is connected (adb devices) and that port 9000 is not in use."
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
