#!/bin/bash

source "$(dirname "$0")/init.sh"

PLATFORM="android"

ITERATIONS=10
EXTRA_ARGS=()
SELECTED_APPS=()
COLLECT_TRACE_FLAG=""
CSPROJ_PATH=""
print_usage() {
    echo "Usage: $0 [options]"
    echo ""
    echo "Runs startup measurements for all (app, config) combinations."
    echo ""
    echo "Options:"
    echo "  --platform <name>          Target platform: android, android-emulator, ios, ios-simulator, osx, maccatalyst (default: android)"
    echo "  --app <name>               Measure only this app (can be repeated)"
    echo "  --csproj <path>            Path to external .csproj file (derives app name, overrides --app)"
    echo "  --startup-iterations N     Number of startup iterations per config (default: 10)"
    echo "  --collect-trace            Collect .nettrace EventPipe traces for each measurement"
    echo "  --help                     Show this help message"
    echo ""
    echo "Examples:"
    echo "  $0                                          # All apps, all configs, 10 iterations"
    echo "  $0 --platform ios                           # iOS platform, all configs"
    echo "  $0 --startup-iterations 3                   # All apps, all configs, 3 iterations"
    echo "  $0 --app dotnet-new-android                 # Only Android app, all configs"
    echo "  $0 --platform osx --collect-trace           # macOS, all configs, with traces"
    echo "  $0 --csproj /path/to/MyApp.csproj           # External app, all configs"
    exit 0
}

while [[ $# -gt 0 ]]; do
    case $1 in
        --platform)
            if [[ -z "$2" || "$2" == --* ]]; then
                echo "Error: --platform requires a value (android, android-emulator, ios, ios-simulator, osx, maccatalyst)"
                exit 1
            fi
            PLATFORM="$2"
            shift 2
            ;;
        --app)
            if [[ -z "$2" || "$2" == --* ]]; then
                echo "Error: --app requires a value"
                exit 1
            fi
            SELECTED_APPS+=("$2")
            shift 2
            ;;
        --csproj)
            if [[ -z "$2" || "$2" == --* ]]; then
                echo "Error: --csproj requires a path to a .csproj file"
                exit 1
            fi
            if [[ ! -f "$2" ]]; then
                echo "Error: .csproj file not found: $2"
                exit 1
            fi
            CSPROJ_PATH="$(cd "$(dirname "$2")" && pwd)/$(basename "$2")"
            shift 2
            ;;
        --startup-iterations)
            if [[ -z "$2" || "$2" == --* ]]; then
                echo "Error: --startup-iterations requires a numeric value"
                exit 1
            fi
            ITERATIONS="$2"
            shift 2
            ;;
        --collect-trace)
            COLLECT_TRACE_FLAG="--collect-trace"
            shift
            ;;
        --help)
            print_usage
            ;;
        *)
            EXTRA_ARGS+=("$1")
            shift
            ;;
    esac
done

# Resolve platform-specific configuration
resolve_platform_config "$PLATFORM" || exit 1
PLATFORM_DISPLAY="$(echo "$PLATFORM" | awk '{print toupper(substr($0,1,1)) substr($0,2)}')"

# Platform-specific build config lists
# Apple platforms (MachO) only support Composite R2R — no non-composite R2R config
case "$PLATFORM" in
    android|android-emulator)
        ALL_CONFIGS=("MONO_JIT" "MONO_AOT" "MONO_PAOT" "CORECLR_JIT" "R2R" "R2R_COMP" "R2R_COMP_PGO")
        ;;
    ios|ios-simulator|maccatalyst)
        ALL_CONFIGS=("MONO_JIT" "MONO_AOT" "MONO_PAOT" "CORECLR_JIT" "R2R_COMP" "R2R_COMP_PGO")
        ;;
    osx)
        # macOS only supports CoreCLR — Mono is not available
        ALL_CONFIGS=("CORECLR_JIT" "R2R_COMP" "R2R_COMP_PGO")
        ;;
esac

