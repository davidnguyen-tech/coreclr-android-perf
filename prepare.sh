#!/bin/bash

source "$(dirname "$0")/init.sh"

# Validate passed parameters
if [ "$#" -gt 2 ]; then
    echo "Error: Too many parameters passed."
    echo "Usage: $0 [-f] [-userollback]"
    exit 1
fi

if [ "$1" != "" ] && [ "$1" != "-f" ]; then
    echo "Error: Invalid first parameter. Only '-f' is allowed."
    exit 1
fi

if [ "$2" != "" ] && [ "$2" != "-userollback" ]; then
    echo "Error: Invalid second parameter. Only '-userollback' is allowed."
    exit 1
fi

# Check if DOTNET_DIR and VERSIONS_LOG exist
if [ -d "$DOTNET_DIR" ] && [ -f "$VERSIONS_LOG" ] && [ "$1" != "-f" ]; then
    echo "The environment is already set up. If you want to reset it, pass the -f parameter to the script."
    echo "Current config:"
    cat "$VERSIONS_LOG"
    exit 0
fi

# Create tools directory if it doesn't exist
mkdir -p "$TOOLS_DIR"

# Download dotnet-install script if it doesn't exist
if [ ! -f "$DOTNET_INSTALL_SCRIPT" ]; then
    curl -L -o "$DOTNET_INSTALL_SCRIPT" https://dot.net/v1/dotnet-install.sh
    chmod +x "$DOTNET_INSTALL_SCRIPT"
fi

# Resets the env
rm -rf "$DOTNET_DIR"
rm -rf "$LOCAL_PACKAGES"
rm -rf "$BUILD_DIR"
rm -f "$VERSIONS_LOG"

mkdir "$LOCAL_PACKAGES"
mkdir "$BUILD_DIR"

# Install the latest SDK build if it doesn't exist
if [ ! -d "$DOTNET_DIR" ]; then
    # Do a dry run to get the version and store it in the log
    VERSION=$("$DOTNET_INSTALL_SCRIPT" -c "11.0.1xx" -q daily -i "$DOTNET_DIR" -DryRun | grep -oE 'version "[^"]+"' | cut -d'"' -f2)
    echo "dotnet sdk: $VERSION" > $VERSIONS_LOG
    "$DOTNET_INSTALL_SCRIPT" -c "11.0.1xx" -q daily -i "$DOTNET_DIR"
fi

# Download NuGet.config file from dotnet/android repo
curl -L -o "$NUGET_CONFIG" https://raw.githubusercontent.com/dotnet/android/main/NuGet.config
if [ $? -ne 0 ] || [ ! -f "$NUGET_CONFIG" ]; then
    echo "Error: Failed to download or locate NuGet.config file."
    exit 1
fi

# Setup workload to take the latest manifests
"$DOTNET_DIR/dotnet" workload config --update-mode manifests

if [ "$2" == "-userollback" ]; then
    "$DOTNET_DIR/dotnet" workload update --from-rollback-file rollback.json
fi

# # Install the Android workload
"$DOTNET_DIR/dotnet" workload install android maui --from-rollback-file rollback.json

# List installed workloads and print the Manifest version for android workload
INSTALLED_WORKLOADS=$("$DOTNET_DIR/dotnet" workload --info)
ANDROID_WORKLOAD_INFO=$(echo "$INSTALLED_WORKLOADS" | grep -A 4 "\[android\]")
if [ -n "$ANDROID_WORKLOAD_INFO" ]; then
    ANDROID_MANIFEST_VERSION=$(echo "$ANDROID_WORKLOAD_INFO" | grep "Manifest Version" | awk '{print $3}')
    echo "dotnet android workload manifest version: $ANDROID_MANIFEST_VERSION" >> $VERSIONS_LOG
else
    echo "android workload not installed"
    echo "Fatal error: Android workload installation failed. Please retry running this script with the -f parameter to reset the environment."
    exit 1
fi

RID=$("$DOTNET_DIR/dotnet" --info | grep "RID:" | awk '{print $2}')

# Build the XAPerfTestRunner project
"$DOTNET_DIR/dotnet" publish external/XAPerfTestRunner/XAPerfTestRunner.csproj -c Release -r $RID --self-contained true -p:PublishSingleFile=true -p:RestoreAdditionalProjectSources=https://api.nuget.org/v3/index.json -o "$BUILD_DIR"