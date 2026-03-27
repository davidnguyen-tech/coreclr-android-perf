#!/bin/bash
# =============================================================================
# tools/analyze-nettrace.sh — Compare .nettrace files between R2R configurations
#
# Orchestrates the nettrace-analyzer C# tool to extract JIT/R2R method data
# from two config traces, then computes a JIT method diff using jq.
#
# Usage:
#   ./tools/analyze-nettrace.sh <app-name> <config1> <config2> [--platform <platform>] [--rebuild]
#   ./tools/analyze-nettrace.sh --help
#
# Examples:
#   ./tools/analyze-nettrace.sh dotnet-new-maui-samplecontent R2R_COMP R2R_COMP_PGO
#   ./tools/analyze-nettrace.sh dotnet-new-maui R2R_COMP R2R_COMP_PGO --platform ios
# =============================================================================
set -e

# ---------------------------------------------------------------------------
# Determine REPO_ROOT by walking up from this script's location
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# ---------------------------------------------------------------------------
# Resolve dotnet — prefer local SDK, fall back to PATH
# ---------------------------------------------------------------------------
if [ -x "$REPO_ROOT/.dotnet/dotnet" ]; then
    DOTNET="$REPO_ROOT/.dotnet/dotnet"
else
    DOTNET="dotnet"
fi

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
ANALYZER_PROJECT="$REPO_ROOT/tools/nettrace-analyzer/nettrace-analyzer.csproj"
ANALYZER_DLL="$REPO_ROOT/tools/nettrace-analyzer/bin/Release/net8.0/nettrace-analyzer.dll"

# ---------------------------------------------------------------------------
# usage — print help text
# ---------------------------------------------------------------------------
usage() {
    cat <<'EOF'
Usage:
  analyze-nettrace.sh <app-name> <config1> <config2> [options]

Arguments:
  <app-name>    Application name (e.g. dotnet-new-maui-samplecontent)
  <config1>     Baseline configuration (e.g. R2R_COMP)
  <config2>     Comparison configuration (e.g. R2R_COMP_PGO)

Options:
  --platform <platform>   Platform filter for trace discovery (default: android)
  --rebuild               Force rebuild of the C# analyzer
  --help                  Print this help and exit

Examples:
  ./tools/analyze-nettrace.sh dotnet-new-maui-samplecontent R2R_COMP R2R_COMP_PGO
  ./tools/analyze-nettrace.sh dotnet-new-maui R2R_COMP R2R_COMP_PGO --platform ios
  ./tools/analyze-nettrace.sh dotnet-new-android CORECLR_JIT R2R_COMP_PGO --rebuild
EOF
}

# ---------------------------------------------------------------------------
# build_analyzer — lazy build (or forced rebuild)
# ---------------------------------------------------------------------------
build_analyzer() {
    echo "Building nettrace analyzer..."
    "$DOTNET" build "$ANALYZER_PROJECT" -c Release --nologo -v quiet
}

# ---------------------------------------------------------------------------
# find_latest_trace <dir> <platform> <config>
#   Find the latest .nettrace file matching *-<platform>-<config>-*.nettrace
#   in the given directory. Sorted lexicographically; last = latest due to
#   YYYYMMDD-HHMMSS timestamps.
# ---------------------------------------------------------------------------
find_latest_trace() {
    local dir="$1"
    local platform="$2"
    local config="$3"
    local pattern="*-${platform}-${config}-*.nettrace"

    # Find candidates: minimum 8 KB (real traces are 8 MB+), sorted newest-last
    local candidates
    candidates=$(find "$dir" -maxdepth 1 -name "$pattern" -type f -size +8k 2>/dev/null | sort)

    if [ -z "$candidates" ]; then
        echo "Error: No trace matching '$pattern' (>8 KB) found in $dir" >&2
        exit 1
    fi

    # Walk from newest to oldest; validate nettrace magic header ("Nettrace")
    local candidate header
    while IFS= read -r candidate; do
        header=$(head -c 8 "$candidate" 2>/dev/null)
        if [ "$header" = "Nettrace" ]; then
            echo "$candidate"
            return 0
        fi
        echo "Warning: skipping invalid nettrace (bad magic header): $candidate" >&2
    done < <(echo "$candidates" | sort -r)

    echo "Error: No valid nettrace file found matching '$pattern' in $dir" >&2
    exit 1
}

