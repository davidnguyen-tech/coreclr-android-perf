# Plan 003: Fix macOS Startup Measurement Timing

## Overview

Replace the flawed timing methodology in `osx/measure_osx_startup.sh`. Currently the
script measures only the wall-clock duration of the `open` command (~95-103ms regardless
of build config). The fix: after calling `open`, poll for the app's first visible window
using the shared library's `wait_for_window` function, and measure the time from `open`
invocation to first window appearance.

This plan also refactors the script to use the shared library from Plan 002.

---

## Files to Modify

| File | Change |
|------|--------|
| `osx/measure_osx_startup.sh` | Replace measurement loop + use shared library |

---

## Sub-steps

### 1. Add `source` for the shared library

After `source init.sh` (line 14), add:

```bash
source "$SCRIPT_DIR/tools/apple_measure_lib.sh"
```

### 2. Replace the measurement loop (lines 297-327)

The current measurement loop does:
```bash
START_NS=$(python3 -c "import time; print(time.time_ns())")
open "$APP_BUNDLE" 2>/dev/null
LAUNCH_RESULT=$?
END_NS=$(python3 -c "import time; print(time.time_ns())")
```

Replace the body of the `for` loop (inside `for ((i = 1; i <= ITERATIONS; i++))`) with:

```bash
    # Clean state: terminate any running instance
    terminate_app

    # Capture start timestamp
    START_NS=$(get_timestamp_ns)

    # Launch the app asynchronously via LaunchServices
    open "$APP_BUNDLE" 2>/dev/null
    LAUNCH_RESULT=$?

    if [ $LAUNCH_RESULT -ne 0 ]; then
        echo "  [$i/$ITERATIONS] FAILED — open returned $LAUNCH_RESULT"
        FAILED_COUNT=$((FAILED_COUNT + 1))
        continue
    fi

    # Wait for the app's first window to appear (actual startup completion)
    if ! wait_for_window "$EXECUTABLE_NAME" 30; then
        echo "  [$i/$ITERATIONS] FAILED — app window did not appear within 30s"
        terminate_app
        FAILED_COUNT=$((FAILED_COUNT + 1))
        continue
    fi

    # Capture end timestamp AFTER window appears
    END_NS=$(get_timestamp_ns)
    ELAPSED_MS=$(elapsed_ms "$START_NS" "$END_NS")
    TIMES+=("$ELAPSED_MS")

    echo "  [$i/$ITERATIONS] ${ELAPSED_MS} ms"

    # Terminate the app before next iteration
    terminate_app

    # Brief pause between iterations to let the system settle
    sleep 1
```

**Key changes from the original:**
- `END_NS` is captured AFTER `wait_for_window` returns, not after `open` returns
- New failure mode: window timeout (30s) marks iteration as failed
- Uses `get_timestamp_ns` and `elapsed_ms` from shared library

### 3. Replace statistics computation (lines 339-363)

Replace the inline Python statistics block:
```bash
STATS=$(python3 << PYEOF
import statistics
times = [${TIMES[0]}$(printf ', %s' "${TIMES[@]:1}")]
...
PYEOF
)
```

With:
```bash
STATS=$(compute_stats "${TIMES[@]}")
```

Leave the `sed` parsing lines (AVG, MEDIAN, MIN, MAX, STDEV, COUNT) unchanged —
`compute_stats` produces the same 6-line output format.

### 4. Replace summary output (lines 379-383)

Replace:
```bash
echo "Generic Startup | ${AVG} | ${MIN} | ${MAX}"
echo "APP size: ${PACKAGE_SIZE_MB} MB ($PACKAGE_SIZE_BYTES bytes)"
```

With:
```bash
print_measurement_summary "$AVG" "$MIN" "$MAX" "$PACKAGE_SIZE_MB" "$PACKAGE_SIZE_BYTES"
```

### 5. Replace CSV save (lines 387-398)