# Default app list per platform
case "$PLATFORM" in
    android|android-emulator)
        APPS=("dotnet-new-android" "dotnet-new-maui" "dotnet-new-maui-samplecontent")
        ;;
    ios|ios-simulator)
        APPS=("dotnet-new-ios" "dotnet-new-maui" "dotnet-new-maui-samplecontent")
        ;;
    osx)
        APPS=("dotnet-new-macos")
        ;;
    maccatalyst)
        APPS=("dotnet-new-maui" "dotnet-new-maui-samplecontent")
        ;;
esac

# When --csproj is provided, measure only the external app
if [ -n "$CSPROJ_PATH" ]; then
    CSPROJ_APP_NAME="$(basename "$CSPROJ_PATH" .csproj)"
    APPS=("$CSPROJ_APP_NAME")
fi

# Default to all apps if none selected
if [ ${#SELECTED_APPS[@]} -eq 0 ]; then
    SELECTED_APPS=("${APPS[@]}")
fi

# Build the list of (app, config) pairs
CONFIGS=()
for app in "${SELECTED_APPS[@]}"; do
    for config in "${ALL_CONFIGS[@]}"; do
        CONFIGS+=("$app|$config")
    done
done

TOTAL=${#CONFIGS[@]}
if [ "$TOTAL" -eq 0 ]; then
    echo "Error: No app/config combinations to measure for platform '$PLATFORM'."
    echo "Specify apps with --app or ensure the platform has a default app list."
    exit 1
fi
PASSED=0
FAILED=0
FAILURES=()

echo "=============================================="
echo " $PLATFORM_DISPLAY Startup Measurements"
echo " Configurations: $TOTAL"
echo " Iterations per config: $ITERATIONS"
echo "=============================================="
echo ""

mkdir -p "$RESULTS_DIR"
SUMMARY_FILE="$RESULTS_DIR/summary.csv"
echo "app,config,avg_ms,min_ms,max_ms,pkg_size_mb,pkg_size_bytes,build_time_ms,iterations" > "$SUMMARY_FILE"

CSPROJ_ARGS=()
if [ -n "$CSPROJ_PATH" ]; then
    CSPROJ_ARGS=(--csproj "$CSPROJ_PATH")
fi

for i in "${!CONFIGS[@]}"; do
    IFS='|' read -r app config <<< "${CONFIGS[$i]}"
    NUM=$((i + 1))

    echo "[$NUM/$TOTAL] $app | $config"
    echo "----------------------------------------------"

    if [ "$PLATFORM_DEVICE_TYPE" = "ios" ]; then
        OUTPUT=$("$SCRIPT_DIR/ios/measure_device_startup.sh" "$app" "$config" \
            --startup-iterations "$ITERATIONS" $COLLECT_TRACE_FLAG "${CSPROJ_ARGS[@]}" "${EXTRA_ARGS[@]}" 2>&1)
    elif [ "$PLATFORM_DEVICE_TYPE" = "ios-simulator" ]; then
        OUTPUT=$("$SCRIPT_DIR/ios/measure_simulator_startup.sh" "$app" "$config" \
            --startup-iterations "$ITERATIONS" $COLLECT_TRACE_FLAG "${CSPROJ_ARGS[@]}" "${EXTRA_ARGS[@]}" 2>&1)
    elif [ "$PLATFORM_DEVICE_TYPE" = "osx" ]; then
        OUTPUT=$("$SCRIPT_DIR/osx/measure_osx_startup.sh" "$app" "$config" \
            --startup-iterations "$ITERATIONS" $COLLECT_TRACE_FLAG "${CSPROJ_ARGS[@]}" "${EXTRA_ARGS[@]}" 2>&1)
    elif [ "$PLATFORM_DEVICE_TYPE" = "maccatalyst" ]; then
        OUTPUT=$("$SCRIPT_DIR/maccatalyst/measure_maccatalyst_startup.sh" "$app" "$config" \
            --startup-iterations "$ITERATIONS" $COLLECT_TRACE_FLAG "${CSPROJ_ARGS[@]}" "${EXTRA_ARGS[@]}" 2>&1)
    else
        OUTPUT=$("$SCRIPT_DIR/measure_startup.sh" "$app" "$config" \
            --platform "$PLATFORM" --startup-iterations "$ITERATIONS" "${CSPROJ_ARGS[@]}" "${EXTRA_ARGS[@]}" 2>&1)
    fi
    EXIT_CODE=$?

    if [ $EXIT_CODE -eq 0 ]; then
        # Parse results from Startup tool output
        AVG=$(echo "$OUTPUT" | grep "Generic Startup" | awk -F'|' '{print $2}' | sed 's/[^0-9.]//g')
        MIN=$(echo "$OUTPUT" | grep "Generic Startup" | awk -F'|' '{print $3}' | sed 's/[^0-9.]//g')
        MAX=$(echo "$OUTPUT" | grep "Generic Startup" | awk -F'|' '{print $4}' | sed 's/[^0-9.]//g')
        # Parse package size from measure_startup.sh output
        APK_SIZE_MB=$(echo "$OUTPUT" | grep "$PLATFORM_PACKAGE_LABEL size:" | sed -n "s/.*$PLATFORM_PACKAGE_LABEL size: \([0-9.]*\) MB.*/\1/p")
        APK_SIZE_BYTES=$(echo "$OUTPUT" | grep "$PLATFORM_PACKAGE_LABEL size:" | grep -o '([0-9]* bytes)' | sed 's/[()]//g; s/ bytes//')
        if [ -z "$APK_SIZE_MB" ]; then
            APK_SIZE_MB="unknown"
        fi

        # Parse build time from output
        BUILD_TIME=$(echo "$OUTPUT" | grep "Build time:" | sed -n 's/.*Build time: \([0-9.]*\) ms.*/\1/p' | tail -1)
        if [ -z "$BUILD_TIME" ]; then
            BUILD_TIME="N/A"
        fi

        if [ -z "$AVG" ] || [ -z "$MIN" ] || [ -z "$MAX" ]; then
            echo "⚠️  PARSE FAILED — could not extract startup times from output"
            echo "$OUTPUT" | tail -10
            FAILURES+=("$app|$config")
            FAILED=$((FAILED + 1))
        else
            echo "✅ avg=${AVG}ms  min=${MIN}ms  max=${MAX}ms  pkg=${APK_SIZE_MB}MB  build=${BUILD_TIME}ms"
            # Report trace file if collected
            TRACE_PATH=$(echo "$OUTPUT" | grep "Trace saved to:" | sed 's/.*Trace saved to: //')
            if [ -n "$TRACE_PATH" ]; then
                echo "   📊 Trace: $TRACE_PATH"
            fi
            echo "$app,$config,$AVG,$MIN,$MAX,$APK_SIZE_MB,$APK_SIZE_BYTES,$BUILD_TIME,$ITERATIONS" >> "$SUMMARY_FILE"
            PASSED=$((PASSED + 1))
        fi
    else
        echo "❌ FAILED"
        echo "$OUTPUT" | tail -5
        FAILURES+=("$app|$config")
        FAILED=$((FAILED + 1))
    fi
    echo ""
done

echo "=============================================="
echo " Summary"
echo "=============================================="
echo " Passed: $PASSED / $TOTAL"
if [ $FAILED -gt 0 ]; then
    echo " Failed: $FAILED"
    for f in "${FAILURES[@]}"; do
        IFS='|' read -r app config <<< "$f"
        echo "   - $app | $config"
    done
fi
echo ""
echo " Results: $SUMMARY_FILE"
echo ""

# Print the summary table
if [ -f "$SUMMARY_FILE" ]; then
    echo "App                          | Config         | Avg (ms) | Min (ms) | Max (ms) | Build (ms) | $PLATFORM_PACKAGE_LABEL (MB)"
    echo "-----------------------------|----------------|----------|----------|----------|------------|--------"
    tail -n +2 "$SUMMARY_FILE" | while IFS=',' read -r app config avg min max pkg_mb pkg_bytes build_time iters; do
        printf "%-28s | %-14s | %8s | %8s | %8s | %10s | %8s\n" "$app" "$config" "$avg" "$min" "$max" "$build_time" "$pkg_mb"
    done
fi

exit $FAILED
