# Plan 002: Create Shared Apple Measurement Library

## Overview

Extract common logic from the three Apple measurement scripts into a shared shell
library at `tools/apple_measure_lib.sh`. The three scripts (`osx/measure_osx_startup.sh`,
`maccatalyst/measure_maccatalyst_startup.sh`, `ios/measure_simulator_startup.sh`) are
~95% identical. Extracting shared functions reduces duplication and ensures the timing
fix (Plans 003-005) only needs to be implemented once.

**This plan creates the library only.** The scripts are NOT refactored to use it yet —
that happens in Plans 003-005 alongside each platform's timing fix.

---

## Files to Create

| File | Purpose |
|------|---------|
| `tools/apple_measure_lib.sh` | Shared shell functions for Apple startup measurement |

---

## Sub-steps

### 1. Design the shared function API

The library should expose these functions, derived from the common patterns across
all three scripts:

```bash
# --- Timing helpers ---

# Capture a high-resolution timestamp (nanoseconds).
# Uses python3 since macOS `date` lacks %N.
# Usage: ts=$(get_timestamp_ns)
get_timestamp_ns()

# Compute elapsed milliseconds between two nanosecond timestamps.
# Usage: ms=$(elapsed_ms "$start_ns" "$end_ns")
elapsed_ms()

# --- macOS/Catalyst: window-based timing ---

# Poll for the app's first on-screen window using System Events.
# Returns 0 when a window appears, 1 on timeout.
# Usage: wait_for_window "$executable_name" <timeout_seconds>
wait_for_window()

# --- iOS Simulator: log-based timing ---

# Start `log stream` in background, filtering for the app's process.
# Sets LOG_STREAM_PID and LOG_STREAM_FILE variables.
# Usage: start_log_stream "$process_name"
start_log_stream()

# Stop the background log stream and clean up temp file.
# Usage: stop_log_stream
stop_log_stream()

# Parse the log stream output to find the first app process event timestamp.
# Usage: first_event_ts=$(parse_first_log_event "$log_file" "$process_name")
parse_first_log_event()

# --- Statistics ---

# Compute statistics (avg, median, min, max, stdev, count) from an array of times.
# Outputs 6 lines: avg, median, min, max, stdev, count
# Usage: stats=$(compute_stats "${TIMES[@]}")
compute_stats()

# --- Output formatting ---

# Print the parseable summary lines for measure_all.sh.
# Usage: print_measurement_summary "$avg" "$min" "$max" "$size_mb" "$size_bytes"
print_measurement_summary()

# Save detailed per-iteration results to a CSV file.
# Usage: save_results_csv "$output_file" "$sample_app" "$build_config" "$platform" \
#            "$size_mb" "$size_bytes" "$avg" "$median" "$min" "$max" "$stdev" "$count" \
#            "${TIMES[@]}"
save_results_csv()
```

### 2. Implement `tools/apple_measure_lib.sh`

Create the file with a header comment explaining it's sourced by the platform-specific
measurement scripts. Use `#!/bin/bash` shebang even though it's sourced (for shellcheck).

**Key implementation notes for each function:**

#### `get_timestamp_ns`
```bash
get_timestamp_ns() {
    python3 -c "import time; print(time.time_ns())"
}
```

#### `elapsed_ms`
```bash
elapsed_ms() {
    local start_ns="$1"
    local end_ns="$2"
    python3 -c "print(f'{($end_ns - $start_ns) / 1_000_000:.2f}')"
}
```

#### `wait_for_window`
This is the key timing function for macOS/Mac Catalyst. After `open` launches the app
asynchronously, poll for the app's first window to appear via AppleScript:

```bash
wait_for_window() {
    local executable_name="$1"
    local timeout="${2:-30}"
    local deadline=$((SECONDS + timeout))
    local poll_interval=0.05  # 50ms polling

    while [ $SECONDS -lt $deadline ]; do
        # Check if the process has any windows via System Events
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
```

**Research note:** The `osascript` call queries System Events for visible windows.
This is the same technique recommended in `.github/researches/measurement-methodology-bug.md`
lines 169-170. The poll interval of 50ms provides adequate resolution for startup
times that are typically 500ms-3000ms.

**Important:** `osascript` requires Accessibility permission on macOS. The first time
the terminal runs this, macOS may prompt for permission. Add a comment documenting
this requirement.

#### `start_log_stream` / `stop_log_stream` / `parse_first_log_event`
These are for iOS Simulator timing. The approach:
1. Start `log stream --predicate` in background before app launch
2. Filter for the app's process name and runtime initialization events
3. Parse timestamps from the log output after launch completes