# ---------------------------------------------------------------------------
# Step 1: Parse arguments
# ---------------------------------------------------------------------------
REBUILD=false
PLATFORM="android"
POSITIONAL=()

while [ $# -gt 0 ]; do
    case "$1" in
        --help)
            usage
            exit 0
            ;;
        --rebuild)
            REBUILD=true
            shift
            ;;
        --platform)
            PLATFORM="$2"
            shift 2
            ;;
        -*)
            echo "Error: Unknown option: $1" >&2
            usage >&2
            exit 1
            ;;
        *)
            POSITIONAL+=("$1")
            shift
            ;;
    esac
done

if [ ${#POSITIONAL[@]} -lt 3 ]; then
    echo "Error: Required arguments: <app-name> <config1> <config2>" >&2
    echo "" >&2
    usage >&2
    exit 1
fi

APP="${POSITIONAL[0]}"
CONFIG1="${POSITIONAL[1]}"
CONFIG2="${POSITIONAL[2]}"

# ---------------------------------------------------------------------------
# Step 2: Resolve dotnet SDK (already done above)
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Step 3: Build analyzer (lazy)
# ---------------------------------------------------------------------------
if [ "$REBUILD" = true ] || [ ! -f "$ANALYZER_DLL" ]; then
    build_analyzer
fi

# ---------------------------------------------------------------------------
# Step 4: Create timestamped output directory
# ---------------------------------------------------------------------------
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
OUTPUT_DIR="$REPO_ROOT/nettrace-analysis/$TIMESTAMP"
mkdir -p "$OUTPUT_DIR"

# ---------------------------------------------------------------------------
# Step 5: Auto-discover latest traces
# ---------------------------------------------------------------------------
TRACE_DIR1="$REPO_ROOT/traces/${APP}_${CONFIG1}"
TRACE_DIR2="$REPO_ROOT/traces/${APP}_${CONFIG2}"

if [ ! -d "$TRACE_DIR1" ]; then
    echo "Error: Trace directory not found: $TRACE_DIR1" >&2
    exit 1
fi
if [ ! -d "$TRACE_DIR2" ]; then
    echo "Error: Trace directory not found: $TRACE_DIR2" >&2
    exit 1
fi

TRACE1=$(find_latest_trace "$TRACE_DIR1" "$PLATFORM" "$CONFIG1")
TRACE2=$(find_latest_trace "$TRACE_DIR2" "$PLATFORM" "$CONFIG2")

echo "Auto-discovered traces:"
echo "  $CONFIG1: $TRACE1"
echo "  $CONFIG2: $TRACE2"

# ---------------------------------------------------------------------------
# Step 6: Run C# analyzer on each trace
# ---------------------------------------------------------------------------
echo ""
echo "Running nettrace analyzer on $CONFIG1..."
if ! "$DOTNET" "$ANALYZER_DLL" "$TRACE1" --config-name "$CONFIG1" \
    > "$OUTPUT_DIR/${CONFIG1}.json" \
    2>"$OUTPUT_DIR/${CONFIG1}.stderr.log"; then
    echo "Error: Analyzer failed for $CONFIG1. See $OUTPUT_DIR/${CONFIG1}.stderr.log" >&2
    exit 1
fi

echo "Running nettrace analyzer on $CONFIG2..."
if ! "$DOTNET" "$ANALYZER_DLL" "$TRACE2" --config-name "$CONFIG2" \
    > "$OUTPUT_DIR/${CONFIG2}.json" \
    2>"$OUTPUT_DIR/${CONFIG2}.stderr.log"; then
    echo "Error: Analyzer failed for $CONFIG2. See $OUTPUT_DIR/${CONFIG2}.stderr.log" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Step 7: Generate metadata.json
# ---------------------------------------------------------------------------
TRACE1_ABS=$(realpath "$TRACE1")
TRACE2_ABS=$(realpath "$TRACE2")
OUTPUT_DIR_ABS=$(realpath "$OUTPUT_DIR")

cat > "$OUTPUT_DIR/metadata.json" <<EOF
{
  "timestamp": "$TIMESTAMP",
  "app": "$APP",
  "platform": "$PLATFORM",
  "configs": ["$CONFIG1", "$CONFIG2"],
  "traceFiles": {
    "$CONFIG1": "$TRACE1_ABS",
    "$CONFIG2": "$TRACE2_ABS"
  },
  "outputDir": "$OUTPUT_DIR_ABS/"
}
EOF

# ---------------------------------------------------------------------------
# Step 8: Generate jit-diff.json using jq
# ---------------------------------------------------------------------------
if command -v jq &>/dev/null; then
    echo ""
    echo "Computing JIT method diff..."
    jq -n \
      --slurpfile c1 "$OUTPUT_DIR/${CONFIG1}.json" \
      --slurpfile c2 "$OUTPUT_DIR/${CONFIG2}.json" \
      --arg config1 "$CONFIG1" \
      --arg config2 "$CONFIG2" \
      '
      ($c1[0].methods.jit | sort) as $jit1 |
      ($c2[0].methods.jit | sort) as $jit2 |
      ($c2[0].methods.jit | map({(.): true}) | add // {}) as $set2 |
      ($c1[0].methods.jit | map({(.): true}) | add // {}) as $set1 |
      {
        config1: $config1,
        config2: $config2,
        summary: {
          jitMethodsConfig1: ($jit1 | length),
          jitMethodsConfig2: ($jit2 | length),
          onlyInConfig1: ([$jit1[] | select($set2[.] == null)] | length),
          onlyInConfig2: ([$jit2[] | select($set1[.] == null)] | length),
          common: ([$jit1[] | select($set2[.] != null)] | length)
        },
        onlyInConfig1: [$jit1[] | select($set2[.] == null)],
        onlyInConfig2: [$jit2[] | select($set1[.] == null)],
        common: [$jit1[] | select($set2[.] != null)]
      }' > "$OUTPUT_DIR/jit-diff.json"
    JIT_DIFF_GENERATED=true
else
    echo ""
    echo "Warning: jq not found — skipping jit-diff.json generation" >&2
    JIT_DIFF_GENERATED=false
fi

# ---------------------------------------------------------------------------
# Step 9: Print summary to terminal
# ---------------------------------------------------------------------------
echo ""
echo "=== Nettrace Analysis Complete ==="

# Relative paths for display
REL_OUTPUT_DIR="${OUTPUT_DIR#"$REPO_ROOT/"}"
REL_TRACE1="${TRACE1#"$REPO_ROOT/"}"
REL_TRACE2="${TRACE2#"$REPO_ROOT/"}"

echo "App:       $APP"
echo "Platform:  $PLATFORM"
echo "Configs:   $CONFIG1 vs $CONFIG2"
echo "Output:    $REL_OUTPUT_DIR/"
echo ""
echo "Trace files:"
echo "  $CONFIG1:$(printf '%*s' $((14 - ${#CONFIG1})) '')$REL_TRACE1"
echo "  $CONFIG2:$(printf '%*s' $((14 - ${#CONFIG2})) '')$REL_TRACE2"
echo ""
echo "Files generated:"

if command -v jq &>/dev/null; then
    JIT_COUNT1=$(jq '.methods.jit | length' "$OUTPUT_DIR/${CONFIG1}.json")
    JIT_COUNT2=$(jq '.methods.jit | length' "$OUTPUT_DIR/${CONFIG2}.json")
    echo "  ${CONFIG1}.json$(printf '%*s' $((21 - ${#CONFIG1} - 5)) '')— $JIT_COUNT1 JIT methods extracted"
    echo "  ${CONFIG2}.json$(printf '%*s' $((21 - ${#CONFIG2} - 5)) '')— $JIT_COUNT2 JIT methods extracted"

    if [ "$JIT_DIFF_GENERATED" = true ]; then
        ONLY_C1=$(jq '.summary.onlyInConfig1' "$OUTPUT_DIR/jit-diff.json")
        ONLY_C2=$(jq '.summary.onlyInConfig2' "$OUTPUT_DIR/jit-diff.json")
        COMMON=$(jq '.summary.common' "$OUTPUT_DIR/jit-diff.json")
        echo "  jit-diff.json$(printf '%*s' $((21 - 13)) '')— $ONLY_C2 only in $CONFIG2, $ONLY_C1 only in $CONFIG1, $COMMON common"
    fi
else
    echo "  ${CONFIG1}.json"
    echo "  ${CONFIG2}.json"
fi

echo "  metadata.json$(printf '%*s' $((21 - 13)) '')— run metadata"
