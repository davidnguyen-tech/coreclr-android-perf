# Plan 005: Fix iOS Simulator Startup Measurement Timing

## Overview

Replace the flawed timing in `ios/measure_simulator_startup.sh`. Currently the script
measures the wall-clock duration of `xcrun simctl launch` (~300ms for all configs).
The fix: start a `log stream` listener before launching the app, then parse runtime
initialization events from the simulator's log to determine when the app actually started.

This is the most complex fix because iOS Simulator doesn't have a visible desktop window
to poll — we must rely on OS log events.

---

## Files to Modify

| File | Change |
|------|--------|
| `ios/measure_simulator_startup.sh` | Replace measurement loop + use shared library |

---

## Sub-steps

### 1. Prerequisite: Identify the correct log event

**Before implementing**, the implementer MUST determine which log event reliably
indicates app startup completion in the simulator. This requires hands-on testing.

**Test procedure:**
```bash
# Terminal 1: Start log stream
log stream --predicate 'process == "dotnet_new_ios"' --style ndjson --level info

# Terminal 2: Launch an app on the simulator
xcrun simctl launch booted com.companyname.dotnet_new_ios
```

Examine the output and identify:
- What process name the .NET app logs under (is it `CFBundleExecutable` value?)
- What the first log message is (runtime init? dyld? something else?)
- How quickly the first log appears after launch
- Whether the event is consistent across MONO_JIT, CORECLR_JIT, and R2R_COMP builds

**Options to investigate (in order of preference):**

**Option A: First app process log event**
```bash
log stream --predicate 'process == "<CFBundleExecutable>"' --style ndjson
```
The first log entry from the app's process means the runtime has initialized enough
to emit log messages. Simple and reliable.

**Option B: FrontBoard/BackBoard lifecycle events**
```bash
log stream --predicate '(process == "SpringBoard" OR process == "FrontBoard") AND eventMessage CONTAINS "<BundleID>"' --style ndjson
```
These processes manage app lifecycle on iOS. Events may be available in the simulator.

**Option C: UIKit scene events**
```bash
log stream --predicate 'process == "<CFBundleExecutable>" AND eventMessage CONTAINS[c] "scene"' --style ndjson
```
UIKit scene lifecycle events indicate UI readiness.

**Recommendation:** Start with Option A. It's the simplest and most likely to work
across all build configs.

**Fallback:** If log-based timing proves unreliable across build configs, fall back to
using `xcrun simctl launch --console` combined with a simple stdout-based signal from
the app. This would require modifying app templates and is out of scope for this plan.

### 2. Add `source` for the shared library

After `source init.sh` (line 13), add:
```bash
source "$SCRIPT_DIR/tools/apple_measure_lib.sh"
```

### 3. Extract CFBundleExecutable from Info.plist

The iOS simulator script already extracts `BUNDLE_ID` (lines 343-356) but does NOT
currently extract `CFBundleExecutable`. Add this extraction for the log stream predicate.

After the existing `BUNDLE_ID` extraction block (around line 356), add:
```bash
EXECUTABLE_NAME=""
if [ -f "$PLIST_PATH" ]; then
    EXECUTABLE_NAME=$(/usr/libexec/PlistBuddy -c "Print :CFBundleExecutable" "$PLIST_PATH" 2>/dev/null || true)
fi
if [ -z "$EXECUTABLE_NAME" ]; then
    EXECUTABLE_NAME=$(basename "$APP_BUNDLE" .app)
    echo "Warning: Could not read CFBundleExecutable, using fallback: $EXECUTABLE_NAME"
fi
echo "Executable: $EXECUTABLE_NAME"
```

**Note:** iOS simulator `.app` bundles have a flat structure — Info.plist is at
`$APP_BUNDLE/Info.plist` (not `Contents/Info.plist` like macOS). The script already
uses this correct path at line 344.

### 4. Replace the measurement loop (lines 382-419)

Replace the loop body with log-stream-based timing:

