#!/bin/bash

source "$(dirname "$0")/init.sh"

# Validate passed parameters
FORCE=false
USE_ROLLBACK=false
PLATFORM="android"

while [[ $# -gt 0 ]]; do
    case $1 in
        -f)
            FORCE=true
            shift
            ;;
        -userollback)
            USE_ROLLBACK=true
            shift
            ;;
        --platform)
            if [[ -z "$2" || "$2" == --* ]]; then
                echo "Error: --platform requires a value (android, ios, osx, maccatalyst)"
                exit 1
            fi
            PLATFORM="$2"
            shift 2
            ;;
        *)
            echo "Error: Invalid parameter '$1'."
            echo "Usage: $0 [-f] [-userollback] [--platform android|ios|osx|maccatalyst]"
            exit 1
            ;;
    esac
done

# Validate platform
case "$PLATFORM" in
    android|ios|osx|maccatalyst) ;;
    *)
        echo "Error: Unsupported platform '$PLATFORM'. Supported: android, ios, osx, maccatalyst"
        exit 1
        ;;
esac

# Check if environment is already set up
if [ -d "$DOTNET_DIR" ] && [ -f "$VERSIONS_LOG" ] && [ "$FORCE" = false ]; then
    echo "The environment is already set up. If you want to reset it, pass the -f parameter to the script."
    echo "Current config:"
    cat "$VERSIONS_LOG"
    exit 0
fi

# Validate prerequisites
if ! command -v python3 &> /dev/null; then
    echo "Error: python3 is required but not found in PATH."
    exit 1
fi

# Read SDK version from global.json
if [ ! -f "$GLOBAL_JSON" ]; then
    echo "Error: global.json not found at $GLOBAL_JSON"
    exit 1
fi

SDK_VERSION=$(python3 -c "import json, sys; print(json.load(open(sys.argv[1]))['sdk']['version'])" "$GLOBAL_JSON" 2>/dev/null)
if [ -z "$SDK_VERSION" ]; then
    echo "Error: Failed to read SDK version from global.json"
    exit 1
fi
echo "SDK version from global.json: $SDK_VERSION"

# Create tools directory if it doesn't exist
mkdir -p "$TOOLS_DIR"

# Download dotnet-install script if it doesn't exist
if [ ! -f "$DOTNET_INSTALL_SCRIPT" ]; then
    curl -L -o "$DOTNET_INSTALL_SCRIPT" https://dot.net/v1/dotnet-install.sh
    chmod +x "$DOTNET_INSTALL_SCRIPT"
fi

# Reset the environment
rm -rf "$DOTNET_DIR"
rm -rf "$LOCAL_PACKAGES"
rm -rf "$BUILD_DIR"
rm -rf "$APPS_DIR"
rm -f "$VERSIONS_LOG"
# Clean tool binaries (keep dotnet-install.sh)
find "$TOOLS_DIR" -maxdepth 1 -type f ! -name "dotnet-install.sh" -exec rm -f {} \; 2>/dev/null
find "$TOOLS_DIR" -maxdepth 1 -type d ! -path "$TOOLS_DIR" -exec rm -rf {} \; 2>/dev/null

mkdir -p "$LOCAL_PACKAGES"
mkdir -p "$BUILD_DIR"

# Install the SDK version specified in global.json
echo "Installing .NET SDK $SDK_VERSION..."
"$DOTNET_INSTALL_SCRIPT" --version "$SDK_VERSION" -i "$DOTNET_DIR"
if [ $? -ne 0 ]; then
    echo "Error: Failed to install .NET SDK $SDK_VERSION"
    exit 1
fi
echo "dotnet sdk: $SDK_VERSION" > "$VERSIONS_LOG"

# Install .NET 8 runtime (needed by dotnet/performance's Startup parser tool)
echo "Installing .NET 8 runtime (for dotnet/performance tooling)..."
"$DOTNET_INSTALL_SCRIPT" --runtime dotnet --channel 8.0 --install-dir "$DOTNET_DIR"
if [ $? -ne 0 ]; then
    echo "Warning: Failed to install .NET 8 runtime. Startup result parsing may fail."
fi

# Download NuGet.config file from dotnet/android repo
curl -L -o "$NUGET_CONFIG" https://raw.githubusercontent.com/dotnet/android/main/NuGet.config
if [ $? -ne 0 ] || [ ! -f "$NUGET_CONFIG" ]; then
    echo "Error: Failed to download or locate NuGet.config file."
    exit 1
