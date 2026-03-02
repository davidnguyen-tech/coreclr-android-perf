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

    if [ -d "$app_dir" ]; then
        echo "App $app_name already exists at $app_dir. Skipping generation."
        return 0
    fi

    echo "Generating $app_name using template '$template'..."
    ${LOCAL_DOTNET} new "$template" -n "$app_name" -o "$app_dir" $extra_args --force
    if [ $? -ne 0 ]; then
        echo "Error: Failed to generate $app_name"
        exit 1
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
    python3 - "$csproj" << 'PYEOF'
import sys

csproj = sys.argv[1]
patch = """
  <!-- Profiling support -->
  <ItemGroup Condition="'$(AndroidEnableProfiler)'=='true'">
    <AndroidEnvironment Include="$(MSBuildThisFileDirectory)..\\..\\env.txt" />
  </ItemGroup>

  <!-- PGO profile support for R2R Composite builds -->
  <ItemGroup Condition="'$(PublishReadyToRun)' == 'true' and '$(PublishReadyToRunComposite)' == 'true' and '$(PGO)' == 'true'">
    <_ReadyToRunPgoFiles Include="$(MSBuildThisFileDirectory)\\profiles\\*.mibc" />
  </ItemGroup>
  <PropertyGroup Condition="'$(PublishReadyToRun)' == 'true' and '$(PublishReadyToRunComposite)' == 'true' and '$(PGO)' == 'true'">
    <PublishReadyToRunCrossgen2ExtraArgs>--partial</PublishReadyToRunCrossgen2ExtraArgs>
  </PropertyGroup>
"""
content = open(csproj).read()
if patch.strip() in content:
    sys.exit(0)
content = content.replace('</Project>', patch + '</Project>')
open(csproj, 'w').write(content)
PYEOF

    echo "Applied profiling/PGO patches to $csproj"
}

# Generate all sample apps
echo "=== Generating sample apps ==="

generate_app "android" "dotnet-new-android"
generate_app "maui" "dotnet-new-maui"
generate_app "maui" "dotnet-new-maui-samplecontent" "--sample-content"

echo "=== Sample app generation complete ==="
echo "Apps generated in: $APPS_DIR"