```bash
for ((i = 1; i <= ITERATIONS; i++)); do
    # Clean state: terminate any running instance and uninstall
    xcrun simctl terminate "$SIM_UDID" "$BUNDLE_ID" 2>/dev/null || true
    xcrun simctl uninstall "$SIM_UDID" "$BUNDLE_ID" 2>/dev/null || true

    # Fresh install
    xcrun simctl install "$SIM_UDID" "$APP_BUNDLE" 2>/dev/null
    if [ $? -ne 0 ]; then
        echo "  [$i/$ITERATIONS] FAILED — could not install app"
        FAILED_COUNT=$((FAILED_COUNT + 1))
        continue
    fi

    # Start log stream BEFORE launching the app
    start_log_stream "$EXECUTABLE_NAME"

    # Capture start timestamp
    START_NS=$(get_timestamp_ns)

    # Launch the app
    xcrun simctl launch "$SIM_UDID" "$BUNDLE_ID" > /dev/null 2>&1
    LAUNCH_RESULT=$?

    if [ $LAUNCH_RESULT -ne 0 ]; then
        stop_log_stream
        echo "  [$i/$ITERATIONS] FAILED — simctl launch returned $LAUNCH_RESULT"
        FAILED_COUNT=$((FAILED_COUNT + 1))
        continue
    fi

    # Wait for the app's first log event (indicates runtime initialization)
    TIMEOUT=30
    DEADLINE=$((SECONDS + TIMEOUT))
    FOUND=false
    while [ $SECONDS -lt $DEADLINE ]; do
        if [ -s "$LOG_STREAM_FILE" ]; then
            FIRST_EVENT=$(parse_first_log_event "$LOG_STREAM_FILE" "$EXECUTABLE_NAME")
            if [ -n "$FIRST_EVENT" ]; then
                FOUND=true
                break
            fi
        fi
        sleep 0.1
    done

    END_NS=$(get_timestamp_ns)
    stop_log_stream

    if [ "$FOUND" = false ]; then
        echo "  [$i/$ITERATIONS] FAILED — no log events within ${TIMEOUT}s"
        xcrun simctl terminate "$SIM_UDID" "$BUNDLE_ID" 2>/dev/null || true
        FAILED_COUNT=$((FAILED_COUNT + 1))
        continue
    fi

    ELAPSED_MS=$(elapsed_ms "$START_NS" "$END_NS")
    TIMES+=("$ELAPSED_MS")

    echo "  [$i/$ITERATIONS] ${ELAPSED_MS} ms"

    # Terminate before next iteration
    xcrun simctl terminate "$SIM_UDID" "$BUNDLE_ID" 2>/dev/null || true

    # Brief pause between iterations to let the simulator settle
    sleep 1
done
```

**Design decisions:**
- **Timing endpoint:** We use `END_NS` (wall-clock time when event is detected in the
  file) rather than parsing the log event's own timestamp. This avoids clock synchronization
  issues between wall-clock and log timestamps. The 100ms polling adds noise but is
  consistent across all build configs.
- **Log stream per iteration:** Start/stop log stream for each iteration to avoid
  log accumulation. The 0.5s `start_log_stream` setup delay is before `START_NS`.
- **Temp file cleanup:** `stop_log_stream` removes the temp file.

### 5. Update the cleanup function (lines 363-368)

Replace:
```bash
cleanup() {
    echo ""
    echo "--- Cleaning up ---"
    xcrun simctl terminate "$SIM_UDID" "$BUNDLE_ID" 2>/dev/null || true
    xcrun simctl uninstall "$SIM_UDID" "$BUNDLE_ID" 2>/dev/null || true
}
```

With:
```bash
cleanup() {
    echo ""
    echo "--- Cleaning up ---"
    stop_log_stream
    xcrun simctl terminate "$SIM_UDID" "$BUNDLE_ID" 2>/dev/null || true
    xcrun simctl uninstall "$SIM_UDID" "$BUNDLE_ID" 2>/dev/null || true
}
```

### 6. Replace statistics, summary output, and CSV save

Same changes as Plans 003/004:
- `STATS=$(compute_stats "${TIMES[@]}")`
- `print_measurement_summary "$AVG" "$MIN" "$MAX" "$PACKAGE_SIZE_MB" "$PACKAGE_SIZE_BYTES"`
- `save_results_csv "$RESULT_FILE" "$SAMPLE_APP" "$BUILD_CONFIG" "ios-simulator" ...`

Filename: `"${SAMPLE_APP}_${BUILD_CONFIG}_simulator.csv"` (unchanged).

### 7. Update the script header comment

```bash
#!/bin/bash

# Measures iOS Simulator startup time using OS log event timing.
#
# This script measures iOS Simulator app startup by launching the app via
# `xcrun simctl launch` and monitoring `log stream` for the first runtime
# log event emitted by the app process. This captures the startup pipeline:
# process creation, dyld loading, runtime initialization, and framework setup.
#
# The script bypasses dotnet/performance's test.py (which only supports
# physical iOS devices) and uses direct simulator interaction.
```

---

## Acceptance Criteria

1. **Correct timing methodology:**
   - Running with `CORECLR_JIT` vs `R2R_COMP` should show meaningfully different
     startup times (not all ~300ms as before)
   - Different build configs should show meaningful variance in startup time
   - Measured times should be larger than the old ~300ms (which was just IPC overhead)

