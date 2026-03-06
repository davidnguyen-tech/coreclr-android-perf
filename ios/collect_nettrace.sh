#!/bin/bash

# Collects a .nettrace file for a given (app, build-config) tuple.
#
# Supports two modes via --platform:
#   ios            — Physical device. Uses dotnet-dsrouter + dotnet-trace to
#                    bridge diagnostics from the device via USB, following the
#                    same pattern as android/collect_nettrace.sh.
#   ios-simulator  — Simulator. The simulator runs locally so no dsrouter is
#                    needed. Uses a direct Unix-domain diagnostic socket,
#                    following the same pattern as osx/collect_nettrace.sh.
#
# IMPORTANT RISKS (physical device only):
#   1. iOS watchdog may kill apps that suspend too long waiting for trace
#      connection. The trace session must connect promptly after app launch.
#   2. --forward-port iOS exact syntax needs runtime verification. The Android
#      equivalent uses --forward-port Android (confirmed working).
#   3. MtouchExtraArgs --setenv compatibility needs testing with .NET 11 iOS.
#      This is documented for Xamarin.iOS but may differ for modern .NET.
#   4. Development provisioning profiles are required — distribution profiles
#      may disable diagnostic ports.

source "$(dirname "$0")/../init.sh"

# ---------------------------------------------------------------------------
# Validate prerequisites
# ---------------------------------------------------------------------------
if [ ! -f "$LOCAL_DOTNET" ]; then
    echo "Error: $LOCAL_DOTNET does not exist. Please run ./prepare.sh first."
    exit 1
fi

DOTNET_TRACE="$TOOLS_DIR/dotnet-trace"

if [ ! -f "$DOTNET_TRACE" ]; then
    echo "Error: dotnet-trace not found at $DOTNET_TRACE. Run ./prepare.sh to install it."
    exit 1
fi

if ! command -v xcrun &> /dev/null; then
    echo "Error: xcrun is required but not found. Please install Xcode."
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
    echo "Apps:     dotnet-new-ios, dotnet-new-maui, dotnet-new-maui-samplecontent"
    echo "Configs:  MONO_JIT, CORECLR_JIT, MONO_AOT, MONO_PAOT, R2R_COMP, R2R_COMP_PGO"
    echo ""
    echo "Options:"
    echo "  --platform PLATFORM      Target platform: ios (default) or ios-simulator"
    echo "  --duration N             Trace duration in seconds (default: 60)"
    echo "  --force                  Re-collect even if trace already exists"
    echo "  --device-id UDID         Target device UDID (physical) or simulator UDID"
    echo "  --simulator-name NAME    Simulator name, e.g. 'iPhone 16' (simulator only)"
    echo ""
    echo "Output: traces/<app>_<config>/ios-startup.nettrace"
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
DEVICE_ID=""
PLATFORM="ios"
SIM_NAME=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --platform)
            if [[ -z "$2" || "$2" == --* ]]; then
                echo "Error: --platform requires a value (ios or ios-simulator)"
                exit 1
            fi
            PLATFORM=$2
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
            FORCE=true
            shift
            ;;
        --device-id)
            if [[ -z "$2" || "$2" == --* ]]; then
                echo "Error: --device-id requires a UDID value"
                exit 1
            fi
            DEVICE_ID=$2
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
        *)
            echo "Unknown option: $1"
            print_usage
            ;;
    esac
done

# ---------------------------------------------------------------------------
# Resolve platform configuration
# ---------------------------------------------------------------------------
if [[ "$PLATFORM" != "ios" && "$PLATFORM" != "ios-simulator" ]]; then
    echo "Error: --platform must be 'ios' or 'ios-simulator', got '$PLATFORM'"
    exit 1
fi

resolve_platform_config "$PLATFORM" || exit 1

# Validate app name
APP_DIR="$APPS_DIR/$SAMPLE_APP"
if [ ! -d "$APP_DIR" ]; then
    echo "Error: App '$SAMPLE_APP' not found in $APPS_DIR"
    print_usage
fi

# Validate build config (matches ios/build-configs.props — 6 configs, no non-composite R2R)
VALID_CONFIGS="MONO_JIT CORECLR_JIT MONO_AOT MONO_PAOT R2R_COMP R2R_COMP_PGO"
if [[ ! " $VALID_CONFIGS " =~ " $BUILD_CONFIG " ]]; then
    echo "Invalid build config '$BUILD_CONFIG'. Allowed values are: $VALID_CONFIGS"
    exit 1
fi

