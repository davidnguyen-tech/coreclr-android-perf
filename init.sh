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
OSX_DIR="$SCRIPT_DIR/osx"
MACCATALYST_DIR="$SCRIPT_DIR/maccatalyst"

# Platform configuration
# Usage: resolve_platform_config <platform>
# Sets: PLATFORM_TFM, PLATFORM_RID, PLATFORM_DEVICE_TYPE, PLATFORM_SCENARIO_DIR,
#        PLATFORM_PACKAGE_GLOB, PLATFORM_PACKAGE_LABEL, PLATFORM_DIR
resolve_platform_config() {
    local platform="${1:-android}"

    case "$platform" in
        android|android-emulator)
            PLATFORM_TFM="net11.0-android"
            PLATFORM_DEVICE_TYPE="android"
            PLATFORM_SCENARIO_DIR="$SCENARIOS_DIR/genericandroidstartup"
            PLATFORM_PACKAGE_GLOB="*-Signed.apk"
            PLATFORM_PACKAGE_LABEL="APK"
            PLATFORM_DIR="$ANDROID_DIR"
            # RID selection: physical devices are always arm64;
            # emulators match the host architecture.
            if [ "$platform" = "android-emulator" ]; then
                local arch
                arch="$(uname -m)"
                if [ "$arch" = "arm64" ] || [ "$arch" = "aarch64" ]; then
                    PLATFORM_RID="android-arm64"
                else
                    PLATFORM_RID="android-x64"
                fi
            else
                PLATFORM_RID="android-arm64"
            fi
            ;;
        ios|ios-simulator)
            PLATFORM_TFM="net11.0-ios"
            PLATFORM_SCENARIO_DIR="$SCENARIOS_DIR/genericiosstartup"
            PLATFORM_PACKAGE_GLOB="*.app"
            PLATFORM_PACKAGE_LABEL="APP"
            PLATFORM_DIR="$IOS_DIR"
            # RID and device type selection: physical devices are always arm64;
            # simulators match the host architecture.
            if [ "$platform" = "ios-simulator" ]; then
                local arch
                arch="$(uname -m)"
                if [ "$arch" = "arm64" ] || [ "$arch" = "aarch64" ]; then
                    PLATFORM_RID="iossimulator-arm64"
                else
                    PLATFORM_RID="iossimulator-x64"
                fi
                PLATFORM_DEVICE_TYPE="ios-simulator"
            else
                PLATFORM_RID="ios-arm64"
                PLATFORM_DEVICE_TYPE="ios"
            fi
            ;;
        osx)
            PLATFORM_TFM="net11.0-macos"
            local arch
            arch="$(uname -m)"
            if [ "$arch" = "arm64" ] || [ "$arch" = "aarch64" ]; then
                PLATFORM_RID="osx-arm64"
            else
                PLATFORM_RID="osx-x64"
            fi
            PLATFORM_DEVICE_TYPE="osx"
            PLATFORM_SCENARIO_DIR="$SCENARIOS_DIR/genericmacosstartup"
            PLATFORM_PACKAGE_GLOB="*.app"
            PLATFORM_PACKAGE_LABEL="APP"
            PLATFORM_DIR="$OSX_DIR"
            ;;
        maccatalyst)
            PLATFORM_TFM="net11.0-maccatalyst"
            PLATFORM_RID="maccatalyst-arm64"
            PLATFORM_DEVICE_TYPE="maccatalyst"
            PLATFORM_SCENARIO_DIR="$SCENARIOS_DIR/genericmaccatalyststartup"
            PLATFORM_PACKAGE_GLOB="*.app"
            PLATFORM_PACKAGE_LABEL="APP"
            PLATFORM_DIR="$MACCATALYST_DIR"
            ;;
        *)
            echo "Error: Unknown platform '$platform'. Supported: android, android-emulator, ios, ios-simulator, osx, maccatalyst"
            return 1
            ;;
    esac
}
