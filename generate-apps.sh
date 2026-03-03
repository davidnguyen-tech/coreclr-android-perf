#!/bin/bash

# Generates sample apps using 'dotnet new' templates and applies
# post-generation patches for profiling/PGO support.

source "$(dirname "$0")/init.sh"

if [ ! -f "$LOCAL_DOTNET" ]; then
    echo "Error: $LOCAL_DOTNET does not exist. Please run ./prepare.sh first."
    exit 1
fi

# Parse --platform flag (default: generate all)
GEN_ANDROID=true
GEN_IOS=true
while [[ $# -gt 0 ]]; do
    case "$1" in
        --platform)
            case "$2" in
                android) GEN_ANDROID=true; GEN_IOS=false ;;
                ios) GEN_ANDROID=false; GEN_IOS=true ;;
                *) echo "Error: Unknown platform '$2'"; exit 1 ;;
            esac
            shift 2
            ;;
        *) shift ;;
    esac
done

APPS_DIR="$SCRIPT_DIR/apps"

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

    # For iOS template apps, update TFM to match SDK version (template may default to older TFM)
    local csproj="$app_dir/$app_name.csproj"
    if [ "$template" = "ios" ] && [ -f "$csproj" ]; then
        sed -i '' 's|<TargetFramework>net[0-9]*\.[0-9]*-ios</TargetFramework>|<TargetFramework>net11.0-ios</TargetFramework>|' "$csproj"
        echo "Updated $app_name TFM to net11.0-ios"
    fi

    # For MAUI apps, set TargetFrameworks based on selected platforms
    local csproj="$app_dir/$app_name.csproj"
    if [ "$template" = "maui" ] && [ -f "$csproj" ]; then
        local maui_tfms=""
        if [ "$GEN_ANDROID" = true ]; then maui_tfms="net11.0-android"; fi
        if [ "$GEN_IOS" = true ]; then
            if [ -n "$maui_tfms" ]; then maui_tfms="$maui_tfms;"; fi
            maui_tfms="${maui_tfms}net11.0-ios"
        fi
        python3 - "$csproj" "$maui_tfms" << 'TFMEOF'
import sys, re
csproj = sys.argv[1]
tfms = sys.argv[2]
content = open(csproj).read()
content = re.sub(
    r'<TargetFrameworks[^>]*>.*?</TargetFrameworks>\s*\n\s*',
    '',
    content,
    flags=re.DOTALL
)
content = content.replace(
    '<PropertyGroup>\n',
    f'<PropertyGroup>\n\t\t<TargetFrameworks>{tfms}</TargetFrameworks>\n',
    1
)
open(csproj, 'w').write(content)
TFMEOF
        echo "Set $app_name TargetFrameworks to $maui_tfms"
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

    python3 - "$csproj" "$is_maui" << 'PYEOF'
import sys

csproj = sys.argv[1]
is_maui = sys.argv[2] == "true"

patch = """
  <!-- Profiling support (Android only) -->
  <ItemGroup Condition="'$(AndroidEnableProfiler)'=='true' and '$(TargetPlatformIdentifier)'=='android'">
    <AndroidEnvironment Include="$(MSBuildThisFileDirectory)../../android/env.txt" />
  </ItemGroup>

  <!-- PGO instrumentation for .nettrace collection (Android only) -->
  <ItemGroup Condition="'$(CollectNetTrace)'=='true' and '$(TargetPlatformIdentifier)'=='android'">
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

# Generate sample apps based on selected platforms
echo "=== Generating sample apps ==="

if [ "$GEN_ANDROID" = true ]; then
    generate_app "android" "dotnet-new-android"
fi
if [ "$GEN_IOS" = true ]; then
    generate_app "ios" "dotnet-new-ios"
fi
generate_app "maui" "dotnet-new-maui"
generate_app "maui" "dotnet-new-maui-samplecontent" "--sample-content"

echo "=== Sample app generation complete ==="
echo "Apps generated in: $APPS_DIR"
