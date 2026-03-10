#!/bin/bash
# =============================================================================
# tools/apple_measure_lib.sh — Shared helper functions for Apple startup
# measurement scripts.
#
# This library is sourced by the platform-specific measurement scripts:
#   - osx/measure_osx_startup.sh
#   - maccatalyst/measure_maccatalyst_startup.sh
#   - ios/measure_simulator_startup.sh
#
# It provides:
#   - High-resolution timing helpers (nanosecond timestamps, elapsed ms)
#   - Window-appearance detection for macOS / Mac Catalyst (via AppleScript)
#   - Log stream event detection for iOS Simulator
#   - Process detection (wait for process by name)
#   - Statistics computation (avg, median, min, max, stdev)
#   - Build time measurement (binlog parsing via dotnet/performance)
#   - Output formatting (parseable summary lines for measure_all.sh)
#   - CSV result saving
#
# Usage:
#   source "$(dirname "$0")/../tools/apple_measure_lib.sh"
#
# NOTE: This file is a pure function library. No code executes at source time.
# =============================================================================

# Double-source guard
[ -n "${_APPLE_MEASURE_LIB_LOADED:-}" ] && return 0
_APPLE_MEASURE_LIB_LOADED=1

# =============================================================================
# Prerequisite validation
# =============================================================================

# Check that python3 is available. Call this during script prerequisite checks.
# Usage: requires_python3
requires_python3() {
    if ! command -v python3 &> /dev/null; then
        echo "Error: python3 is required but not found."
        return 1
    fi
    return 0
}

# =============================================================================
# Timing helpers
# =============================================================================

# Capture a high-resolution timestamp in nanoseconds.
# Uses python3 because macOS `date` does not support %N.
# Usage: ts=$(get_timestamp_ns)
get_timestamp_ns() {
    python3 -c "import time; print(time.time_ns())"
}

# Compute elapsed milliseconds between two nanosecond timestamps.
# Output is formatted to 2 decimal places.
# Usage: ms=$(elapsed_ms "$start_ns" "$end_ns")
elapsed_ms() {
    local start_ns="$1"
    local end_ns="$2"
    python3 -c "print(f'{($end_ns - $start_ns) / 1_000_000:.2f}')"
}

# =============================================================================
# macOS / Mac Catalyst: window-appearance detection
# =============================================================================

