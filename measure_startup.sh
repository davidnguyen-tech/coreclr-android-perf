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
    echo "Usage: $0 <dotnet-new-android|dotnet-new-maui|dotnet-new-maui-samplecontent> <build-config> [options]"
    echo ""
    echo "Build configs: MONO_JIT, CORECLR_JIT, MONO_AOT, MONO_PAOT, R2R, R2R_COMP, R2R_COMP_PGO"
    echo ""
    echo "Options:"
    echo "  --platform <android|ios>      Target platform (default: from prepare.sh)"
    echo "  --local-runtime <path>        Path to local dotnet/runtime repo with built shipping packages"
    echo "  --local-runtime-config <cfg>  Runtime build configuration: Release, Debug (default: Release)"
    echo "  --disable-animations          Disable device animations during measurement"
    echo "  --use-fully-drawn-time        Use fully drawn time instead of displayed time"
    echo "  --fully-drawn-extra-delay N   Extra delay in seconds for fully drawn time"
    echo "  --trace-perfetto              Capture a perfetto trace after measurements"
    echo "  --startup-iterations N        Number of startup iterations (default: 10)"
    echo "  --results-dir <path>          Save results to this directory (default: auto-generated timestamped dir)"
    exit 1
}

if [[ -z "$1" || -z "$2" ]]; then
    print_usage
fi

SAMPLE_APP=$1
BUILD_CONFIG=$2
shift 2

# Parse options to extract --platform and --local-runtime before passing remaining args to test.py
PLATFORM="$(read_prepared_platform)"
LOCAL_RUNTIME_PATH=""
LOCAL_RUNTIME_CONFIG="Release"
CUSTOM_RESULTS_DIR=""
STARTUP_ITERATIONS=10
PASSTHROUGH_ARGS=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --platform)
            if [[ -z "$2" || "$2" == --* ]]; then
                echo "Error: --platform requires a value (android, ios)"
                exit 1
            fi
            PLATFORM="$2"
            shift 2
            ;;
        --local-runtime)
            if [[ -z "$2" || "$2" == --* ]]; then
                echo "Error: --local-runtime requires a path to the runtime repo"
                exit 1
            fi
            LOCAL_RUNTIME_PATH="$2"
            shift 2
            ;;
        --local-runtime-config)
            if [[ -z "$2" || "$2" == --* ]]; then
                echo "Error: --local-runtime-config requires a value (Release, Debug)"
                exit 1
            fi
            LOCAL_RUNTIME_CONFIG="$2"
            shift 2
            ;;
        --results-dir)
            if [[ -z "$2" || "$2" == --* ]]; then
                echo "Error: --results-dir requires a path"
                exit 1
            fi
            CUSTOM_RESULTS_DIR="$2"
            shift 2
            ;;
        --startup-iterations)
            if [[ -z "$2" || "$2" == --* ]]; then
                echo "Error: --startup-iterations requires a numeric value"
                exit 1
            fi
            STARTUP_ITERATIONS="$2"
            PASSTHROUGH_ARGS+=("$1" "$2")
            shift 2
            ;;
        *)
            PASSTHROUGH_ARGS+=("$1")
            shift
            ;;
    esac
done
set -- "${PASSTHROUGH_ARGS[@]}"

# Resolve platform-specific configuration
resolve_platform_config "$PLATFORM" || exit 1

# Validate build config
VALID_CONFIGS="MONO_JIT CORECLR_JIT MONO_AOT MONO_PAOT R2R R2R_COMP R2R_COMP_PGO"
if [[ ! " $VALID_CONFIGS " =~ " $BUILD_CONFIG " ]]; then
    echo "Invalid build config '$BUILD_CONFIG'. Allowed values are: $VALID_CONFIGS"
    exit 1
fi

APP_DIR="$APPS_DIR/$SAMPLE_APP"
if [ ! -d "$APP_DIR" ]; then
    echo "Error: App directory $APP_DIR does not exist. Run ./prepare.sh first."
    exit 1
fi

# Build config determines all MSBuild properties (including UseMonoRuntime)
MSBUILD_ARGS="-p:_BuildConfig=$BUILD_CONFIG"

# Configure local runtime if requested
if [ -n "$LOCAL_RUNTIME_PATH" ]; then
    configure_local_runtime "$LOCAL_RUNTIME_PATH" "$PLATFORM_RID" "$LOCAL_RUNTIME_CONFIG" || exit 1
    generate_local_nuget_config "$APP_DIR" || exit 1
    generate_local_build_props "$APP_DIR" || exit 1
    MSBUILD_ARGS="$MSBUILD_ARGS -p:_UseLocalRuntime=true"
fi

# Generate timestamped results directory
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
RESULT_NAME="${SAMPLE_APP}_${BUILD_CONFIG}"
LOCAL_RUNTIME_SUFFIX=""
if [ "$LOCAL_RUNTIME_ACTIVE" = true ]; then
    LOCAL_RUNTIME_SUFFIX="_local-runtime"
fi
if [ -n "$CUSTOM_RESULTS_DIR" ]; then
    RUN_RESULTS_DIR="$CUSTOM_RESULTS_DIR"
