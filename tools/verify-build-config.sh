#!/bin/bash
# =============================================================================
# tools/verify-build-config.sh — Verify MSBuild property values for all build
# configurations without building full packages.
#
# Evaluates each (platform, config) combination using 'dotnet build --getProperty'
# and compares against expected values. Catches configuration regressions like
# R2R_COMP_PGO missing --partial.
#
# Prerequisites:
#   - ./prepare.sh has been run (apps/ directory exists with generated projects)
#
# Usage:
#   ./tools/verify-build-config.sh                        # all platforms
#   ./tools/verify-build-config.sh --platform android     # single platform
#   ./tools/verify-build-config.sh --platform ios
#   ./tools/verify-build-config.sh --platform osx
#   ./tools/verify-build-config.sh --platform maccatalyst
#
# Exit code: 0 when all checks pass, 1 on any failure.
# =============================================================================

set -euo pipefail

source "$(dirname "$0")/../init.sh"

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
PLATFORM=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --platform)
            if [[ -z "${2:-}" || "$2" == --* ]]; then
                echo "Error: --platform requires a value (android, ios, osx, maccatalyst)"
                exit 1
            fi
            PLATFORM="$2"
            shift 2
            ;;
        --platform=*)
            PLATFORM="${1#*=}"
            shift
            ;;
        -h|--help)
            echo "Usage: $0 [--platform <android|ios|osx|maccatalyst>]"
            echo ""
            echo "Verify MSBuild property values for all build configurations."
            echo "If --platform is not specified, all platforms are checked."
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

# ---------------------------------------------------------------------------
# Validate prerequisites
# ---------------------------------------------------------------------------
if [ ! -f "$LOCAL_DOTNET" ]; then
    echo "Error: $LOCAL_DOTNET does not exist. Please run ./prepare.sh first."
    exit 1
fi

if [ ! -d "$APPS_DIR" ]; then
    echo "Error: $APPS_DIR does not exist. Please run ./prepare.sh and ./generate-apps.sh first."
    exit 1
fi

# ---------------------------------------------------------------------------
# Configuration: platforms, configs, and preferred app per platform
# ---------------------------------------------------------------------------

# Preferred app name per platform (first match wins).
# Falls back to dotnet-new-maui if the platform-specific app doesn't exist.
get_app_for_platform() {
    local platform="$1"
    local candidates=()

    case "$platform" in
        android)      candidates=("dotnet-new-android" "dotnet-new-maui") ;;
        ios)          candidates=("dotnet-new-ios" "dotnet-new-maui") ;;
        osx)          candidates=("dotnet-new-macos") ;;
        maccatalyst)  candidates=("dotnet-new-maui") ;;
    esac

    for app in "${candidates[@]}"; do
        local csproj="$APPS_DIR/$app/$app.csproj"
        if [ -f "$csproj" ]; then
            echo "$app"
            return 0
        fi
    done

    return 1
}

# Configs available per platform (derived from the build-configs.props files)
get_configs_for_platform() {
    local platform="$1"
    case "$platform" in
        android)      echo "MONO_JIT MONO_AOT MONO_PAOT CORECLR_JIT R2R R2R_COMP R2R_COMP_PGO" ;;
        ios)          echo "MONO_JIT MONO_AOT MONO_PAOT CORECLR_JIT R2R_COMP R2R_COMP_PGO" ;;
        osx)          echo "CORECLR_JIT R2R_COMP R2R_COMP_PGO" ;;
        maccatalyst)  echo "MONO_JIT MONO_AOT MONO_PAOT CORECLR_JIT R2R_COMP R2R_COMP_PGO" ;;
    esac
}

# Properties we evaluate for every config
PROPERTIES=(
    UseMonoRuntime
    RunAOTCompilation
    PublishReadyToRun
    PublishReadyToRunComposite
    PublishReadyToRunCrossgen2ExtraArgs
    _MauiPublishReadyToRunPartial
    PGO
)

# ---------------------------------------------------------------------------
# Expected values table
#
# Format: expect_<CONFIG>_<PropertyName>="value"
#   - "True" / "False" / "" for exact match (case-insensitive)
#   - "*" means any value is acceptable (skip check)
#   - "contains:TEXT" means the value must contain TEXT
#   - "!contains:TEXT" means the value must NOT contain TEXT
# ---------------------------------------------------------------------------