# ---------------------------------------------------------------------------
# Validate physical-device-only prerequisites
# ---------------------------------------------------------------------------
if [ "$PLATFORM" = "ios" ]; then
    DSROUTER="$TOOLS_DIR/dotnet-dsrouter"
    XHARNESS="$TOOLS_DIR/xharness"

    if [ ! -f "$DSROUTER" ]; then
        echo "Error: dotnet-dsrouter not found at $DSROUTER. Run ./prepare.sh to install it."
        exit 1
    fi

    if [ ! -f "$XHARNESS" ]; then
        echo "Error: xharness not found at $XHARNESS. Run ./prepare.sh to install it."
        exit 1
    fi
fi

if ! command -v python3 &> /dev/null; then
    echo "Error: python3 is required but not found."
    exit 1
fi

# ---------------------------------------------------------------------------
# Detect device / simulator
# ---------------------------------------------------------------------------
if [ "$PLATFORM" = "ios" ]; then
    # --- Physical device detection ---
    if [ -z "$DEVICE_ID" ]; then
        DEVICE_ID=$(xcrun devicectl list devices --json-output /dev/stdout 2>/dev/null \
            | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    devices = [d for d in data.get('result', {}).get('devices', [])
               if d.get('connectionProperties', {}).get('transportType') == 'wired']
    if len(devices) == 1:
        print(devices[0]['identifier'])
    elif len(devices) > 1:
        print('MULTIPLE', file=sys.stderr)
    else:
        print('NONE', file=sys.stderr)
except Exception as e:
    print(f'ERROR: {e}', file=sys.stderr)
" 2>&1)

        if [[ "$DEVICE_ID" == *"MULTIPLE"* ]]; then
            echo "Error: Multiple iOS devices detected. Use --device-id to specify which one."
            xcrun devicectl list devices 2>/dev/null
            exit 1
        fi

        if [ -z "$DEVICE_ID" ] || [[ "$DEVICE_ID" == *"NONE"* ]] || [[ "$DEVICE_ID" == *"ERROR"* ]]; then
            echo "Error: No iOS device detected. Connect a device via USB and ensure it is trusted."
            exit 1
        fi
    fi

    echo "Using iOS device: $DEVICE_ID"
else
    # --- Simulator detection / boot ---
    echo "--- Detecting simulator ---"

    if [ -n "$DEVICE_ID" ]; then
        echo "Using provided simulator UDID: $DEVICE_ID"
        SIM_UDID="$DEVICE_ID"
    elif [ -n "$SIM_NAME" ]; then
        echo "Looking for simulator named '$SIM_NAME'..."
        SIM_UDID=$(xcrun simctl list devices available -j 2>/dev/null | python3 -c "
import sys, json
name = sys.argv[1]
data = json.load(sys.stdin)
for runtime, device_list in data.get('devices', {}).items():
    for d in device_list:
        if d.get('name') == name and d.get('isAvailable', False):
            print(d['udid'])
            sys.exit(0)
sys.exit(1)
" "$SIM_NAME" 2>/dev/null)
        if [ -z "$SIM_UDID" ]; then
            echo "Error: No available simulator found with name '$SIM_NAME'."
            echo "Available simulators:"
            xcrun simctl list devices available | grep -i iphone | head -10
            exit 1
        fi
        echo "Found simulator: $SIM_UDID"
    else
        echo "Auto-detecting booted simulator..."
        SIM_UDID=$(xcrun simctl list devices booted -j 2>/dev/null | python3 -c "
import sys, json
data = json.load(sys.stdin)
for runtime, device_list in data.get('devices', {}).items():
    for d in device_list:
        if d.get('state') == 'Booted':
            print(d['udid'])
            sys.exit(0)
" 2>/dev/null)
        if [ -z "$SIM_UDID" ]; then
            echo "No booted simulator found. Looking for an available iPhone simulator..."
            SIM_UDID=$(xcrun simctl list devices available -j 2>/dev/null | python3 -c "
import sys, json
data = json.load(sys.stdin)
for runtime in sorted(data.get('devices', {}).keys(), reverse=True):
    for d in data['devices'][runtime]:
        if d.get('isAvailable', False) and 'iPhone' in d.get('name', ''):
            print(d['udid'])
            sys.exit(0)
sys.exit(1)
" 2>/dev/null)
            if [ -z "$SIM_UDID" ]; then
                echo "Error: No available iPhone simulator found."
                echo "Create one with: xcrun simctl create 'iPhone 16' 'com.apple.CoreSimulator.SimDeviceType.iPhone-16'"
                exit 1
            fi
        fi
    fi

    # Read simulator name and state
    SIM_INFO=$(xcrun simctl list devices -j 2>/dev/null | python3 -c "
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
" "$SIM_UDID" 2>/dev/null)
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
        xcrun simctl bootstatus "$SIM_UDID" -b 2>/dev/null || sleep 10
    fi

    echo "Simulator: $SIM_NAME_RESOLVED ($SIM_UDID)"
fi

# ---------------------------------------------------------------------------
# Check if trace already exists
# ---------------------------------------------------------------------------
TRACE_DIR="$TRACES_DIR/${SAMPLE_APP}_${BUILD_CONFIG}"
TRACE_FILE="$TRACE_DIR/ios-startup.nettrace"

if [ -f "$TRACE_FILE" ] && [ "$FORCE" = false ]; then
    TRACE_SIZE=$(wc -c < "$TRACE_FILE" | tr -d ' ')
    echo "Trace already exists: $TRACE_FILE ($TRACE_SIZE bytes)"
    echo "Use --force to re-collect."
    exit 0
fi

mkdir -p "$TRACE_DIR"

# ---------------------------------------------------------------------------
# Determine bundle identifier
# ---------------------------------------------------------------------------
BUNDLE_ID=$(grep -o '<ApplicationId>[^<]*' "$APP_DIR/$SAMPLE_APP.csproj" | sed 's/<ApplicationId>//')
if [ -z "$BUNDLE_ID" ]; then
    BUNDLE_ID="com.companyname.$(echo "$SAMPLE_APP" | tr '-' '_')"
fi

echo "Bundle ID: $BUNDLE_ID"

# ---------------------------------------------------------------------------
# Diagnostic port / IPC configuration
# ---------------------------------------------------------------------------
if [ "$PLATFORM" = "ios" ]; then
    IPC_NAME="/tmp/dsrouter-$$"
else
    DIAG_SOCKET="/tmp/diag-$$.sock"
fi

# ---------------------------------------------------------------------------
# Cleanup function
# ---------------------------------------------------------------------------
DSROUTER_PID=""
APP_PID=""
cleanup() {
    echo ""
    echo "=== Cleaning up ==="

    if [ "$PLATFORM" = "ios" ]; then
        # Stop dsrouter
        if [ -n "$DSROUTER_PID" ] && kill -0 "$DSROUTER_PID" 2>/dev/null; then
            echo "Stopping dotnet-dsrouter (PID $DSROUTER_PID)..."
            kill "$DSROUTER_PID" 2>/dev/null
            wait "$DSROUTER_PID" 2>/dev/null
        fi

        # Uninstall app from device
        echo "Uninstalling $BUNDLE_ID from device..."
        "$XHARNESS" apple uninstall \
            --app "$BUNDLE_ID" \
            --target ios-device \
            --device "$DEVICE_ID" \
            --output-directory "$TRACE_DIR" 2>/dev/null || true

        # Remove IPC socket file if it exists
        rm -f "$IPC_NAME" 2>/dev/null
    else
        # Simulator cleanup
        # Kill the app process if still running (APP_PID is the actual app
        # process spawned by simctl, not a child of this shell)
        if [ -n "$APP_PID" ] && kill -0 "$APP_PID" 2>/dev/null; then
            echo "Stopping app process (PID $APP_PID)..."
            kill "$APP_PID" 2>/dev/null || true
        fi

        # Terminate and uninstall from simulator
        echo "Terminating and uninstalling $BUNDLE_ID from simulator..."
        xcrun simctl terminate "$SIM_UDID" "$BUNDLE_ID" 2>/dev/null || true
        xcrun simctl uninstall "$SIM_UDID" "$BUNDLE_ID" 2>/dev/null || true

        # Remove diagnostic socket file if it exists
        if [ -e "$DIAG_SOCKET" ]; then
            echo "Removing diagnostic socket: $DIAG_SOCKET"
            rm -f "$DIAG_SOCKET" 2>/dev/null
        fi
    fi
}

trap cleanup EXIT

# ---------------------------------------------------------------------------
# Step 1: Start dsrouter (physical device only)
# ---------------------------------------------------------------------------
echo "=== Collecting .nettrace for $SAMPLE_APP ($BUILD_CONFIG) [platform: $PLATFORM] ==="
echo "Trace duration: ${DURATION}s"

if [ "$PLATFORM" = "ios" ]; then
    echo ""
    echo "--- Starting dotnet-dsrouter ---"

    # NOTE: --forward-port iOS tells dsrouter to use Apple device transport (usbmuxd)
    # instead of ADB. This exact flag value needs runtime verification — see risk #2
    # in the header comments.
    "$DSROUTER" server-server \
        -ipcs "$IPC_NAME" \
        -tcps 127.0.0.1:9000 \
        --forward-port iOS &
    DSROUTER_PID=$!
    echo "dotnet-dsrouter started with PID: $DSROUTER_PID"

    # Give dsrouter time to set up the device port forwarding
    sleep 3

    if ! kill -0 "$DSROUTER_PID" 2>/dev/null; then
        echo "Error: dotnet-dsrouter exited unexpectedly."
        echo "Verify that --forward-port iOS is the correct syntax by running:"
        echo "  $DSROUTER server-server --help"
        exit 1
    fi
else
    echo "Diagnostic socket: $DIAG_SOCKET"
fi
echo ""

# ---------------------------------------------------------------------------
# Step 2: Build app with diagnostics enabled
# ---------------------------------------------------------------------------
echo "--- Building app with diagnostics enabled ---"

if [ "$PLATFORM" = "ios" ]; then
    # NOTE: MtouchExtraArgs --setenv injects the diagnostic port environment variable
    # at build time, baking it into the app. This matches how Android uses
    # <AndroidEnvironment> items. See risk #3 in the header comments about
    # MtouchExtraArgs compatibility with .NET 11 iOS.
    DIAG_MTOUCH_ARGS="--setenv=DOTNET_DiagnosticPorts=127.0.0.1:9000,suspend,connect"

    ${LOCAL_DOTNET} build -c Release \
        -f "$PLATFORM_TFM" -r "$PLATFORM_RID" \
        -tl:off \
        -bl:"$TRACE_DIR/${SAMPLE_APP}_${BUILD_CONFIG}_nettrace.binlog" \
        "$APP_DIR/$SAMPLE_APP.csproj" \
        -p:_BuildConfig="$BUILD_CONFIG" \
        -p:MtouchExtraArgs="$DIAG_MTOUCH_ARGS"
else
    # Simulator: no MtouchExtraArgs needed — env var is passed at launch time
    # via SIMCTL_CHILD_ prefix
    ${LOCAL_DOTNET} build -c Release \
        -f "$PLATFORM_TFM" -r "$PLATFORM_RID" \
        -tl:off \
        -bl:"$TRACE_DIR/${SAMPLE_APP}_${BUILD_CONFIG}_nettrace.binlog" \
        "$APP_DIR/$SAMPLE_APP.csproj" \
        -p:_BuildConfig="$BUILD_CONFIG"
fi

if [ $? -ne 0 ]; then
    echo "Error: Build failed."
    exit 1
fi

# ---------------------------------------------------------------------------
# Step 3: Locate the built .app bundle
# ---------------------------------------------------------------------------
echo ""
echo "--- Locating built app ---"

# Search in bin/ first, excluding obj/
APP_BUNDLE=$(find "$APP_DIR/bin" -type d -name "*.app" -not -path "*/obj/*" 2>/dev/null | head -1)

if [ -z "$APP_BUNDLE" ]; then
    # Fall back to broader search
    APP_BUNDLE=$(find "$APP_DIR" -type d -name "*.app" -not -path "*/obj/*" 2>/dev/null | head -1)
fi

if [ -z "$APP_BUNDLE" ]; then
    echo "Error: Could not find .app bundle in $APP_DIR"
    exit 1
fi

echo "Found app bundle: $APP_BUNDLE"

# ---------------------------------------------------------------------------
# Step 4: Install and launch the app
# ---------------------------------------------------------------------------
if [ "$PLATFORM" = "ios" ]; then
    # --- Physical device: install via xharness, launch via devicectl ---
    echo ""
    echo "--- Installing app on device ---"

    "$XHARNESS" apple install \
        --app "$APP_BUNDLE" \
        --target ios-device \
        --device "$DEVICE_ID" \
        --output-directory "$TRACE_DIR"

    if [ $? -ne 0 ]; then
        echo "Error: Failed to install app on device."
        exit 1
    fi

    echo ""
    echo "--- Launching app on device ---"

    # Launch the app using xcrun devicectl. The app will start, connect to dsrouter
    # on port 9000, and suspend waiting for a trace session.
    # NOTE: The app will be in a suspended state due to the DOTNET_DiagnosticPorts
    # env var. iOS watchdog may kill it if the trace session doesn't connect
    # promptly — see risk #1 in the header comments.
    xcrun devicectl device process launch \
        --device "$DEVICE_ID" \
        "$BUNDLE_ID"

    if [ $? -ne 0 ]; then
        echo "Error: Failed to launch app on device."
        echo "Verify the device is unlocked and the app is signed with a development profile."
        exit 1
    fi

    # Give the app time to connect to dsrouter and suspend
    echo "Waiting for app to connect to dsrouter and suspend..."
    sleep 5
else
    # --- Simulator: install via simctl, launch with diagnostic socket ---
    echo ""
    echo "--- Installing app on simulator ---"

    xcrun simctl install "$SIM_UDID" "$APP_BUNDLE"
    if [ $? -ne 0 ]; then
        echo "Error: Failed to install app on simulator."
        exit 1
    fi

    echo ""
    echo "--- Launching app on simulator with diagnostic port (suspended) ---"

    # SIMCTL_CHILD_ prefix passes environment variables to the launched process.
    # The app suspends at startup waiting for dotnet-trace to connect.
    # Note: `xcrun simctl launch` prints the spawned app PID to stdout (e.g.
    # "com.example.app: 12345") and then exits immediately — it does NOT stay
    # alive for the lifetime of the app.  We capture the real app PID from
    # that output so we can terminate it later.
    LAUNCH_OUTPUT=$(SIMCTL_CHILD_DOTNET_DiagnosticPorts="$DIAG_SOCKET,suspend" \
        xcrun simctl launch "$SIM_UDID" "$BUNDLE_ID" 2>&1)
    LAUNCH_RESULT=$?

    if [ $LAUNCH_RESULT -ne 0 ]; then
        echo "Error: simctl launch failed (exit code $LAUNCH_RESULT)."
        echo "$LAUNCH_OUTPUT"
        exit 1
    fi

    APP_PID=$(echo "$LAUNCH_OUTPUT" | grep -o '[0-9]*$')
    echo "App launched via simctl (app PID $APP_PID, suspended, waiting for trace session)"

    # Give the app a moment to create the diagnostic socket
    sleep 2
fi

# ---------------------------------------------------------------------------
# Step 5: Collect trace with dotnet-trace
# ---------------------------------------------------------------------------
echo ""
echo "--- Collecting .nettrace (${DURATION}s) ---"

# Event providers matching dotnet-optimization's configuration:
# Microsoft-Windows-DotNETRuntime with JIT, Loader, GC, Exception, ThreadPool, Interop events
PROVIDERS="Microsoft-Windows-DotNETRuntime:0x1F000080018:5,Microsoft-Windows-DotNETRuntime:0x4c14fccbd:5,Microsoft-Windows-DotNETRuntimePrivate:0x4002000b:5"

if [ "$PLATFORM" = "ios" ]; then
    DIAG_PORT_ARG="$IPC_NAME,connect"
else
    DIAG_PORT_ARG="$DIAG_SOCKET,connect"
fi

"$DOTNET_TRACE" collect \
    --output "$TRACE_FILE" \
    --diagnostic-port "$DIAG_PORT_ARG" \
    --duration "$(printf '%02d:%02d:%02d' $((DURATION / 3600)) $(((DURATION % 3600) / 60)) $((DURATION % 60)))" \
    --providers "$PROVIDERS"

TRACE_RESULT=$?

# ---------------------------------------------------------------------------
# Step 6: Validate trace file
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
        if [ "$PLATFORM" = "ios" ]; then
            echo "The app may not have connected to dsrouter properly."
            echo "Check that a device is connected, port 9000 is not in use,"
            echo "and the app is signed with a development provisioning profile."
        else
            echo "The app may not have connected to the diagnostic port properly."
        fi
    fi
else
    echo "ERROR: No trace file was produced."
    exit 1
fi

# ---------------------------------------------------------------------------
# Step 7: Collect system log for diagnostics
# ---------------------------------------------------------------------------
SYSLOG_FILE="$TRACE_DIR/syslog.txt"
echo "Saving system log to $SYSLOG_FILE..."
if [ "$PLATFORM" = "ios" ]; then
    log show --device --last 5m > "$SYSLOG_FILE" 2>/dev/null || true
else
    log show --last 5m --predicate "process == \"$BUNDLE_ID\"" > "$SYSLOG_FILE" 2>/dev/null || true
fi

echo ""
echo "=== .nettrace collection complete ==="
echo "Trace:  $TRACE_FILE"
echo "Syslog: $SYSLOG_FILE"
