# Plan 004: Fix Mac Catalyst Startup Measurement Timing

## Overview

Apply the same window-appearance timing fix to `maccatalyst/measure_maccatalyst_startup.sh`
that was done for macOS in Plan 003. Mac Catalyst apps are native macOS `.app` bundles
with the same `Contents/MacOS/<exec>` structure, so the identical `wait_for_window`
approach works.

This script is nearly identical to the macOS script — the same set of changes applies.

---

## Files to Modify

| File | Change |
|------|--------|
| `maccatalyst/measure_maccatalyst_startup.sh` | Replace measurement loop + use shared library |

---

## Sub-steps

### 1. Add `source` for the shared library

After `source init.sh` (line 15), add:
```bash
source "$SCRIPT_DIR/tools/apple_measure_lib.sh"
```

### 2. Replace the measurement loop (lines 299-328)

Same change as Plan 003 Step 2. Replace the loop body with:

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

### 3. Replace statistics computation

Replace inline Python statistics block with:
```bash
STATS=$(compute_stats "${TIMES[@]}")
```

Leave the `sed` parsing lines unchanged (same 6-line output format).

### 4. Replace summary output

Replace with:
```bash
print_measurement_summary "$AVG" "$MIN" "$MAX" "$PACKAGE_SIZE_MB" "$PACKAGE_SIZE_BYTES"
```

### 5. Replace CSV save

Replace with:
```bash
mkdir -p "$RESULTS_DIR"
RESULT_FILE="$RESULTS_DIR/${SAMPLE_APP}_${BUILD_CONFIG}_maccatalyst.csv"
save_results_csv "$RESULT_FILE" "$SAMPLE_APP" "$BUILD_CONFIG" "maccatalyst" \
    "$PACKAGE_SIZE_MB" "$PACKAGE_SIZE_BYTES" \
    "$AVG" "$MEDIAN" "$MIN" "$MAX" "$STDEV" "$COUNT" "${TIMES[@]}"
```

### 6. Update the script header comment

```bash
#!/bin/bash

# Measures Mac Catalyst app startup time using window-appearance timing.
#
# This script measures Mac Catalyst (.app bundle) startup by launching the
# app via `open` and waiting for the first visible window to appear (detected
# via System Events AppleScript). Mac Catalyst apps are native macOS .app
# bundles built from iOS/MAUI code, so the same window-detection technique
# used for macOS apps works here.
#
# NOTE: Requires Accessibility permission for the terminal app on first run.
```

---

## Acceptance Criteria

1. **Correct timing methodology:**
   - Running with `MONO_JIT` vs `R2R_COMP` should show meaningfully different
     startup times (not all ~80-100ms as before)
   - The 386MB R2R_COMP app should show different startup characteristics than
     the 77MB MONO_JIT app
   - Measured times should be in the hundreds-of-ms to seconds range

2. **Output format unchanged:**
   - `"Generic Startup | avg | min | max"` line present
   - `"APP size: X MB (Y bytes)"` line present (exactly once)
   - `measure_all.sh --platform maccatalyst` works without modification

3. **Shared library integration:**
   - Script sources `tools/apple_measure_lib.sh`
   - Uses all shared functions — no inline python timestamp calls remaining
   - Identical timing pattern to the macOS script (Plan 003)

4. **Parity with macOS script (Plan 003):**
   - Same timing technique, same error handling, same output format
   - Only differences: platform name strings (`maccatalyst` vs `osx`),
     file path conventions, script-specific help text

---

## Dependencies

- **Plan 002** (shared library — must exist)
- **Plan 003** (macOS fix — should be done first since it establishes the pattern.
  Any issues discovered during macOS implementation should be incorporated here.)

---

## Risks

- **Same risks as Plan 003** (System Events permission, osascript overhead, headless
  environments). See Plan 003 Risks section.

- **Mac Catalyst process name in System Events:** Mac Catalyst apps may report a
  different process name in System Events than native macOS apps. The implementer
  MUST verify that `EXECUTABLE_NAME` (from `CFBundleExecutable` in Info.plist) matches
  what System Events sees. Test with both:
  - `dotnet-new-maui` (MAUI template)
  - `dotnet-new-maui-samplecontent` (MAUI with sample content)
  
  Verification command (run while app is open):
  ```bash
  osascript -e 'tell application "System Events" to get name of every process whose visible is true'
  ```

- **Mac Catalyst windowing differences:** Mac Catalyst apps use UIKit's Mac Catalyst
  compatibility layer, which may have slightly different windowing behavior than native
  AppKit. The window may appear in System Events differently (e.g., as an
  `NSWindow` wrapper around `UIWindow`). If `wait_for_window` doesn't detect the window,
  the implementer should check if the process name or window property differs.