# --- MONO_JIT ---
expect_MONO_JIT_UseMonoRuntime="True"
expect_MONO_JIT_RunAOTCompilation="False"
expect_MONO_JIT_PublishReadyToRun="False"
expect_MONO_JIT_PublishReadyToRunComposite="False"
expect_MONO_JIT_PublishReadyToRunCrossgen2ExtraArgs=""
expect_MONO_JIT_PGO=""

# --- MONO_AOT ---
expect_MONO_AOT_UseMonoRuntime="True"
expect_MONO_AOT_RunAOTCompilation="True"
expect_MONO_AOT_PublishReadyToRun="*"
expect_MONO_AOT_PublishReadyToRunComposite="*"
expect_MONO_AOT_PublishReadyToRunCrossgen2ExtraArgs="*"
expect_MONO_AOT_PGO="*"

# --- MONO_PAOT ---
expect_MONO_PAOT_UseMonoRuntime="True"
expect_MONO_PAOT_RunAOTCompilation="True"
expect_MONO_PAOT_PublishReadyToRun="*"
expect_MONO_PAOT_PublishReadyToRunComposite="*"
expect_MONO_PAOT_PublishReadyToRunCrossgen2ExtraArgs="*"
expect_MONO_PAOT_PGO="*"

# --- CORECLR_JIT ---
expect_CORECLR_JIT_UseMonoRuntime="False"
expect_CORECLR_JIT_RunAOTCompilation="False"
expect_CORECLR_JIT_PublishReadyToRun="False"
expect_CORECLR_JIT_PublishReadyToRunComposite="False"
expect_CORECLR_JIT_PublishReadyToRunCrossgen2ExtraArgs=""
expect_CORECLR_JIT_PGO=""

# --- R2R (android only) ---
expect_R2R_UseMonoRuntime="False"
expect_R2R_RunAOTCompilation="*"
expect_R2R_PublishReadyToRun="True"
expect_R2R_PublishReadyToRunComposite="False"
expect_R2R_PublishReadyToRunCrossgen2ExtraArgs=""
expect_R2R_PGO=""

# --- R2R_COMP ---
expect_R2R_COMP_UseMonoRuntime="False"
expect_R2R_COMP_RunAOTCompilation="*"
expect_R2R_COMP_PublishReadyToRun="True"
expect_R2R_COMP_PublishReadyToRunComposite="True"
expect_R2R_COMP_PublishReadyToRunCrossgen2ExtraArgs="!contains:--partial"
expect_R2R_COMP_PGO=""

# --- R2R_COMP_PGO ---
expect_R2R_COMP_PGO_UseMonoRuntime="False"
expect_R2R_COMP_PGO_RunAOTCompilation="*"
expect_R2R_COMP_PGO_PublishReadyToRun="True"
expect_R2R_COMP_PGO_PublishReadyToRunComposite="True"
expect_R2R_COMP_PGO_PublishReadyToRunCrossgen2ExtraArgs="contains:--partial"
expect_R2R_COMP_PGO_PGO="True"

# _MauiPublishReadyToRunPartial is always "*" (skip) — it varies by app type
# and is only meaningful to MAUI internals, not a correctness signal for us.

# ---------------------------------------------------------------------------
# Evaluation helpers
# ---------------------------------------------------------------------------

TOTAL_PASS=0
TOTAL_FAIL=0
TOTAL_SKIP=0