2. **Output format unchanged:**
   - `"Generic Startup | avg | min | max"` line present
   - `"APP size: X MB (Y bytes)"` line present (exactly once)
   - `measure_all.sh --platform ios-simulator` works without modification

3. **Log stream lifecycle:**
   - Log stream is started before each launch and stopped after measurement/failure
   - Cleanup trap stops any remaining log stream on script exit
   - All temp files are cleaned up (no `/tmp/apple_measure_log.*` left behind)

4. **Error handling:**
   - Log event timeout (30s) produces clear error and marks iteration as failed
   - Install failure and launch failure handled (preserved from original)
   - Failed iterations counted and reported in summary

5. **Shared library integration:**
   - Script sources `tools/apple_measure_lib.sh`
   - Uses `start_log_stream`, `stop_log_stream`, `parse_first_log_event`,
     `get_timestamp_ns`, `elapsed_ms`, `compute_stats`, `print_measurement_summary`,
     `save_results_csv`

---

## Dependencies

- **Plan 002** (shared library — log stream functions especially)
- **Plan 003** (macOS fix — should be completed first to validate shared library works.
  Any shared library bugs found during Plan 003 should be fixed before starting Plan 005.)

---

## Risks

### High: Log event reliability across build configs

This is the **highest-risk item in the entire plan**. The specific log events emitted
by .NET apps in the simulator may vary between:
- **.NET runtime**: Mono vs CoreCLR emit different log messages at different stages
- **Build config**: AOT apps may not emit the same log events as JIT apps
- **App template**: `dotnet-new-ios` (UIKit) vs `dotnet-new-maui` (MAUI) may differ
- **.NET version**: net9.0 vs net11.0 may change log behavior

**Mitigation:** The implementer MUST do exploratory testing with at least 3 build
configs (MONO_JIT, CORECLR_JIT, R2R_COMP) and 2 app templates before committing to
a specific log predicate. If no single predicate works reliably, escalate to the
fallback approach (documented below).

### Medium: Log stream buffering latency

`log stream` has inherent buffering — there may be 50-200ms delay between the app
emitting a log entry and the stream delivering it to the temp file. This adds a
**systematic bias** (constant offset) to all measurements, which is acceptable for
relative comparisons between configs but means absolute numbers may differ from
physical device measurements.

### Medium: Log stream `sleep 0.5` setup overhead

The `start_log_stream` function sleeps 0.5s to let the stream connect. This is
BEFORE `START_NS` is captured, so it doesn't add to measured time, but it does add
0.5s per iteration to total wall-clock runtime. For 10 iterations, that's 5s overhead.
This is acceptable.

### Low: Simulator boot warmup

After booting a cold simulator, the first measurement may be an outlier due to system
cache warming. The existing script doesn't have a warmup iteration. Consider adding
one (run launch + terminate once before the measurement loop begins) — but this is
optional and can be a follow-up.

### Fallback: `xcrun simctl launch --console`

If log-based timing proves too unreliable, an alternative approach:
1. Use `xcrun simctl launch --console <UDID> <BundleID>` which connects stdout/stderr
2. Have the .NET app write a timestamp to stdout when it finishes initializing
3. Parse the stdout output to detect startup completion

This requires **modifying the app templates** to add a startup-complete log line,
which is a larger change. Create a separate plan for this if needed.

---

## Testing Strategy

### Manual Testing Checklist

1. **Build and run with MONO_JIT:**
   ```bash
   ./ios/measure_simulator_startup.sh dotnet-new-ios MONO_JIT --startup-iterations 3
   ```
   Verify: Output shows ~3 measurements, times are in hundreds-of-ms range.

2. **Build and run with CORECLR_JIT:**
   ```bash
   ./ios/measure_simulator_startup.sh dotnet-new-ios CORECLR_JIT --startup-iterations 3
   ```
   Verify: Times differ meaningfully from MONO_JIT.

3. **Build and run with R2R_COMP:**
   ```bash
   ./ios/measure_simulator_startup.sh dotnet-new-ios R2R_COMP --startup-iterations 3
   ```
   Verify: Times differ from CORECLR_JIT (typically faster for cold start).

4. **Run via measure_all.sh:**
   ```bash
   ./measure_all.sh --platform ios-simulator --startup-iterations 3 --app dotnet-new-ios
   ```
   Verify: `results/summary.csv` has valid rows with different avg times per config.

5. **Verify cleanup:**
   ```bash
   ls /tmp/apple_measure_log.*
   ```
   Should return empty (no leftover temp files).
