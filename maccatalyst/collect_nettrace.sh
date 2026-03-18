#!/bin/bash

# Collects a .nettrace file for a given (app, build-config) tuple.
# Mac Catalyst apps run locally on macOS — no dsrouter device bridge is needed.
# Uses a diagnostic port with suspend to capture full startup events.

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

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------
print_usage() {
    echo "Usage: $0 <app> <build-config> [options]"
    echo ""
    echo "Collects a .nettrace startup trace for the given (app, build-config) tuple."
    echo "Mac Catalyst apps run locally on macOS — no dsrouter or device bridge is needed."
    echo ""
    echo "Apps:     dotnet-new-maui, dotnet-new-maui-samplecontent"
    echo "Configs:  MONO_JIT, CORECLR_JIT, MONO_AOT, MONO_PAOT, R2R_COMP, R2R_COMP_PGO"
    echo ""
    echo "Options:"
    echo "  --platform PLATFORM      Target platform (default: maccatalyst)"
    echo "  --duration N             Trace duration in seconds (default: 60)"
    echo "  --force                  Re-collect even if trace already exists"
    echo ""
    echo "Output: traces/<app>_<config>/maccatalyst-startup.nettrace"
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
PLATFORM="maccatalyst"

while [[ $# -gt 0 ]]; do
    case $1 in
        --platform)
            if [[ -z "$2" || "$2" == --* ]]; then
                echo "Error: --platform requires a value"
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
        *)
            echo "Unknown option: $1"
            print_usage
            ;;
    esac
done

# ---------------------------------------------------------------------------
# Resolve platform configuration
# ---------------------------------------------------------------------------
resolve_platform_config "$PLATFORM" || exit 1

# Validate app name
APP_DIR="$APPS_DIR/$SAMPLE_APP"
if [ ! -d "$APP_DIR" ]; then
    echo "Error: App '$SAMPLE_APP' not found in $APPS_DIR"
    print_usage
fi

# Validate build config
VALID_CONFIGS="MONO_JIT CORECLR_JIT MONO_AOT MONO_PAOT R2R_COMP R2R_COMP_PGO"
if [[ ! " $VALID_CONFIGS " =~ " $BUILD_CONFIG " ]]; then
    echo "Invalid build config '$BUILD_CONFIG'. Allowed values are: $VALID_CONFIGS"
    exit 1
fi

# ---------------------------------------------------------------------------
# Check if trace already exists
# ---------------------------------------------------------------------------
TRACE_DIR="$TRACES_DIR/${SAMPLE_APP}_${BUILD_CONFIG}"
TRACE_FILE="$TRACE_DIR/maccatalyst-startup.nettrace"

if [ -f "$TRACE_FILE" ] && [ "$FORCE" = false ]; then
    TRACE_SIZE=$(wc -c < "$TRACE_FILE" | tr -d ' ')
    echo "Trace already exists: $TRACE_FILE ($TRACE_SIZE bytes)"
    echo "Use --force to re-collect."
    exit 0
fi

mkdir -p "$TRACE_DIR"

# ---------------------------------------------------------------------------
# Diagnostic socket path
# ---------------------------------------------------------------------------
DIAG_SOCKET="/tmp/diag-$$.sock"

# ---------------------------------------------------------------------------
# Cleanup function
# ---------------------------------------------------------------------------
APP_PID=""
cleanup() {
    echo ""
    echo "=== Cleaning up ==="

    # Kill the app process if still running
    if [ -n "$APP_PID" ] && kill -0 "$APP_PID" 2>/dev/null; then
        echo "Stopping app process (PID $APP_PID)..."
        kill "$APP_PID" 2>/dev/null
        wait "$APP_PID" 2>/dev/null
    fi

    # Remove diagnostic socket file if it exists
    if [ -e "$DIAG_SOCKET" ]; then
        echo "Removing diagnostic socket: $DIAG_SOCKET"
        rm -f "$DIAG_SOCKET" 2>/dev/null
    fi
}

trap cleanup EXIT

# ---------------------------------------------------------------------------
# Step 1: Build the app
# ---------------------------------------------------------------------------
echo "=== Collecting .nettrace for $SAMPLE_APP ($BUILD_CONFIG) ==="
echo "Trace duration: ${DURATION}s"
echo "Diagnostic socket: $DIAG_SOCKET"
echo ""

echo "--- Building app ---"
${LOCAL_DOTNET} build -c Release \
    -f "$PLATFORM_TFM" -r "$PLATFORM_RID" \
    -tl:off \
    -bl:"$TRACE_DIR/${SAMPLE_APP}_${BUILD_CONFIG}_nettrace.binlog" \
    "$APP_DIR/$SAMPLE_APP.csproj" \
    -p:_BuildConfig="$BUILD_CONFIG"

if [ $? -ne 0 ]; then
    echo "Error: Build failed."
    exit 1
fi

# ---------------------------------------------------------------------------
# Step 2: Locate the built .app bundle
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

# Determine the executable inside the .app bundle
APP_NAME=$(defaults read "$APP_BUNDLE/Contents/Info.plist" CFBundleExecutable 2>/dev/null)
if [ -z "$APP_NAME" ]; then
    # Fall back to bundle name without .app extension
    APP_NAME=$(basename "$APP_BUNDLE" .app)
fi

APP_EXECUTABLE="$APP_BUNDLE/Contents/MacOS/$APP_NAME"

if [ ! -f "$APP_EXECUTABLE" ]; then
    echo "Error: Executable not found at $APP_EXECUTABLE"
    echo "Contents of $APP_BUNDLE/Contents/MacOS/:"
    ls -la "$APP_BUNDLE/Contents/MacOS/" 2>/dev/null || echo "  (directory does not exist)"
    exit 1
fi

echo "App executable: $APP_EXECUTABLE"

# ---------------------------------------------------------------------------
# Step 3: Launch the app with diagnostic port (suspended)
# ---------------------------------------------------------------------------
echo ""
echo "--- Launching app with diagnostic port (suspended) ---"

DOTNET_DiagnosticPorts="$DIAG_SOCKET,suspend" "$APP_EXECUTABLE" &
APP_PID=$!

echo "App launched with PID: $APP_PID (suspended, waiting for trace session)"

# Give the app a moment to create the diagnostic socket
sleep 2

if ! kill -0 "$APP_PID" 2>/dev/null; then
    echo "Error: App process exited unexpectedly."
    exit 1
fi

# ---------------------------------------------------------------------------
# Step 4: Collect trace with dotnet-trace
# ---------------------------------------------------------------------------
echo ""
echo "--- Collecting .nettrace (${DURATION}s) ---"

# Event providers matching dotnet-optimization's configuration:
# Microsoft-Windows-DotNETRuntime with JIT, Loader, GC, Exception, ThreadPool, Interop events
PROVIDERS="Microsoft-Windows-DotNETRuntime:0x5F000080018:5,Microsoft-Windows-DotNETRuntime:0x4c14fccbd:5,Microsoft-Windows-DotNETRuntimePrivate:0x4002000b:5"

"$DOTNET_TRACE" collect \
    --output "$TRACE_FILE" \
    --diagnostic-port "$DIAG_SOCKET,connect" \
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
        echo "The app may not have connected to the diagnostic port properly."
    fi
else
    echo "ERROR: No trace file was produced."
    exit 1
fi

# ---------------------------------------------------------------------------
# Step 6: Collect system log for diagnostics
# ---------------------------------------------------------------------------
SYSLOG_FILE="$TRACE_DIR/syslog.txt"
echo "Saving system log to $SYSLOG_FILE..."
log show --last 5m --predicate "process == \"$APP_NAME\"" > "$SYSLOG_FILE" 2>/dev/null || true

echo ""
echo "=== .nettrace collection complete ==="
echo "Trace:  $TRACE_FILE"
echo "Syslog: $SYSLOG_FILE"
