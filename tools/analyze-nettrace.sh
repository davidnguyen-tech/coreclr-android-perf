#!/bin/bash
# =============================================================================
# tools/analyze-nettrace.sh — Compare .nettrace files between R2R configurations
#
# Wrapper script for the nettrace-analyzer C# tool. Supports two modes:
#
#   Direct file mode:
#     ./tools/analyze-nettrace.sh <file1.nettrace> <file2.nettrace> [report.md]
#
#   Auto-discovery mode:
#     ./tools/analyze-nettrace.sh --app dotnet-new-maui-samplecontent [report.md]
#     ./tools/analyze-nettrace.sh --app dotnet-new-android --configs CORECLR_JIT R2R_COMP_PGO
#     ./tools/analyze-nettrace.sh --app dotnet-new-maui --platform ios
#
# Options:
#   --help                  Print usage and exit
#   --rebuild               Force rebuild of the analyzer before running
#   --app <name>            Auto-discover latest traces by app name
#   --platform <platform>   Platform filter for auto-discovery (default: android)
#   --configs <c1> <c2>     Configs to compare (default: R2R_COMP R2R_COMP_PGO)
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
ANALYZER_PROJECT="$REPO_ROOT/tools/nettrace-analyzer"
ANALYZER_DLL="$ANALYZER_PROJECT/bin/Release/net8.0/nettrace-analyzer.dll"

# ---------------------------------------------------------------------------
# usage — print help text
# ---------------------------------------------------------------------------
usage() {
    cat <<'EOF'
Usage:
  analyze-nettrace.sh <file1.nettrace> <file2.nettrace> [report.md]
  analyze-nettrace.sh --app <name> [report.md]

Direct file mode:
  Pass two .nettrace files to compare directly.
  Default report: /tmp/nettrace-comparison-report.md

Auto-discovery mode:
  --app <name>            Find latest traces by app name under traces/
  --platform <platform>   Platform filter (default: android)
  --configs <c1> <c2>     Configs to compare (default: R2R_COMP R2R_COMP_PGO)
  Default report: results/<app>-nettrace-comparison.md

Options:
  --help      Print this help and exit
  --rebuild   Force rebuild of the analyzer before running

Examples:
  ./tools/analyze-nettrace.sh trace1.nettrace trace2.nettrace
  ./tools/analyze-nettrace.sh --app dotnet-new-maui-samplecontent
  ./tools/analyze-nettrace.sh --app dotnet-new-android --configs CORECLR_JIT R2R_COMP_PGO
  ./tools/analyze-nettrace.sh --app dotnet-new-maui --platform ios report.md
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
# Parse arguments
# ---------------------------------------------------------------------------
REBUILD=false
APP_NAME=""
PLATFORM="android"
CONFIG1="R2R_COMP"
CONFIG2="R2R_COMP_PGO"
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
        --app)
            APP_NAME="$2"
            shift 2
            ;;
        --platform)
            PLATFORM="$2"
            shift 2
            ;;
        --configs)
            CONFIG1="$2"
            CONFIG2="$3"
            shift 3
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

# ---------------------------------------------------------------------------
# Lazy build
# ---------------------------------------------------------------------------
if [ "$REBUILD" = true ] || [ ! -f "$ANALYZER_DLL" ]; then
    build_analyzer
fi

# ---------------------------------------------------------------------------
# Determine mode and resolve file paths
# ---------------------------------------------------------------------------
if [ -n "$APP_NAME" ]; then
    # --- Auto-discovery mode ---
    TRACE_DIR1="$REPO_ROOT/traces/${APP_NAME}_${CONFIG1}"
    TRACE_DIR2="$REPO_ROOT/traces/${APP_NAME}_${CONFIG2}"

    if [ ! -d "$TRACE_DIR1" ]; then
        echo "Error: Trace directory not found: $TRACE_DIR1" >&2
        exit 1
    fi
    if [ ! -d "$TRACE_DIR2" ]; then
        echo "Error: Trace directory not found: $TRACE_DIR2" >&2
        exit 1
    fi

    FILE1=$(find_latest_trace "$TRACE_DIR1" "$PLATFORM" "$CONFIG1")
    FILE2=$(find_latest_trace "$TRACE_DIR2" "$PLATFORM" "$CONFIG2")

    # Default report path for auto-discovery
    REPORT="${POSITIONAL[0]:-$REPO_ROOT/results/${APP_NAME}-nettrace-comparison.md}"

    echo "Auto-discovered traces:"
    echo "  $CONFIG1: $FILE1"
    echo "  $CONFIG2: $FILE2"
else
    # --- Direct file mode ---
    if [ ${#POSITIONAL[@]} -lt 2 ]; then
        echo "Error: Direct mode requires two .nettrace files" >&2
        echo "" >&2
        usage >&2
        exit 1
    fi

    FILE1="${POSITIONAL[0]}"
    FILE2="${POSITIONAL[1]}"
    REPORT="${POSITIONAL[2]:-/tmp/nettrace-comparison-report.md}"

    if [ ! -f "$FILE1" ]; then
        echo "Error: File not found: $FILE1" >&2
        exit 1
    fi
    if [ ! -f "$FILE2" ]; then
        echo "Error: File not found: $FILE2" >&2
        exit 1
    fi
fi

# ---------------------------------------------------------------------------
# Ensure results directory exists for report output
# ---------------------------------------------------------------------------
mkdir -p "$(dirname "$REPORT")"

# ---------------------------------------------------------------------------
# Run the analyzer via DLL mode (avoids macOS amfid issue)
# ---------------------------------------------------------------------------
echo "Running nettrace analyzer..."
echo "  Report: $REPORT"
"$DOTNET" "$ANALYZER_DLL" "$FILE1" "$FILE2" "$REPORT"
