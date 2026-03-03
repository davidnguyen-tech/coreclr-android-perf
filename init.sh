#!/bin/bash

# Define variables
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
BUILD_DIR="$SCRIPT_DIR/build"
TOOLS_DIR="$SCRIPT_DIR/tools"
DOTNET_INSTALL_SCRIPT="$TOOLS_DIR/dotnet-install.sh"
DOTNET_DIR="$SCRIPT_DIR/.dotnet"
LOCAL_DOTNET="$DOTNET_DIR/dotnet"
LOCAL_PACKAGES="$SCRIPT_DIR/packages"
APPS_DIR="$SCRIPT_DIR/apps"
VERSIONS_LOG="$SCRIPT_DIR/versions.log"
NUGET_CONFIG="$SCRIPT_DIR/NuGet.config"
GLOBAL_JSON="$SCRIPT_DIR/global.json"
PERF_DIR="$SCRIPT_DIR/external/performance"
SCENARIOS_DIR="$PERF_DIR/src/scenarios"
TRACES_DIR="$SCRIPT_DIR/traces"
RESULTS_DIR="$SCRIPT_DIR/results"
ANDROID_DIR="$SCRIPT_DIR/android"
IOS_DIR="$SCRIPT_DIR/ios"

# Platform configuration
# Usage: resolve_platform_config <platform>
# Sets: PLATFORM_TFM, PLATFORM_RID, PLATFORM_DEVICE_TYPE, PLATFORM_SCENARIO_DIR,
#        PLATFORM_PACKAGE_GLOB, PLATFORM_PACKAGE_LABEL, PLATFORM_DIR
resolve_platform_config() {
    local platform="${1:-android}"

    case "$platform" in
        android)
            PLATFORM_TFM="net11.0-android"
            PLATFORM_RID="android-arm64"
            PLATFORM_DEVICE_TYPE="android"
            PLATFORM_SCENARIO_DIR="$SCENARIOS_DIR/genericandroidstartup"
            PLATFORM_PACKAGE_GLOB="*-Signed.apk"
            PLATFORM_PACKAGE_LABEL="APK"
            PLATFORM_DIR="$ANDROID_DIR"
            ;;
        ios)
            PLATFORM_TFM="net11.0-ios"
            PLATFORM_RID="ios-arm64"
            PLATFORM_DEVICE_TYPE="apple"
            PLATFORM_SCENARIO_DIR="$SCENARIOS_DIR/genericiosstartup"
            PLATFORM_PACKAGE_GLOB="*.app"
            PLATFORM_PACKAGE_LABEL="APP"
            PLATFORM_DIR="$IOS_DIR"
            ;;
        *)
            echo "Error: Unknown platform '$platform'. Supported: android, ios"
            return 1
            ;;
    esac
}
