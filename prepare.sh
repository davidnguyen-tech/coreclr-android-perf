#!/bin/bash

source "$(dirname "$0")/init.sh"

# Validate passed parameters
FORCE=false
USE_ROLLBACK=false

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
        *)
            echo "Error: Invalid parameter '$1'."
            echo "Usage: $0 [-f] [-userollback]"
            exit 1
            ;;
    esac
done

# Check if environment is already set up
if [ -d "$DOTNET_DIR" ] && [ -f "$VERSIONS_LOG" ] && [ "$FORCE" = false ]; then
    echo "The environment is already set up. If you want to reset it, pass the -f parameter to the script."
    echo "Current config:"
    cat "$VERSIONS_LOG"
    exit 0
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

# Download NuGet.config file from dotnet/android repo
curl -L -o "$NUGET_CONFIG" https://raw.githubusercontent.com/dotnet/android/main/NuGet.config
if [ $? -ne 0 ] || [ ! -f "$NUGET_CONFIG" ]; then
    echo "Error: Failed to download or locate NuGet.config file."
    exit 1
fi

# Setup workload to take the latest manifests
"$LOCAL_DOTNET" workload config --update-mode manifests

if [ "$USE_ROLLBACK" = true ]; then
    "$LOCAL_DOTNET" workload update --from-rollback-file rollback.json
fi

# Install the Android and MAUI workloads
"$LOCAL_DOTNET" workload install android maui
if [ $? -ne 0 ]; then
    echo "Error: Failed to install workloads."
    exit 1
fi

# Log installed workload info
INSTALLED_WORKLOADS=$("$LOCAL_DOTNET" workload --info)
ANDROID_WORKLOAD_INFO=$(echo "$INSTALLED_WORKLOADS" | grep -A 4 "\[android\]")
if [ -n "$ANDROID_WORKLOAD_INFO" ]; then
    ANDROID_MANIFEST_VERSION=$(echo "$ANDROID_WORKLOAD_INFO" | grep "Manifest Version" | awk '{print $3}')
    echo "dotnet android workload manifest version: $ANDROID_MANIFEST_VERSION" >> "$VERSIONS_LOG"
else
    echo "android workload not installed"
    echo "Fatal error: Android workload installation failed. Please retry running this script with the -f parameter to reset the environment."
    exit 1
fi

# Install xharness CLI tool (required for startup measurements)
"$LOCAL_DOTNET" tool install Microsoft.DotNet.XHarness.CLI --tool-path "$TOOLS_DIR" --version "*" --add-source https://pkgs.dev.azure.com/dnceng/public/_packaging/dotnet-eng/nuget/v3/index.json
echo "xharness: $("$TOOLS_DIR/xharness" version 2>/dev/null || echo 'installed')" >> "$VERSIONS_LOG"

# Install diagnostic tools (required for .nettrace collection)
DIAG_FEED="https://pkgs.dev.azure.com/dnceng/public/_packaging/dotnet-tools/nuget/v3/index.json"
"$LOCAL_DOTNET" tool install dotnet-dsrouter --tool-path "$TOOLS_DIR" --version "*" --add-source "$DIAG_FEED"
"$LOCAL_DOTNET" tool install dotnet-trace --tool-path "$TOOLS_DIR" --version "*" --add-source "$DIAG_FEED"
echo "dotnet-dsrouter: installed" >> "$VERSIONS_LOG"
echo "dotnet-trace: installed" >> "$VERSIONS_LOG"

# Initialize the dotnet/performance submodule
echo "Initializing dotnet/performance submodule..."
git submodule update --init --recursive external/performance

# Generate sample apps
echo "Generating sample apps..."
"$SCRIPT_DIR/generate-apps.sh"

echo ""
echo "=== Environment setup complete ==="
cat "$VERSIONS_LOG"