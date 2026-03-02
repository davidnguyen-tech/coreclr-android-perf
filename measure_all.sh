#!/bin/bash

source "$(dirname "$0")/init.sh"

ALL_CONFIGS=("MONO_JIT" "AOT" "PAOT" "CORECLR_JIT" "R2R" "R2R_COMP" "R2R_COMP_PGO")
APPS=("dotnet-new-android" "dotnet-new-maui" "dotnet-new-maui-samplecontent")

ITERATIONS=10
EXTRA_ARGS=()
SELECTED_APPS=()

print_usage() {
    echo "Usage: $0 [options]"
    echo ""
    echo "Runs startup measurements for all (app, config) combinations."
    echo ""
    echo "Options:"
    echo "  --app <name>               Measure only this app (can be repeated)"
    echo "  --startup-iterations N     Number of startup iterations per config (default: 10)"
    echo "  --help                     Show this help message"
    echo ""
    echo "Examples:"
    echo "  $0                                          # All apps, all configs, 10 iterations"
    echo "  $0 --startup-iterations 3                   # All apps, all configs, 3 iterations"
    echo "  $0 --app dotnet-new-android                 # Only Android app, all configs"
    exit 0
}

while [[ $# -gt 0 ]]; do
    case $1 in
        --app)
            SELECTED_APPS+=("$2")
            shift 2
            ;;
        --startup-iterations)
            ITERATIONS="$2"
            shift 2
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
PASSED=0
FAILED=0
FAILURES=()

echo "=============================================="
echo " Android Startup Measurements"
echo " Configurations: $TOTAL"
echo " Iterations per config: $ITERATIONS"
echo "=============================================="
echo ""

mkdir -p "$RESULTS_DIR"
SUMMARY_FILE="$RESULTS_DIR/summary.csv"
echo "app,config,avg_ms,min_ms,max_ms,apk_size_mb,apk_size_bytes,iterations" > "$SUMMARY_FILE"

for i in "${!CONFIGS[@]}"; do
    IFS='|' read -r app config <<< "${CONFIGS[$i]}"
    NUM=$((i + 1))

    echo "[$NUM/$TOTAL] $app | $config"
    echo "----------------------------------------------"

    OUTPUT=$("$SCRIPT_DIR/measure_startup.sh" "$app" "$config" \
        --startup-iterations "$ITERATIONS" "${EXTRA_ARGS[@]}" 2>&1)
    EXIT_CODE=$?

    if [ $EXIT_CODE -eq 0 ]; then
        # Parse results from Startup tool output
        AVG=$(echo "$OUTPUT" | grep "Generic Startup" | awk -F'|' '{print $2}' | sed 's/[^0-9.]//g')
        MIN=$(echo "$OUTPUT" | grep "Generic Startup" | awk -F'|' '{print $3}' | sed 's/[^0-9.]//g')
        MAX=$(echo "$OUTPUT" | grep "Generic Startup" | awk -F'|' '{print $4}' | sed 's/[^0-9.]//g')
        # Parse APK size from measure_startup.sh output
        APK_SIZE_MB=$(echo "$OUTPUT" | grep "APK size:" | sed 's/.*APK size: \([0-9.]*\) MB.*/\1/')
        APK_SIZE_BYTES=$(echo "$OUTPUT" | grep -o '([0-9]* bytes)' | sed 's/[()]//g; s/ bytes//')
        echo "✅ avg=${AVG}ms  min=${MIN}ms  max=${MAX}ms  apk=${APK_SIZE_MB}MB"
        echo "$app,$config,$AVG,$MIN,$MAX,$APK_SIZE_MB,$APK_SIZE_BYTES,$ITERATIONS" >> "$SUMMARY_FILE"
        PASSED=$((PASSED + 1))
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
    echo "App                          | Config         | Avg (ms) | Min (ms) | Max (ms) | APK (MB)"
    echo "-----------------------------|----------------|----------|----------|----------|--------"
    tail -n +2 "$SUMMARY_FILE" | while IFS=',' read -r app config avg min max apk_mb apk_bytes iters; do
        printf "%-28s | %-14s | %8s | %8s | %8s | %8s\n" "$app" "$config" "$avg" "$min" "$max" "$apk_mb"
    done
fi

exit $FAILED