fi

# Setup workload to take the latest manifests
"$LOCAL_DOTNET" workload config --update-mode manifests

if [ "$USE_ROLLBACK" = true ]; then
    "$LOCAL_DOTNET" workload update --from-rollback-file "$SCRIPT_DIR/rollback.json"
    if [ $? -ne 0 ]; then
        echo "Error: Failed to apply workload rollback."
        exit 1
    fi
fi

# Install platform-specific workloads
case "$PLATFORM" in
    android)      WORKLOADS="android maui-android" ;;
    ios)          WORKLOADS="ios maui-ios" ;;
    osx)          WORKLOADS="macos maui-macos" ;;
    maccatalyst)  WORKLOADS="maccatalyst maui-maccatalyst" ;;
esac
echo "Installing workloads for $PLATFORM: $WORKLOADS"
"$LOCAL_DOTNET" workload install $WORKLOADS
if [ $? -ne 0 ]; then
    echo "Error: Failed to install workloads."
    exit 1
fi

# Log installed workload info
INSTALLED_WORKLOADS=$("$LOCAL_DOTNET" workload --info)
PLATFORM_WORKLOAD_INFO=$(echo "$INSTALLED_WORKLOADS" | grep -A 4 "\[$PLATFORM\]")
if [ -n "$PLATFORM_WORKLOAD_INFO" ]; then
    PLATFORM_MANIFEST_VERSION=$(echo "$PLATFORM_WORKLOAD_INFO" | grep "Manifest Version" | awk '{print $3}')
    echo "dotnet $PLATFORM workload manifest version: $PLATFORM_MANIFEST_VERSION" >> "$VERSIONS_LOG"
else
    echo "$PLATFORM workload not installed"
    echo "Fatal error: $PLATFORM workload installation failed. Please retry running this script with the -f parameter to reset the environment."
    exit 1
fi

# Install xharness CLI tool (required for startup measurements)
"$LOCAL_DOTNET" tool install Microsoft.DotNet.XHarness.CLI --tool-path "$TOOLS_DIR" --version "11.0.0-prerelease.*" --add-source https://pkgs.dev.azure.com/dnceng/public/_packaging/dotnet-eng/nuget/v3/index.json
if [ $? -ne 0 ]; then
    echo "Error: Failed to install xharness."
    exit 1
fi
echo "xharness: $("$TOOLS_DIR/xharness" version 2>/dev/null || echo 'installed')" >> "$VERSIONS_LOG"

# Install diagnostic tools (required for .nettrace collection)
DIAG_FEED="https://pkgs.dev.azure.com/dnceng/public/_packaging/dotnet-tools/nuget/v3/index.json"
"$LOCAL_DOTNET" tool install dotnet-dsrouter --tool-path "$TOOLS_DIR" --version "*" --add-source "$DIAG_FEED"
if [ $? -ne 0 ]; then
    echo "Error: Failed to install dotnet-dsrouter."
    exit 1
fi
"$LOCAL_DOTNET" tool install dotnet-trace --tool-path "$TOOLS_DIR" --version "*" --add-source "$DIAG_FEED"
if [ $? -ne 0 ]; then
    echo "Error: Failed to install dotnet-trace."
    exit 1
fi
echo "dotnet-dsrouter: $("$TOOLS_DIR/dotnet-dsrouter" --version 2>/dev/null || echo 'installed')" >> "$VERSIONS_LOG"
echo "dotnet-trace: $("$TOOLS_DIR/dotnet-trace" --version 2>/dev/null || echo 'installed')" >> "$VERSIONS_LOG"

# Initialize the dotnet/performance submodule
echo "Initializing dotnet/performance submodule..."
if [ -f "$SCRIPT_DIR/external/performance/README.md" ]; then
    echo "Submodule already populated, skipping."
else
    git -C "$SCRIPT_DIR" submodule update --init --recursive
    if [ $? -ne 0 ]; then
        echo "Error: Failed to initialize dotnet/performance submodule."
        exit 1
    fi
fi

# Generate sample apps
echo "Generating sample apps..."
"$SCRIPT_DIR/generate-apps.sh" --platform "$PLATFORM"
if [ $? -ne 0 ]; then
    echo "Error: Failed to generate sample apps."
    exit 1
fi

echo ""
echo "=== Environment setup complete ==="
cat "$VERSIONS_LOG"