# Evaluate all properties for a given (platform, config, app) combination.
# Uses 'dotnet build --getProperty' which performs property evaluation only (no compile).
evaluate_properties() {
    local app_name="$1"
    local config="$2"
    local tfm="$3"
    local rid="$4"

    local csproj="$APPS_DIR/$app_name/$app_name.csproj"

    # Build the --getProperty flags
    local get_args=()
    for prop in "${PROPERTIES[@]}"; do
        get_args+=("--getProperty:$prop")
    done

    local output
    if ! output=$("$LOCAL_DOTNET" build "$csproj" \
        "${get_args[@]}" \
        -p:_BuildConfig="$config" \
        -c Release \
        -f "$tfm" \
        -r "$rid" \
        --no-restore 2>&1); then
        echo "  [FAIL] $config: MSBuild evaluation failed"
        echo "         Output: $output"
        TOTAL_FAIL=$((TOTAL_FAIL + 1))
        return 1
    fi

    # Parse JSON output: extract property values
    # Format: { "Properties": { "Name": "Value", ... } }
    for prop in "${PROPERTIES[@]}"; do
        local actual
        actual=$(echo "$output" | python3 -c "
import sys, json
data = json.load(sys.stdin)
print(data.get('Properties', {}).get('$prop', ''))
" 2>/dev/null) || actual=""

        check_property "$config" "$prop" "$actual"
    done
}

# Check a single property value against the expected value.
check_property() {
    local config="$1"
    local prop="$2"
    local actual="$3"

    # Look up expected value via variable indirection
    local var_name="expect_${config}_${prop}"
    local expected="${!var_name:-*}"

    # Skip if expected is "*" (any value acceptable)
    if [ "$expected" = "*" ]; then
        TOTAL_SKIP=$((TOTAL_SKIP + 1))
        return 0
    fi

    # Handle "contains:" check
    if [[ "$expected" == contains:* ]]; then
        local needle="${expected#contains:}"
        if [[ "$actual" == *"$needle"* ]]; then
            echo "  [PASS] $config: $prop contains '$needle' ✓  (value='$actual')"
            TOTAL_PASS=$((TOTAL_PASS + 1))
        else
            echo "  [FAIL] $config: $prop='$actual' (expected to contain '$needle')"
            TOTAL_FAIL=$((TOTAL_FAIL + 1))
        fi
        return 0
    fi

    # Handle "!contains:" check
    if [[ "$expected" == '!contains:'* ]]; then
        local needle="${expected#!contains:}"
        if [[ "$actual" == *"$needle"* ]]; then
            echo "  [FAIL] $config: $prop='$actual' (must NOT contain '$needle')"
            TOTAL_FAIL=$((TOTAL_FAIL + 1))
        else
            echo "  [PASS] $config: $prop does not contain '$needle' ✓  (value='$actual')"
            TOTAL_PASS=$((TOTAL_PASS + 1))
        fi
        return 0
    fi

    # Exact match (case-insensitive)
    local actual_lower
    local expected_lower
    actual_lower=$(echo "$actual" | tr '[:upper:]' '[:lower:]')
    expected_lower=$(echo "$expected" | tr '[:upper:]' '[:lower:]')

    if [ "$actual_lower" = "$expected_lower" ]; then
        echo "  [PASS] $config: $prop=$actual ✓"
        TOTAL_PASS=$((TOTAL_PASS + 1))
    else
        echo "  [FAIL] $config: $prop='$actual' (expected '$expected')"
        TOTAL_FAIL=$((TOTAL_FAIL + 1))
    fi
}

# ---------------------------------------------------------------------------
# Main: iterate platforms and configs
# ---------------------------------------------------------------------------

PLATFORMS_TO_CHECK=()
if [ -n "$PLATFORM" ]; then
    PLATFORMS_TO_CHECK=("$PLATFORM")
else
    PLATFORMS_TO_CHECK=("android" "ios" "osx" "maccatalyst")
fi

for platform in "${PLATFORMS_TO_CHECK[@]}"; do
    resolve_platform_config "$platform" || {
        echo "Error: Failed to resolve platform config for '$platform'"
        exit 1
    }

    echo ""
    echo "=== ${platform} (TFM=${PLATFORM_TFM}, RID=${PLATFORM_RID}) ==="

    app_name=$(get_app_for_platform "$platform") || {
        echo "  WARNING: No generated app found for $platform. Run ./generate-apps.sh --platform $platform first. Skipping."
        continue
    }

    echo "  Using app: $app_name"
    echo ""

    configs=$(get_configs_for_platform "$platform")
    for config in $configs; do
        evaluate_properties "$app_name" "$config" "$PLATFORM_TFM" "$PLATFORM_RID"
    done
done

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "=== Summary ==="
echo "  Passed:  $TOTAL_PASS"
echo "  Failed:  $TOTAL_FAIL"
echo "  Skipped: $TOTAL_SKIP"

if [ "$TOTAL_FAIL" -gt 0 ]; then
    echo ""
    echo "RESULT: FAIL ($TOTAL_FAIL failures detected)"
    exit 1
else
    echo ""
    echo "RESULT: PASS (all checks passed)"
    exit 0
fi
