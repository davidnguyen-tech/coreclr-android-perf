#!/bin/bash

# Generates sample apps using 'dotnet new' templates and applies
# post-generation patches for profiling/PGO support.

source "$(dirname "$0")/init.sh"

if [ ! -f "$LOCAL_DOTNET" ]; then
    echo "Error: $LOCAL_DOTNET does not exist. Please run ./prepare.sh first."
    exit 1
fi

APPS_DIR="$SCRIPT_DIR/apps"

# Parse --platform parameter (default: android for backward compatibility)
PLATFORM="android"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --platform)
            if [[ -z "$2" || "$2" == --* ]]; then
                echo "Error: --platform requires a value (android, android-emulator, ios, ios-simulator, osx, maccatalyst)"
                exit 1
            fi
            PLATFORM="$2"
            shift 2
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

resolve_platform_config "$PLATFORM" || exit 1

generate_app() {
    local template=$1
    local app_name=$2
    local extra_args=$3

    local app_dir="$APPS_DIR/$app_name"

    # Guard: app name must not look like a framework assembly (e.g. Microsoft.*, System.*, Mono.*)
    # to avoid collisions with --include-reference filters used in R2R/PGO compilation.
    local assembly_name
    assembly_name=$(echo "$app_name" | tr '-' '_')
    for prefix in Microsoft. System. Mono. Xamarin.; do
        if [[ "$assembly_name" == ${prefix}* ]]; then
            echo "Error: App name '$app_name' produces assembly name '$assembly_name' which starts with '$prefix'."
            echo "This would collide with framework assembly filters used in R2R compilation."
            exit 1
        fi
    done

    if [ -d "$app_dir" ]; then
        echo "App $app_name already exists at $app_dir. Skipping generation."
        return 0
    fi

    echo "Generating $app_name using template '$template'..."
    local restore_flag=""
    if [ "$template" = "maui" ]; then
        restore_flag="--no-restore"
    fi
    ${LOCAL_DOTNET} new "$template" -n "$app_name" -o "$app_dir" $extra_args --force $restore_flag
    if [ $? -ne 0 ]; then
        echo "Error: Failed to generate $app_name"
        exit 1
    fi

    # Patch TFM to match the build system's PLATFORM_TFM.
    # Template apps (ios, android, macos) generate csprojs with the SDK's default
    # TFM (e.g. net10.0-ios) which may not match PLATFORM_TFM (e.g. net11.0-ios).
    # MAUI apps have their own multi-TFM patching below, so skip them here.
    local csproj="$app_dir/$app_name.csproj"
    if [ "$template" != "maui" ] && [ -f "$csproj" ]; then
        sed -i '' "s|<TargetFramework>[^<]*</TargetFramework>|<TargetFramework>$PLATFORM_TFM</TargetFramework>|" "$csproj"
        echo "Patched $app_name TFM to $PLATFORM_TFM"
    fi

    # For MAUI apps, restrict TargetFrameworks to the selected platform only
    if [ "$template" = "maui" ] && [ -f "$csproj" ]; then
        python3 - "$csproj" "$PLATFORM_TFM" << 'TFMEOF'
import sys, re
csproj = sys.argv[1]
platform_tfm = sys.argv[2]
content = open(csproj).read()
# Replace all TargetFrameworks lines with a single platform-specific line
content = re.sub(
    r'<TargetFrameworks[^>]*>.*?</TargetFrameworks>\s*\n\s*',
    '',
    content,
    flags=re.DOTALL
)
# Insert single TargetFrameworks after the opening <PropertyGroup>
content = content.replace(
    '<PropertyGroup>\n',
    '<PropertyGroup>\n\t\t<TargetFrameworks>' + platform_tfm + '</TargetFrameworks>\n',
    1
)
open(csproj, 'w').write(content)
TFMEOF
        echo "Restricted $app_name to $PLATFORM_TFM TFM"
    fi

    # Apply profiling patches
    patch_app "$app_dir" "$app_name"
}