Replace the inline CSV generation block with:
```bash
mkdir -p "$RESULTS_DIR"
RESULT_FILE="$RESULTS_DIR/${SAMPLE_APP}_${BUILD_CONFIG}_osx.csv"
save_results_csv "$RESULT_FILE" "$SAMPLE_APP" "$BUILD_CONFIG" "osx" \
    "$PACKAGE_SIZE_MB" "$PACKAGE_SIZE_BYTES" \
    "$AVG" "$MEDIAN" "$MIN" "$MAX" "$STDEV" "$COUNT" "${TIMES[@]}"
```

### 6. Update the script header comment (lines 1-12)

Replace the header to reflect the new methodology:
```bash
#!/bin/bash

# Measures macOS app startup time using window-appearance timing.
#
# This script measures native macOS (.app bundle) startup by launching the
# app via `open` and waiting for the first visible window to appear (detected
# via System Events AppleScript). This captures the full startup pipeline:
# process creation, runtime initialization, framework loading, and first
# window draw.
#
# NOTE: Requires Accessibility permission for the terminal app on first run
# (macOS will prompt to allow System Events access).
```

---

## Acceptance Criteria

1. **Correct timing methodology:**
   - Running with `CORECLR_JIT` vs `R2R_COMP` should show meaningfully different
     startup times (not ~8ms difference as before)
   - Measured times should be in the hundreds-of-ms to seconds range (not ~100ms)
   - R2R_COMP should generally show faster startup than CORECLR_JIT

2. **Output format unchanged:**
   - Script still outputs `"Generic Startup | avg | min | max"` line
   - Script still outputs `"APP size: X MB (Y bytes)"` line (exactly once, at end)
   - `measure_all.sh --platform osx` can parse output without modification

3. **Shared library integration:**
   - Script sources `tools/apple_measure_lib.sh`
   - Uses `get_timestamp_ns`, `elapsed_ms`, `wait_for_window`, `compute_stats`,
     `print_measurement_summary`, `save_results_csv`
   - No remaining inline `python3 -c "import time..."` calls in the measurement loop

4. **Error handling:**
   - Window timeout (30s) produces a clear error and marks iteration as failed
   - Script still exits cleanly via cleanup trap (terminate_app) on failure
   - Failed iterations are counted and reported in the summary

5. **CSV output file:**
   - Same path: `results/${SAMPLE_APP}_${BUILD_CONFIG}_osx.csv`
   - Same column format: `iteration,time_ms` rows + summary comment line
   - Parseable by existing tooling

---

## Dependencies

- **Plan 001** (bug fixes — `obj/` cleanup and duplicate APP size)
- **Plan 002** (shared library — `wait_for_window`, `compute_stats`, etc.)

---

## Risks

- **System Events permission:** First run on a new machine will trigger the macOS
  Accessibility permission dialog. The terminal app (Terminal.app, iTerm2, etc.) must
  be granted access under System Settings → Privacy & Security → Accessibility.
  This is a one-time setup. Add a note in the script header and in the macOS README.

- **`osascript` overhead adds ~50ms uncertainty:** Each `osascript` call takes ~20-30ms,
  and with 50ms polling interval, the measurement has ±50ms resolution. For macOS app
  startup times (typically 500ms-2000ms), this is acceptable (<10% relative error).
  The key value is in **relative comparisons** between build configs, not absolute numbers.

- **Headless/SSH environments:** `osascript` System Events requires an active GUI session.
  If the script is run over SSH without screen sharing or a display, `osascript` will fail
  and all iterations will timeout. Document this limitation. The original `open` command
  has the same GUI requirement.

- **App name mismatch in System Events:** The `wait_for_window` function matches by
  process name (`EXECUTABLE_NAME`). If System Events reports the process under a different
  name than `CFBundleExecutable`, window detection will fail. The implementer should verify
  with actual built apps by running:
  ```bash
  osascript -e 'tell application "System Events" to get name of every process'
  ```
  while the app is running, and confirming the name matches.

- **Apps without windows:** If an app crashes during startup (before showing a window),
  the measurement will timeout after 30s. The `terminate_app` call in the failure handler
  will clean up. This is correct behavior — the iteration should be marked as failed.
