#!/bin/bash

source "$(dirname "$0")/init.sh"

# Validate required tools
if [ ! -f "$LOCAL_DOTNET" ]; then
    echo "Error: $LOCAL_DOTNET does not exist. Please run ./prepare.sh first."
    exit 1
fi

if ! command -v python3 &> /dev/null; then
    echo "Error: python3 is required but not found."
    exit 1
fi

if ! command -v xharness &> /dev/null && [ ! -f "$TOOLS_DIR/xharness" ]; then
    echo "Error: xharness is required but not found. Run ./prepare.sh to install it."
    exit 1
fi

# Usage
print_usage() {
    echo "Usage: $0 <dotnet-new-android|dotnet-new-maui|dotnet-new-maui-samplecontent> <mono|coreclr> <build-config> [options]"
    echo ""
    echo "Build configs: JIT, AOT, PAOT, R2R, R2R_COMP, R2R_COMP_PGO"
    echo ""
    echo "Options:"
    echo "  --disable-animations          Disable device animations during measurement"
    echo "  --use-fully-drawn-time        Use fully drawn time instead of displayed time"
    echo "  --fully-drawn-extra-delay N   Extra delay in seconds for fully drawn time"
    echo "  --trace-perfetto              Capture a perfetto trace after measurements"
    echo "  --startup-iterations N        Number of startup iterations (default: 10)"
    exit 1
}

if [[ -z "$1" || -z "$2" || -z "$3" ]]; then
    print_usage
fi

SAMPLE_APP=$1
RUNTIME=$2
BUILD_CONFIG=$3
shift 3

# Validate app name
if [[ "$SAMPLE_APP" != "dotnet-new-android" && "$SAMPLE_APP" != "dotnet-new-maui" && "$SAMPLE_APP" != "dotnet-new-maui-samplecontent" ]]; then
    echo "Invalid app: $SAMPLE_APP"
    print_usage
fi

# Validate runtime
if [[ "$RUNTIME" != "mono" && "$RUNTIME" != "coreclr" ]]; then
    echo "Invalid runtime: $RUNTIME"
    print_usage
fi

APP_DIR="$APPS_DIR/$SAMPLE_APP"
if [ ! -d "$APP_DIR" ]; then
    echo "Error: App directory $APP_DIR does not exist. Run ./prepare.sh first."
    exit 1
fi

# Determine runtime-specific MSBuild args
MSBUILD_ARGS=""
if [[ "$RUNTIME" == "mono" ]]; then
    MSBUILD_ARGS="-p:UseMonoRuntime=true"
elif [[ "$RUNTIME" == "coreclr" ]]; then
    MSBUILD_ARGS="-p:UseMonoRuntime=false"
fi

# Add build config
MSBUILD_ARGS="$MSBUILD_ARGS -p:_BuildConfig=$BUILD_CONFIG"

# Determine package name from the csproj
PACKAGE_NAME=$(grep -o '<ApplicationId>[^<]*' "$APP_DIR/$SAMPLE_APP.csproj" | sed 's/<ApplicationId>//')
if [ -z "$PACKAGE_NAME" ]; then
    # Fallback for android template
    PACKAGE_NAME="com.companyname.$(echo "$SAMPLE_APP" | tr '-' '_')"
fi

echo "=== Building $SAMPLE_APP ($RUNTIME, $BUILD_CONFIG) ==="

# Build the APK
${LOCAL_DOTNET} build -c Release -f net11.0-android -r android-arm64 \
    -bl:"$BUILD_DIR/${SAMPLE_APP}_${RUNTIME}_${BUILD_CONFIG}.binlog" \
    "$APP_DIR/$SAMPLE_APP.csproj" \
    $MSBUILD_ARGS

if [ $? -ne 0 ]; then
    echo "Error: Build failed."
    exit 1
fi

# Find the signed APK
APK_PATH=$(find "$APP_DIR" -name "*-Signed.apk" -path "*/Release/*" | head -1)
if [ -z "$APK_PATH" ]; then
    echo "Error: Could not find signed APK after build."
    exit 1
fi

echo "Built APK: $APK_PATH"
echo ""
echo "=== Measuring startup ==="

# Use local .dotnet for DOTNET_ROOT so the Startup parser tool can find its runtime
export DOTNET_ROOT="$DOTNET_DIR"
export PATH="$DOTNET_DIR:$PATH"

# Set up PYTHONPATH for dotnet/performance scripts
export PYTHONPATH="$SCENARIOS_DIR:$PYTHONPATH"

# Add xharness to PATH if it's in the tools directory
if [ -f "$TOOLS_DIR/xharness" ]; then
    export PATH="$TOOLS_DIR:$PATH"
fi

# Run startup measurement using dotnet/performance's test.py
cd "$SCENARIOS_DIR/genericandroidstartup" || { echo "Error: dotnet/performance scenario directory not found. Run ./prepare.sh first."; exit 1; }

# Create results directory
RESULT_NAME="${SAMPLE_APP}_${RUNTIME}_${BUILD_CONFIG}"
mkdir -p "$RESULTS_DIR"

python3 test.py devicestartup \
    --device-type android \
    --package-path "$APK_PATH" \
    --package-name "$PACKAGE_NAME" \
    "$@"

RESULT=$?

# Save the raw trace and any generated reports
TRACE_SRC="traces/PerfTest/runoutput.trace"
if [ -f "$TRACE_SRC" ]; then
    cp "$TRACE_SRC" "$RESULTS_DIR/${RESULT_NAME}.trace"
fi

cd "$SCRIPT_DIR" || exit 1

if [ $RESULT -ne 0 ]; then
    echo "Error: Startup measurement failed."
    exit 1
fi

echo ""
echo "=== Measurement complete ==="
if [ -f "$RESULTS_DIR/${RESULT_NAME}.trace" ]; then
    echo "Results saved to: results/${RESULT_NAME}.trace"
fi