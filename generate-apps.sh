#!/bin/bash

# Generates sample apps using 'dotnet new' templates and applies
# post-generation patches for profiling/PGO support.

source "$(dirname "$0")/init.sh"

if [ ! -f "$LOCAL_DOTNET" ]; then
    echo "Error: $LOCAL_DOTNET does not exist. Please run ./prepare.sh first."
    exit 1
fi

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

    # For MAUI apps, set TargetFrameworks to Android+iOS
    local csproj="$app_dir/$app_name.csproj"
    if [ "$template" = "maui" ] && [ -f "$csproj" ]; then
        python3 - "$csproj" << 'TFMEOF'
import sys, re
csproj = sys.argv[1]
content = open(csproj).read()
content = re.sub(
    r'<TargetFrameworks[^>]*>.*?</TargetFrameworks>\s*\n\s*',
    '',
    content,
    flags=re.DOTALL
)
content = content.replace(
    '<PropertyGroup>\n',
    '<PropertyGroup>\n\t\t<TargetFrameworks>net11.0-android;net11.0-ios</TargetFrameworks>\n',
    1
)
open(csproj, 'w').write(content)
TFMEOF
        echo "Set $app_name to Android+iOS TFMs"
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

# Generate all sample apps
echo "=== Generating sample apps ==="

generate_app "android" "dotnet-new-android"
generate_app "ios" "dotnet-new-ios"
generate_app "maui" "dotnet-new-maui"
generate_app "maui" "dotnet-new-maui-samplecontent" "--sample-content"

echo "=== Sample app generation complete ==="
echo "Apps generated in: $APPS_DIR"
