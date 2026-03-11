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
PLATFORM_FILE="$SCRIPT_DIR/.platform"

# Local runtime state (set by configure_local_runtime)
LOCAL_RUNTIME_ACTIVE=false
LOCAL_RUNTIME_SHIPPING_PATH=""
LOCAL_RUNTIME_VERSION=""
LOCAL_RUNTIME_CROSSGEN2_PATH=""

# Read the platform saved by prepare.sh, or return empty string if not set.
read_prepared_platform() {
    if [ -f "$PLATFORM_FILE" ]; then
        cat "$PLATFORM_FILE"
    else
        echo ""
    fi
}

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
            PLATFORM_DEVICE_TYPE="ios"
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

# Configure local runtime build for use in app builds.
# Usage: configure_local_runtime <runtime-repo-path> <platform-rid> [config]
# Sets: LOCAL_RUNTIME_ACTIVE, LOCAL_RUNTIME_SHIPPING_PATH, LOCAL_RUNTIME_VERSION, LOCAL_RUNTIME_CROSSGEN2_PATH
configure_local_runtime() {
    local runtime_path="$1"
    local platform_rid="$2"
    local config="${3:-Release}"

    if [ ! -d "$runtime_path" ]; then
        echo "Error: Runtime repo path does not exist: $runtime_path"
        return 1
    fi

    LOCAL_RUNTIME_SHIPPING_PATH="$runtime_path/artifacts/packages/$config/Shipping"
    if [ ! -d "$LOCAL_RUNTIME_SHIPPING_PATH" ]; then
        echo "Error: Shipping packages not found at $LOCAL_RUNTIME_SHIPPING_PATH"
        echo "Build the runtime first with: ./build.sh -s clr+libs+packs+host -c $config"
        return 1
    fi

    # Auto-detect version from shipping package filenames
    local version=""
    local ref_pkg
    ref_pkg=$(ls "$LOCAL_RUNTIME_SHIPPING_PATH"/Microsoft.NETCore.App.Ref.*.nupkg 2>/dev/null | head -1)
    if [ -n "$ref_pkg" ]; then
        version=$(basename "$ref_pkg" | sed 's/Microsoft\.NETCore\.App\.Ref\.\(.*\)\.nupkg/\1/')
    fi
    if [ -z "$version" ]; then
        echo "Error: Could not detect runtime version from packages in $LOCAL_RUNTIME_SHIPPING_PATH"
        echo "Expected to find Microsoft.NETCore.App.Ref.*.nupkg"
        return 1
    fi

    # Derive crossgen2 path from RID: e.g. ios-arm64 → ios.arm64.Release/arm64/crossgen2/crossgen2
    local rid_os="${platform_rid%%-*}"    # ios, android
    local rid_arch="${platform_rid##*-}"  # arm64
    LOCAL_RUNTIME_CROSSGEN2_PATH="$runtime_path/artifacts/bin/coreclr/$rid_os.$rid_arch.$config/$rid_arch/crossgen2/crossgen2"
    if [ ! -f "$LOCAL_RUNTIME_CROSSGEN2_PATH" ]; then
        echo "Error: crossgen2 not found at $LOCAL_RUNTIME_CROSSGEN2_PATH"
        echo "Build the runtime first with: ./build.sh -s clr+libs+packs+host -c $config"
        return 1
    fi

    LOCAL_RUNTIME_ACTIVE=true
    LOCAL_RUNTIME_VERSION="$version"

    echo "Local runtime: $LOCAL_RUNTIME_SHIPPING_PATH (version: $version)"
    if [ -n "$LOCAL_RUNTIME_CROSSGEN2_PATH" ]; then
        echo "Local crossgen2: $LOCAL_RUNTIME_CROSSGEN2_PATH"
    fi
}

# Generate a per-app NuGet.config that includes the local runtime shipping path
# alongside all existing package sources from the root NuGet.config.
# Usage: generate_local_nuget_config <app-dir>
# Requires: LOCAL_RUNTIME_SHIPPING_PATH to be set (via configure_local_runtime)
generate_local_nuget_config() {
    local app_dir="$1"

    if [ -z "$LOCAL_RUNTIME_SHIPPING_PATH" ]; then
        echo "Error: LOCAL_RUNTIME_SHIPPING_PATH not set. Call configure_local_runtime first."
        return 1
    fi

    cat > "$app_dir/NuGet.config" << EOF
<?xml version="1.0" encoding="utf-8"?>
<configuration>
  <packageSources>
    <add key="local-runtime" value="$LOCAL_RUNTIME_SHIPPING_PATH" />
  </packageSources>
</configuration>
EOF

    echo "Generated $app_dir/NuGet.config with local runtime source"
}

# Generate a per-app Directory.Build.props that imports the root props,
# pins RuntimeFrameworkVersion, and sets Crossgen2Path for the local runtime build.
# Usage: generate_local_build_props <app-dir>
# Requires: LOCAL_RUNTIME_VERSION to be set (via configure_local_runtime)
generate_local_build_props() {
    local app_dir="$1"

    if [ -z "$LOCAL_RUNTIME_VERSION" ]; then
        echo "Error: LOCAL_RUNTIME_VERSION not set. Call configure_local_runtime first."
        return 1
    fi

    local crossgen2_prop=""
    if [ -n "$LOCAL_RUNTIME_CROSSGEN2_PATH" ]; then
        crossgen2_prop="    <Crossgen2Path>$LOCAL_RUNTIME_CROSSGEN2_PATH</Crossgen2Path>"
    fi

    cat > "$app_dir/Directory.Build.props" << EOF
<Project>
  <!-- Import the root Directory.Build.props -->
  <Import Project="\$([MSBuild]::GetPathOfFileAbove('Directory.Build.props', '\$(MSBuildThisFileDirectory)../'))" />

  <!-- Pin runtime framework version to the local build -->
  <PropertyGroup>
$crossgen2_prop
  </PropertyGroup>
  <ItemGroup>
    <KnownFrameworkReference Update="Microsoft.NETCore.App"
                             DefaultRuntimeFrameworkVersion="$LOCAL_RUNTIME_VERSION"
                             LatestRuntimeFrameworkVersion="$LOCAL_RUNTIME_VERSION"
                             TargetingPackVersion="$LOCAL_RUNTIME_VERSION" />
  </ItemGroup>
</Project>
EOF

    echo "Generated $app_dir/Directory.Build.props (RuntimeFrameworkVersion=$LOCAL_RUNTIME_VERSION)"
}