patch_app() {
    local app_dir=$1
    local app_name=$2
    local csproj="$app_dir/$app_name.csproj"

    if [ ! -f "$csproj" ]; then
        echo "Warning: Could not find $csproj for patching"
        return 1
    fi

    # Create profiles directory and copy shared PGO profiles
    mkdir -p "$app_dir/profiles"
    if [ -d "$SCRIPT_DIR/profiles" ]; then
        cp "$SCRIPT_DIR/profiles"/*.mibc "$app_dir/profiles/" 2>/dev/null
    fi

    # Inject profiling and PGO support before the closing </Project> tag
    local is_maui="false"
    if grep -q "Maui" "$csproj" 2>/dev/null; then
        is_maui="true"
    fi

    python3 - "$csproj" "$is_maui" "$PLATFORM" << 'PYEOF'
import sys

csproj = sys.argv[1]
is_maui = sys.argv[2] == "true"
platform = sys.argv[3]

patch = ""

# Android-specific profiling support (AndroidEnvironment items)
if platform in ("android", "android-emulator"):
    patch += """
  <!-- Profiling support -->
  <ItemGroup Condition="'$(AndroidEnableProfiler)'=='true'">
    <AndroidEnvironment Include="$(MSBuildThisFileDirectory)../../android/env.txt" />
  </ItemGroup>

  <!-- PGO instrumentation for .nettrace collection -->
  <ItemGroup Condition="'$(CollectNetTrace)'=='true'">
    <AndroidEnvironment Include="$(MSBuildThisFileDirectory)../../android/env-nettrace.txt" />
  </ItemGroup>
"""

if is_maui:
    # MAUI Controls already sets --partial and includes default MIBC profiles
    # via _MauiPublishReadyToRunPartial and _MauiUseDefaultReadyToRunPgoFiles.
    # Override the default profiles with our own.
    patch += """
  <!-- Use our own PGO profiles instead of MAUI defaults for R2R Composite PGO builds -->
  <PropertyGroup Condition="'$(PublishReadyToRun)' == 'true' and '$(PublishReadyToRunComposite)' == 'true' and '$(PGO)' == 'true'">
    <_MauiUseDefaultReadyToRunPgoFiles>false</_MauiUseDefaultReadyToRunPgoFiles>
  </PropertyGroup>
  <ItemGroup Condition="'$(PublishReadyToRun)' == 'true' and '$(PublishReadyToRunComposite)' == 'true' and '$(PGO)' == 'true'">
    <_ReadyToRunPgoFiles Include="$(MSBuildThisFileDirectory)profiles/*.mibc" />
  </ItemGroup>
"""
else:
    # Non-MAUI apps: set --partial and MIBC profiles ourselves
    patch += """
  <!-- PGO profile support for R2R Composite builds -->
  <ItemGroup Condition="'$(PublishReadyToRun)' == 'true' and '$(PublishReadyToRunComposite)' == 'true' and '$(PGO)' == 'true'">
    <_ReadyToRunPgoFiles Include="$(MSBuildThisFileDirectory)profiles/*.mibc" />
  </ItemGroup>
  <PropertyGroup Condition="'$(PublishReadyToRun)' == 'true' and '$(PublishReadyToRunComposite)' == 'true' and '$(PGO)' == 'true'">
    <PublishReadyToRunCrossgen2ExtraArgs>--partial</PublishReadyToRunCrossgen2ExtraArgs>
  </PropertyGroup>
"""

content = open(csproj).read()
content = content.replace('</Project>', patch + '</Project>')
open(csproj, 'w').write(content)
PYEOF

    echo "Applied profiling/PGO patches to $csproj"
}

# Generate sample apps for the selected platform
echo "=== Generating sample apps for $PLATFORM ==="

case "$PLATFORM" in
    android|android-emulator)
        generate_app "android" "dotnet-new-android"
        ;;
    ios|ios-simulator)
        generate_app "ios" "dotnet-new-ios"
        ;;
    osx)
        generate_app "macos" "dotnet-new-macos"
        ;;
    maccatalyst)
        # No standalone template — MAUI only
        ;;
esac

# MAUI apps work for all platforms except osx (MAUI requires maccatalyst, not macos)
if [ "$PLATFORM" != "osx" ]; then
    generate_app "maui" "dotnet-new-maui"
    generate_app "maui" "dotnet-new-maui-samplecontent" "--sample-content"
fi

echo "=== Sample app generation complete for $PLATFORM ==="
echo "Apps generated in: $APPS_DIR"