```bash
start_log_stream() {
    local process_name="$1"
    LOG_STREAM_FILE=$(mktemp /tmp/apple_measure_log.XXXXXX)
    # Stream logs for the simulator, filtering for the app process
    log stream --predicate "process == \"$process_name\"" \
        --style ndjson --level info > "$LOG_STREAM_FILE" 2>/dev/null &
    LOG_STREAM_PID=$!
    # Brief pause to ensure log stream is connected
    sleep 0.5
}

stop_log_stream() {
    if [ -n "${LOG_STREAM_PID:-}" ]; then
        kill "$LOG_STREAM_PID" 2>/dev/null || true
        wait "$LOG_STREAM_PID" 2>/dev/null || true
        LOG_STREAM_PID=""
    fi
    if [ -n "${LOG_STREAM_FILE:-}" ] && [ -f "$LOG_STREAM_FILE" ]; then
        rm -f "$LOG_STREAM_FILE"
        LOG_STREAM_FILE=""
    fi
}

parse_first_log_event() {
    local log_file="$1"
    local process_name="$2"
    # Extract the timestamp of the first log event from the app process.
    # ndjson format has "timestamp" field in ISO 8601.
    # Returns non-empty string if found, empty if not.
    python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            entry = json.loads(line)
            proc = entry.get('processImagePath', '') or entry.get('process', '')
            if sys.argv[2] in proc:
                print(entry.get('timestamp', 'found'))
                sys.exit(0)
        except (json.JSONDecodeError, KeyError):
            continue
sys.exit(1)
" "$log_file" "$process_name" 2>/dev/null
}
```

#### `compute_stats`
Extract from the identical Python block that appears in all three scripts:

```bash
compute_stats() {
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
```

**Note on array serialization:** The existing scripts use a fragile bash array
expansion (`${TIMES[0]}$(printf ', %s' "${TIMES[@]:1}")`). The approach above
iterates through the arguments to build a safe comma-separated string. Both produce
the same Python list, but the loop approach avoids edge cases with special characters.

#### `print_measurement_summary`
```bash
print_measurement_summary() {
    local avg="$1" min="$2" max="$3" size_mb="$4" size_bytes="$5"
    echo "Generic Startup | ${avg} | ${min} | ${max}"
    echo "APP size: ${size_mb} MB ($size_bytes bytes)"
}
```

#### `save_results_csv`
```bash
save_results_csv() {
    local output_file="$1" sample_app="$2" build_config="$3" platform="$4"
    local size_mb="$5" size_bytes="$6"
    local avg="$7" median="$8" min_val="$9" max_val="${10}"
    local stdev="${11}" count="${12}"
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
```

### 3. Make the library sourceable and safe

- Start with a double-source guard:
  ```bash
  [ -n "${_APPLE_MEASURE_LIB_LOADED:-}" ] && return 0
  _APPLE_MEASURE_LIB_LOADED=1
  ```
- Do NOT call `set -e` or modify shell options (caller controls that)
- Do NOT define global variables except the guard and `LOG_STREAM_PID`/`LOG_STREAM_FILE`
- Add a `requires_python3()` validation function that scripts can call during prereq checks
- Every function that uses `python3` should fail gracefully if python3 is not available

---

## Acceptance Criteria

1. **File exists:** `tools/apple_measure_lib.sh` is created and is well-commented.

2. **Sourceable without side effects:**
   ```bash
   source tools/apple_measure_lib.sh
   echo $?  # 0
   ```

3. **Functions work independently:**
   - `get_timestamp_ns` returns a large integer (>0)
   - `elapsed_ms 1000000000 1050000000` outputs `50.00`
   - `compute_stats 100 200 300` outputs 6 lines of valid numbers
   - `print_measurement_summary "200.00" "100.00" "300.00" "50.00" "52428800"` outputs
     exactly two lines matching expected patterns

4. **ShellCheck clean:** `shellcheck tools/apple_measure_lib.sh` passes with no errors.

5. **Double-source safe:** Sourcing twice doesn't cause errors or duplicate definitions.

6. **No executable bit needed:** The file is a library, not an executable script. No
   `chmod +x` required (though it won't hurt).

---

## Dependencies

- **Plan 001** should be merged first (so scripts are clean before refactoring).

---

## Risks

- **`osascript` System Events may require Accessibility permission** on macOS. The first
  time the terminal/shell runs `osascript` to query System Events, macOS may prompt for
  permission. This is a one-time action. Document this in a comment in the library.

- **`log stream` predicate syntax** may vary between macOS versions. The ndjson format
  and field names should be tested against actual simulator output on macOS 14.x/15.x.
  The implementer should do exploratory testing: launch an app, run `log stream`, and
  examine the actual output format.

- **Polling resolution for `wait_for_window`:** Each `osascript` call takes ~20-30ms.
  With 50ms sleep between polls, effective resolution is ~50-80ms. For startup times
  of 500ms+, this is <15% relative error. Acceptable for relative comparisons between
  build configs.

- **The `compute_stats` function requires at least one value.** Callers MUST check for
  empty arrays before calling (the existing scripts already do this check).