else
    RUN_RESULTS_DIR="$RESULTS_DIR/${TIMESTAMP}_${RESULT_NAME}_iter${STARTUP_ITERATIONS}${LOCAL_RUNTIME_SUFFIX}"
fi

# Determine package name from the csproj
PACKAGE_NAME=$(grep -o '<ApplicationId>[^<]*' "$APP_DIR/$SAMPLE_APP.csproj" | sed 's/<ApplicationId>//')
if [ -z "$PACKAGE_NAME" ]; then
    # Fallback for android template
    PACKAGE_NAME="com.companyname.$(echo "$SAMPLE_APP" | tr '-' '_')"
fi

echo "=== Building $SAMPLE_APP ($BUILD_CONFIG) ==="

# Clean previous build artifacts to avoid stale state between configs
rm -rf "${APP_DIR:?}/bin" "${APP_DIR:?}/obj"

# Clear NuGet cache when using local runtime to ensure fresh packages
if [ "$LOCAL_RUNTIME_ACTIVE" = true ]; then
    echo "Clearing NuGet package cache ($LOCAL_PACKAGES)..."
    rm -rf "${LOCAL_PACKAGES:?}"
    mkdir -p "$LOCAL_PACKAGES"
fi

# Build the package
${LOCAL_DOTNET} build -c Release -f "$PLATFORM_TFM" -r "$PLATFORM_RID" \
    -bl:"$BUILD_DIR/${SAMPLE_APP}_${BUILD_CONFIG}.binlog" \
    "$APP_DIR/$SAMPLE_APP.csproj" \
    $MSBUILD_ARGS

if [ $? -ne 0 ]; then
    echo "Error: Build failed."
    exit 1
fi

# Find the built package in the bin/ output directory (not obj/ intermediates)
PACKAGE_PATH=$(find "$APP_DIR/bin" -name "$PLATFORM_PACKAGE_GLOB" -path "*/Release/*" | head -1)
if [ -z "$PACKAGE_PATH" ]; then
    # Fallback: search entire app dir but prefer bin/ over obj/
    PACKAGE_PATH=$(find "$APP_DIR" -name "$PLATFORM_PACKAGE_GLOB" -path "*/bin/Release/*" -not -path "*/obj/*" | head -1)
fi
if [ -z "$PACKAGE_PATH" ]; then
    echo "Error: Could not find $PLATFORM_PACKAGE_LABEL package after build."
    exit 1
fi

# Record package size (iOS .app is a directory; use du for directories)
if [ -d "$PACKAGE_PATH" ]; then
    PACKAGE_SIZE_BYTES=$(du -sk "$PACKAGE_PATH" | awk '{print $1 * 1024}')
else
    PACKAGE_SIZE_BYTES=$(stat -f%z "$PACKAGE_PATH" 2>/dev/null || stat -c%s "$PACKAGE_PATH" 2>/dev/null)
fi
if [ -z "$PACKAGE_SIZE_BYTES" ]; then
    echo "Warning: Could not determine $PLATFORM_PACKAGE_LABEL size for $PACKAGE_PATH"
    PACKAGE_SIZE_MB="unknown"
else
    PACKAGE_SIZE_MB=$(python3 -c "print(f'{$PACKAGE_SIZE_BYTES / 1048576:.2f}')")
fi
echo "Built $PLATFORM_PACKAGE_LABEL: $PACKAGE_PATH (${PACKAGE_SIZE_MB} MB)"
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
cd "$PLATFORM_SCENARIO_DIR" || { echo "Error: dotnet/performance scenario directory not found. Run ./prepare.sh first."; exit 1; }

# Create results directory
mkdir -p "$RUN_RESULTS_DIR"

python3 test.py devicestartup \
    --device-type "$PLATFORM_DEVICE_TYPE" \
    --package-path "$PACKAGE_PATH" \
    --package-name "$PACKAGE_NAME" \
    "$@"

RESULT=$?

# Save the raw trace and any generated reports
RESULT_NAME="${SAMPLE_APP}_${BUILD_CONFIG}"
TRACE_SRC="traces/PerfTest/runoutput.trace"
if [ -f "$TRACE_SRC" ]; then
    cp "$TRACE_SRC" "$RUN_RESULTS_DIR/${RESULT_NAME}.trace"
fi

# Save package size metadata
if [ -n "$PACKAGE_SIZE_BYTES" ]; then
    echo "${PACKAGE_SIZE_BYTES}" > "$RUN_RESULTS_DIR/${RESULT_NAME}.size"
fi

cd "$SCRIPT_DIR" || exit 1

if [ $RESULT -ne 0 ]; then
    echo "Error: Startup measurement failed."
    exit 1
fi

echo ""
echo "=== Measurement complete ==="
echo "$PLATFORM_PACKAGE_LABEL size: ${PACKAGE_SIZE_MB} MB ($PACKAGE_SIZE_BYTES bytes)"
if [ -f "$RUN_RESULTS_DIR/${RESULT_NAME}.trace" ]; then
    echo "Results saved to: $RUN_RESULTS_DIR/"
fi