# Poll for the app's first on-screen window using System Events AppleScript.
# This is the primary timing mechanism for macOS and Mac Catalyst apps: after
# the `open` command launches the app asynchronously, this function polls
# until the app has at least one visible window, indicating it has finished
# rendering its initial UI.
#
# IMPORTANT: This requires Accessibility permissions for the terminal/shell.
# On first use, macOS will prompt to grant "System Events" access to your
# terminal application (Terminal.app, iTerm2, etc.). This is a one-time grant.
#
# Arguments:
#   $1 - executable_name  The process name as shown in System Events
#                         (typically the CFBundleExecutable value)
#   $2 - timeout          Maximum seconds to wait (default: 30)
#   $3 - poll_interval    Seconds between polls (default: 0.05 = 50ms)
#
# Returns:
#   0 - Window detected
#   1 - Timeout (no window appeared within the timeout period)
#
# Usage: wait_for_window "$EXECUTABLE_NAME" 30 0.05
wait_for_window() {
    local executable_name="$1"
    local timeout="${2:-30}"
    local poll_interval="${3:-0.05}"
    local deadline=$((SECONDS + timeout))

    while [ "$SECONDS" -lt "$deadline" ]; do
        local has_window
        has_window=$(osascript -e "
            tell application \"System Events\"
                set appProcs to every process whose name is \"$executable_name\"
                if (count of appProcs) > 0 then
                    set appProc to item 1 of appProcs
                    if (count of windows of appProc) > 0 then
                        return \"yes\"
                    end if
                end if
            end tell
            return \"no\"
        " 2>/dev/null)

        if [ "$has_window" = "yes" ]; then
            return 0
        fi
        sleep "$poll_interval"
    done

    return 1  # timeout
}

# =============================================================================
# iOS Simulator: log stream event detection
# =============================================================================

# Variables set by start_log_stream / cleaned up by stop_log_stream.
# These are intentionally global so the caller can reference them.
_AML_LOG_STREAM_PID=""
_AML_LOG_STREAM_FILE=""

# Start a background `log stream` filtered for a specific process name.
# This should be called BEFORE launching the app so that the log stream
# is already connected when the first events arrive.
#
# Sets:
#   _AML_LOG_STREAM_PID  - PID of the background log stream process
#   _AML_LOG_STREAM_FILE - Path to the temp file collecting log output
#
# Arguments:
#   $1 - predicate  A `log stream --predicate` expression
#                   (e.g., "process == \"MyApp\"")
#   $2 - settle     Seconds to wait after starting the stream to ensure
#                   it is connected (default: 0.5)
#
# Usage: start_log_stream "process == \"MyApp\"" 0.5
start_log_stream() {
    stop_log_stream
    local predicate="$1"
    local settle="${2:-0.5}"

    _AML_LOG_STREAM_FILE=$(mktemp /tmp/apple_measure_log.XXXXXX)

    log stream --predicate "$predicate" \
        --style ndjson --level info > "$_AML_LOG_STREAM_FILE" 2>/dev/null &
    _AML_LOG_STREAM_PID=$!

    # Brief pause to ensure the log stream is connected before we launch the app
    sleep "$settle"
}

# Stop the background log stream and clean up the temp file.
# Safe to call even if start_log_stream was never called.
# Usage: stop_log_stream
stop_log_stream() {
    if [ -n "${_AML_LOG_STREAM_PID:-}" ]; then
        kill "$_AML_LOG_STREAM_PID" 2>/dev/null || true
        wait "$_AML_LOG_STREAM_PID" 2>/dev/null || true
        _AML_LOG_STREAM_PID=""
    fi
    if [ -n "${_AML_LOG_STREAM_FILE:-}" ] && [ -f "$_AML_LOG_STREAM_FILE" ]; then
        rm -f "$_AML_LOG_STREAM_FILE"
        _AML_LOG_STREAM_FILE=""
    fi
}

# Wait for a matching log event to appear in the log stream output file.
# Polls the temp file created by start_log_stream for any line containing
# the specified process name.
#
# Arguments:
#   $1 - process_name  The process name to search for in log entries
#   $2 - timeout       Maximum seconds to wait (default: 30)
#   $3 - poll_interval Seconds between polls (default: 0.1)
#
# Returns:
#   0 - Matching event found (timestamp is printed to stdout if available)
#   1 - Timeout (no matching event within the timeout period)
#
# Usage:
#   start_log_stream "process == \"MyApp\""
#   # ... launch the app ...
#   wait_for_log_event "MyApp" 30
wait_for_log_event() {
    local process_name="$1"
    local timeout="${2:-30}"
    local poll_interval="${3:-0.1}"
    local deadline=$((SECONDS + timeout))

    if [ -z "${_AML_LOG_STREAM_FILE:-}" ] || [ ! -f "$_AML_LOG_STREAM_FILE" ]; then
        echo "Error: log stream not started. Call start_log_stream first." >&2
        return 1
    fi

    while [ "$SECONDS" -lt "$deadline" ]; do
        # Check if the log file contains any entry mentioning the process.
        # Use grep for speed — we just need to know if any line matches.
        if grep -q "$process_name" "$_AML_LOG_STREAM_FILE" 2>/dev/null; then
            # Found a match. Try to extract the timestamp from the first
            # matching ndjson line.
            local ts
            ts=$(python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            entry = json.loads(line)
            proc = entry.get('processImagePath', '') or entry.get('process', '')
            if sys.argv[2] in str(proc):
                print(entry.get('timestamp', 'found'))
                sys.exit(0)
        except (json.JSONDecodeError, KeyError):
            continue
sys.exit(1)
" "$_AML_LOG_STREAM_FILE" "$process_name" 2>/dev/null)

            if [ -n "$ts" ]; then
                echo "$ts"
                return 0
            fi
            # grep matched but python3 didn't parse a valid entry yet —
            # could be a partial write. Keep polling.
        fi
        sleep "$poll_interval"
    done

    return 1  # timeout
}

# =============================================================================
# Process detection
# =============================================================================

# Wait for a process with the given name to appear.
# Uses pgrep to find the process. Returns the PID on stdout when found.
#
# Arguments:
#   $1 - process_name  Name to match (passed to pgrep -x for exact match)
#   $2 - timeout       Maximum seconds to wait (default: 30)
#   $3 - poll_interval Seconds between polls (default: 0.05 = 50ms)
#
# Returns:
#   0 - Process found (PID printed to stdout)
#   1 - Timeout
#
# Usage: pid=$(wait_for_process "MyApp" 10)
wait_for_process() {
    local process_name="$1"
    local timeout="${2:-30}"
    local poll_interval="${3:-0.05}"
    local deadline=$((SECONDS + timeout))

    while [ "$SECONDS" -lt "$deadline" ]; do
        local pid
        pid=$(pgrep -x "$process_name" 2>/dev/null | head -1)
        if [ -n "$pid" ]; then
            echo "$pid"
            return 0
        fi
        sleep "$poll_interval"
    done

    return 1  # timeout
}

# =============================================================================
# Statistics computation
# =============================================================================

# Compute statistics from an array of timing values.
# Outputs 6 lines: avg, median, min, max, stdev, count
# Numeric values are formatted to 2 decimal places; count is an integer.
#
# Requires at least 1 value. Stdev is 0.00 for a single value.
#
# Arguments:
#   $@ - Timing values (e.g., "150.23" "200.45" "175.80")
#
# Usage:
#   STATS=$(compute_stats "${TIMES[@]}")
#   AVG=$(echo "$STATS" | sed -n '1p')
#   MEDIAN=$(echo "$STATS" | sed -n '2p')
#   MIN=$(echo "$STATS" | sed -n '3p')
#   MAX=$(echo "$STATS" | sed -n '4p')
#   STDEV=$(echo "$STATS" | sed -n '5p')
#   COUNT=$(echo "$STATS" | sed -n '6p')
compute_stats() {
    if [ $# -eq 0 ]; then
        echo "Error: compute_stats requires at least one value." >&2
        return 1
    fi

    # Build a comma-separated string from the arguments.
    # This avoids the fragile ${TIMES[0]}$(printf ...) pattern used
    # in the original scripts, and handles edge cases safely.
    local times_str=""
    local first=true
    for t in "$@"; do
        if [ "$first" = true ]; then
            times_str="$t"
            first=false
        else
            times_str="$times_str, $t"
        fi
    done

    python3 << PYEOF
import statistics
times = [$times_str]
times.sort()
n = len(times)
avg = statistics.mean(times)
median = statistics.median(times)
min_t = min(times)
max_t = max(times)
stdev = statistics.stdev(times) if n > 1 else 0.0
print(f'{avg:.2f}')
print(f'{median:.2f}')
print(f'{min_t:.2f}')
print(f'{max_t:.2f}')
print(f'{stdev:.2f}')
print(f'{n}')
PYEOF
}

# =============================================================================
# Build time measurement (binlog parsing)
# =============================================================================

# Run test.py buildtime to parse build metrics from an MSBuild binlog.
#
# Uses the dotnet/performance infrastructure to extract per-task build timing
# (ILLink, MonoAOTCompiler, AppleAppBuilderTask, AndroidAppBuilderTask) and
# total Publish Time from a binary log produced by `dotnet build -bl:`.
#
# Outputs a "Build time: XXXX.XX ms" line to stdout on success.
# Also outputs the detailed per-task breakdown from test.py for visibility.
# On failure, prints a warning and outputs nothing parseable — the caller
# can fall back to wall-clock timing.
#
# Requirements:
#   - DOTNET_ROOT must be set (or DOTNET_DIR from init.sh)
#   - python3 must be available
#   - The external/performance submodule must be checked out
#
# Arguments:
#   $1 - binlog_path     Absolute path to the .binlog file
#   $2 - scenario_name   Name for the scenario (e.g., "dotnet-new-macos_CORECLR_JIT")
#
# Usage:
#   BUILDTIME_OUTPUT=$(run_buildtime_parser "$BINLOG_PATH" "${SAMPLE_APP}_${BUILD_CONFIG}")
#   echo "$BUILDTIME_OUTPUT"
run_buildtime_parser() {
    local binlog_path="$1"
    local scenario_name="$2"

    # Validate inputs
    if [ -z "$binlog_path" ] || [ ! -f "$binlog_path" ]; then
        echo "Warning: Binlog not found at '$binlog_path', skipping build time parsing." >&2
        return 1
    fi

    if [ -z "$scenario_name" ]; then
        echo "Warning: scenario_name is required for build time parsing." >&2
        return 1
    fi

    # Locate the test.py script in the dotnet/performance submodule.
    # We use genericandroidstartup as the scenario directory because the
    # buildtime codepath in runner.py ignores the scenario's EXENAME —
    # it unconditionally sets apptorun="app". Any scenario dir works.
    local perf_dir="${PERF_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/external/performance}"
    local scenario_dir="$perf_dir/src/scenarios/genericandroidstartup"
    local test_py="$scenario_dir/test.py"

    if [ ! -f "$test_py" ]; then
        echo "Warning: test.py not found at '$test_py'. Is the external/performance submodule checked out?" >&2
        return 1
    fi

    # Ensure DOTNET_ROOT is set for the Startup tool build
    local dotnet_dir="${DOTNET_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/.dotnet}"
    export DOTNET_ROOT="${DOTNET_ROOT:-$dotnet_dir}"
    export PATH="$DOTNET_ROOT:$PATH"

    # Ensure PYTHONPATH includes the scenarios dir (for shared.runner import)
    local scenarios_dir="${SCENARIOS_DIR:-$perf_dir/src/scenarios}"
    export PYTHONPATH="$scenarios_dir:${PYTHONPATH:-}"

    # The runner expects the binlog at traces/<binlog-path> relative to CWD.
    # Create traces/ in the scenario dir and copy the binlog there.
    local binlog_filename
    binlog_filename=$(basename "$binlog_path")

    local traces_dir="$scenario_dir/traces"
    mkdir -p "$traces_dir"
    cp "$binlog_path" "$traces_dir/$binlog_filename"

    # Run test.py buildtime from the scenario directory
    local output
    local exit_code
    output=$(cd "$scenario_dir" && python3 test.py buildtime \
        --scenario-name "$scenario_name" \
        --binlog-path "./$binlog_filename" 2>&1) || exit_code=$?
    exit_code=${exit_code:-0}

    # Clean up: remove the copied binlog to avoid accumulation
    rm -f "$traces_dir/$binlog_filename"

    if [ $exit_code -ne 0 ]; then
        echo "Warning: test.py buildtime failed (exit code $exit_code). Build time parsing unavailable." >&2
        echo "$output" | tail -5 >&2
        return 1
    fi

    # Echo the full output for visibility (detailed per-task breakdown)
    echo "$output"

    # Parse "Publish Time" from the result table.
    # Format: "Publish Time   |42.123 s       |42.123 s       |42.123 s"
    local publish_time_s
    publish_time_s=$(echo "$output" | grep "Publish Time" | awk -F'|' '{print $2}' | sed 's/[^0-9.]//g')

    if [ -n "$publish_time_s" ]; then
        # Convert seconds to milliseconds
        local build_time_ms
        build_time_ms=$(python3 -c "print(f'{float(\"$publish_time_s\") * 1000:.2f}')")
        echo "Build time: ${build_time_ms} ms"
    else
        echo "Warning: Could not parse Publish Time from test.py buildtime output." >&2
        return 1
    fi

    return 0
}

# =============================================================================
# Output formatting
# =============================================================================

# Print the parseable summary lines expected by measure_all.sh.
# Format:
#   Generic Startup | <avg> | <min> | <max>
#   APP size: <size_mb> MB (<size_bytes> bytes)
#
# Arguments:
#   $1 - avg         Average startup time in ms (e.g., "200.00")
#   $2 - min         Minimum startup time in ms
#   $3 - max         Maximum startup time in ms
#   $4 - size_mb     Package size in MB (e.g., "50.00")
#   $5 - size_bytes  Package size in bytes (e.g., "52428800")
#
# Usage: print_measurement_summary "$AVG" "$MIN" "$MAX" "$SIZE_MB" "$SIZE_BYTES"
print_measurement_summary() {
    local avg="$1"
    local min="$2"
    local max="$3"
    local size_mb="$4"
    local size_bytes="$5"

    echo "Generic Startup | ${avg} | ${min} | ${max}"
    echo "APP size: ${size_mb} MB ($size_bytes bytes)"
}

# =============================================================================
# CSV result saving
# =============================================================================

# Save detailed per-iteration results to a CSV file.
# The CSV contains one row per iteration plus a summary comment line.
#
# Arguments:
#   $1  - output_file   Path to the CSV file to write
#   $2  - sample_app    App name (e.g., "dotnet-new-macos")
#   $3  - build_config  Build config (e.g., "CORECLR_JIT")
#   $4  - platform      Platform label (e.g., "osx", "maccatalyst", "simulator")
#   $5  - size_mb       Package size in MB
#   $6  - size_bytes    Package size in bytes
#   $7  - avg           Average startup time in ms
#   $8  - median        Median startup time in ms
#   $9  - min_val       Minimum startup time in ms
#   $10 - max_val       Maximum startup time in ms
#   $11 - stdev         Standard deviation in ms
#   $12 - count         Number of successful iterations
#   $@  (remaining)     Per-iteration timing values
#
# Usage:
#   save_results_csv "$RESULT_FILE" "$SAMPLE_APP" "$BUILD_CONFIG" "osx" \
#       "$SIZE_MB" "$SIZE_BYTES" "$AVG" "$MEDIAN" "$MIN" "$MAX" "$STDEV" "$COUNT" \
#       "${TIMES[@]}"
save_results_csv() {
    local output_file="$1"
    local sample_app="$2"
    local build_config="$3"
    local platform="$4"
    local size_mb="$5"
    local size_bytes="$6"
    local avg="$7"
    local median="$8"
    local min_val="$9"
    local max_val="${10}"
    local stdev="${11}"
    local count="${12}"
    shift 12
    local times=("$@")

    {
        echo "iteration,time_ms"
        for ((idx = 0; idx < ${#times[@]}; idx++)); do
            echo "$((idx + 1)),${times[$idx]}"
        done
        echo ""
        echo "# summary: avg_ms,median_ms,min_ms,max_ms,stdev_ms,count,app,config,platform,pkg_size_mb,pkg_size_bytes"
        echo "$avg,$median,$min_val,$max_val,$stdev,$count,$sample_app,$build_config,$platform,$size_mb,$size_bytes"
    } > "$output_file"
}

# =============================================================================
# .nettrace trace collection helpers
# =============================================================================

# Default EventPipe providers for startup analysis.
# - Microsoft-Windows-DotNETRuntime with JIT, Loader, GC, R2R, TypeLoad events
# - Microsoft-DotNETCore-SampleProfiler for CPU sampling
NETTRACE_PROVIDERS="Microsoft-Windows-DotNETRuntime:0x4c14fccbd:5,Microsoft-DotNETCore-SampleProfiler:0x0:5"

# Set up EventPipe environment variables for trace collection.
# These are designed for the "simple" approach: env vars tell the runtime to
# write a .nettrace file on startup without needing dotnet-trace or dsrouter.
#
# Arguments:
#   $1 - output_path  Where to write the .nettrace file
#   $2 - providers    Provider config string (default: $NETTRACE_PROVIDERS)
#
# Sets the following environment variables in the CALLING shell:
#   DOTNET_EnableEventPipe=1
#   DOTNET_EventPipeOutputPath=<output_path>
#   DOTNET_EventPipeOutputStreaming=1
#   DOTNET_EventPipeConfig=<providers>
#
# Usage:
#   setup_eventpipe_env "/tmp/trace.nettrace"
#   # ... launch app with these env vars ...
#   unset_eventpipe_env
setup_eventpipe_env() {
    local output_path="$1"
    local providers="${2:-$NETTRACE_PROVIDERS}"

    export DOTNET_EnableEventPipe=1
    export DOTNET_EventPipeOutputPath="$output_path"
    export DOTNET_EventPipeOutputStreaming=1
    export DOTNET_EventPipeConfig="$providers"
}

# Unset EventPipe environment variables after trace collection.
# Safe to call even if setup_eventpipe_env was never called.
# Usage: unset_eventpipe_env
unset_eventpipe_env() {
    unset DOTNET_EnableEventPipe
    unset DOTNET_EventPipeOutputPath
    unset DOTNET_EventPipeOutputStreaming
    unset DOTNET_EventPipeConfig
}

# Collect the .nettrace file after an app run.
# Searches for .nettrace files at the expected path, and if not found,
# searches common locations (app data container, /tmp, etc.).
#
# Arguments:
#   $1 - expected_path  Where the trace should have been written
#   $2 - dest_path      Where to copy the trace file
#   $3 - search_dirs    (Optional) Space-separated list of additional dirs to search
#
# Returns:
#   0 - Trace file found and copied successfully
#   1 - No trace file found
#
# Usage:
#   collect_nettrace "/tmp/trace.nettrace" "$RESULTS_DIR/app_config.nettrace"
collect_nettrace() {
    local expected_path="$1"
    local dest_path="$2"
    local search_dirs="${3:-}"

    # First, check the expected path
    if [ -f "$expected_path" ]; then
        local file_size
        file_size=$(wc -c < "$expected_path" | tr -d ' ')
        if [ "$file_size" -gt 1000 ]; then
            cp "$expected_path" "$dest_path"
            echo "Trace collected: $dest_path ($file_size bytes)"
            rm -f "$expected_path"
            return 0
        else
            echo "Warning: Trace file at $expected_path is suspiciously small ($file_size bytes)." >&2
        fi
    fi

    # Search additional directories for .nettrace files matching the expected name pattern.
    # Derive a scoped glob from the expected filename (strip PID suffix) to avoid matching
    # stale traces from previous runs.
    local expected_basename
    expected_basename=$(basename "$expected_path" .nettrace)
    # Strip trailing _<PID> (digits after last underscore) to get the app/config prefix
    local name_pattern
    name_pattern=$(echo "$expected_basename" | sed 's/_[0-9]*$//')

    for dir in $search_dirs; do
        if [ -d "$dir" ]; then
            local found
            found=$(find "$dir" -name "${name_pattern}*.nettrace" -size +1k 2>/dev/null | head -1)
            if [ -n "$found" ]; then
                local file_size
                file_size=$(wc -c < "$found" | tr -d ' ')
                cp "$found" "$dest_path"
                echo "Trace collected from $found: $dest_path ($file_size bytes)"
                rm -f "$found"
                return 0
            fi
        fi
    done

    echo "Warning: No .nettrace file found at expected path or search directories." >&2
    return 1
}

# Build the SIMCTL_CHILD_ prefixed env var exports for iOS Simulator trace collection.
# The iOS Simulator passes environment variables to launched apps when they
# have the SIMCTL_CHILD_ prefix.
#
# Arguments:
#   $1 - output_path  Where to write the .nettrace file (inside simulator container)
#   $2 - providers    Provider config string (default: $NETTRACE_PROVIDERS)
#
# Usage:
#   setup_simctl_eventpipe_env "/tmp/trace.nettrace"
#   xcrun simctl launch ...
#   unset_simctl_eventpipe_env
setup_simctl_eventpipe_env() {
    local output_path="$1"
    local providers="${2:-$NETTRACE_PROVIDERS}"

    export SIMCTL_CHILD_DOTNET_EnableEventPipe=1
    export SIMCTL_CHILD_DOTNET_EventPipeOutputPath="$output_path"
    export SIMCTL_CHILD_DOTNET_EventPipeOutputStreaming=1
    export SIMCTL_CHILD_DOTNET_EventPipeConfig="$providers"
}

# Unset SIMCTL_CHILD_ prefixed EventPipe environment variables.
# Usage: unset_simctl_eventpipe_env
unset_simctl_eventpipe_env() {
    unset SIMCTL_CHILD_DOTNET_EnableEventPipe
    unset SIMCTL_CHILD_DOTNET_EventPipeOutputPath
    unset SIMCTL_CHILD_DOTNET_EventPipeOutputStreaming
    unset SIMCTL_CHILD_DOTNET_EventPipeConfig
}
