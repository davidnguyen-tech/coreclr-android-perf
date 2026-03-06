# measure_startup.sh: iOS Simulator Routing

## Summary

`measure_startup.sh` currently rejects `--platform ios-simulator` with an error (line 67–72), directing users to call `ios/measure_simulator_startup.sh` manually. Meanwhile, `measure_all.sh` already routes to the simulator script transparently (line 138–144). The guard in `measure_startup.sh` is a **necessary technical constraint**, not a lazy workaround — but it *can* be improved with transparent routing.

## Architecture

### How `measure_startup.sh` works

1. Parses `--platform` from args; everything else goes to `PASSTHROUGH_ARGS` (lines 46–64)
2. Calls `resolve_platform_config "$PLATFORM"` → sets `PLATFORM_DEVICE_TYPE`, `PLATFORM_TFM`, `PLATFORM_RID`, etc. (line 75)
3. Builds the app with `dotnet build` (lines 106–109)
4. Finds the built package via `PLATFORM_PACKAGE_GLOB` (line 117)
5. Calls `python3 test.py devicestartup --device-type "$PLATFORM_DEVICE_TYPE" ...` (lines 161–165)

The critical detail: it passes `$PLATFORM_DEVICE_TYPE` directly to test.py's `--device-type` argument.

### Why test.py can't handle `ios-simulator`

The dotnet/performance `runner.py` (line 71) hardcodes the allowed device types:

```python
devicestartupparser.add_argument('--device-type', choices=['android','ios'], ...)
```

Only `android` and `ios` are valid. There is no `ios-simulator` choice. argparse would reject it immediately.

Furthermore, the iOS device startup flow in `runner.py` (lines 695–870) is hardwired for **physical devices**:
- Uses `xharness apple mlaunch -- --launchdev` (line 757) — the `--launchdev` flag is for physical devices only
- Uses `sudo log collect --device` (lines 802–810) — collects system logs from a USB-connected physical device
- Parses SpringBoard Watchdog events from device logs to compute startup timing (lines 825–856)
- Uses `xharness apple install --target ios-device` (line 737)

None of this works on a simulator. The simulator has no USB connection, no `--device` flag for `log collect`, and the `--launchdev` mlaunch flag doesn't apply.

### How `ios/measure_simulator_startup.sh` works instead

This script (461 lines) is a completely self-contained measurement tool:
- Takes `<app-name> <build-config>` positional args, plus `--startup-iterations`, `--simulator-name`, `--simulator-udid`, `--no-build` options (lines 70–121)
- Calls `resolve_platform_config "ios-simulator"` itself (line 126)
- Builds the app itself via `dotnet build` (lines 264–269)
- Detects/boots a simulator via `xcrun simctl` (lines 146–248)
- Measures startup using wall-clock timing around `xcrun simctl launch` (lines 360–385)
- Computes statistics in Python (lines 398–414)
- Outputs a `Generic Startup | <avg> | <min> | <max>` line (line 440) — this format is what `measure_all.sh` parses

### How `measure_all.sh` already routes correctly

```bash
# measure_all.sh lines 138-144
if [ "$PLATFORM_DEVICE_TYPE" = "ios-simulator" ]; then
    OUTPUT=$("$SCRIPT_DIR/ios/measure_simulator_startup.sh" "$app" "$config" \
        --startup-iterations "$ITERATIONS" "${EXTRA_ARGS[@]}" 2>&1)
else
    OUTPUT=$("$SCRIPT_DIR/measure_startup.sh" "$app" "$config" \
        --platform "$PLATFORM" --startup-iterations "$ITERATIONS" "${EXTRA_ARGS[@]}" 2>&1)
fi
```

It checks `PLATFORM_DEVICE_TYPE` (set by `resolve_platform_config`) and dispatches accordingly.

## Key Question: Can `measure_startup.sh` do the same routing?

**Yes, absolutely.** The argument interfaces are compatible enough:

### Argument mapping

| `measure_startup.sh` accepts | `ios/measure_simulator_startup.sh` accepts | Compatible? |
|---|----|---|
| `$1` (app name) | `$1` (app name) | ✅ Identical |
| `$2` (build config) | `$2` (build config) | ✅ Identical |
| `--startup-iterations N` | `--startup-iterations N` | ✅ Identical |
| `--platform <val>` | N/A (hardcoded to ios-simulator) | ✅ Not needed |
| `--disable-animations` | N/A | ⚠️ Ignored (irrelevant for sim) |
| `--use-fully-drawn-time` | N/A | ⚠️ Not supported |
| `--trace-perfetto` | N/A | ⚠️ Not supported |
| N/A | `--simulator-name` | ℹ️ Sim-specific |
| N/A | `--simulator-udid` | ℹ️ Sim-specific |
| N/A | `--no-build` | ℹ️ Sim-specific |

The core shared arguments (app name, build config, startup iterations) are identical. The simulator script also handles its own build, package discovery, and measurement — it's fully self-contained and doesn't need anything from `measure_startup.sh`'s build/measure flow.

### What changes would be needed

In `measure_startup.sh`, replace the error guard (lines 66–72) with a routing dispatch:

```bash
# Instead of:
if [[ "$PLATFORM" == "ios-simulator" ]]; then
    echo "Error: --platform ios-simulator is not supported..."
    exit 1
fi

# Do:
if [[ "$PLATFORM" == "ios-simulator" ]]; then
    # Route to dedicated simulator script — test.py doesn't support simulators
    exec "$SCRIPT_DIR/ios/measure_simulator_startup.sh" "$SAMPLE_APP" "$BUILD_CONFIG" \
        --startup-iterations "${STARTUP_ITERATIONS:-10}" "${PASSTHROUGH_ARGS[@]}"
fi
```

One wrinkle: `measure_startup.sh` currently doesn't extract `--startup-iterations` from `PASSTHROUGH_ARGS` — it just passes everything through to `test.py`. The routing would need to forward the passthrough args, which already contain `--startup-iterations` if the user specified it. The simulator script will parse them correctly since it accepts `--startup-iterations`.

Actually, the simplest approach: just forward all remaining args as-is:

```bash
if [[ "$PLATFORM" == "ios-simulator" ]]; then
    exec "$SCRIPT_DIR/ios/measure_simulator_startup.sh" "$SAMPLE_APP" "$BUILD_CONFIG" \
        "${PASSTHROUGH_ARGS[@]}"
fi
```

This works because `PASSTHROUGH_ARGS` already contains everything except `--platform` (which was extracted at lines 48–63). The simulator script will handle `--startup-iterations` and any unknown args will cause it to error with its own usage message.

## Assessment

**The routing should be added.** There is no technical reason to reject `ios-simulator` — the guard exists only because test.py can't handle it, but the solution (routing to the simulator script) is trivial and already proven by `measure_all.sh`. The change is ~5 lines: replace the error block with an `exec` dispatch to the simulator script, forwarding the positional args and passthrough args.

### Risks
- **Low**: Unsupported passthrough args (e.g., `--trace-perfetto`, `--disable-animations`) would be rejected by the simulator script with an "Unknown option" error. This is actually *better* UX than silently ignoring them.
- **None**: The simulator script is self-contained — it builds, deploys, measures, and reports independently. No shared state to worry about.

## Key Files

| File | Lines | Role |
|------|-------|------|
| `measure_startup.sh` | 66–72 | Current ios-simulator guard (to be replaced) |
| `measure_startup.sh` | 46–64 | Arg parsing — extracts `--platform`, rest goes to `PASSTHROUGH_ARGS` |
| `measure_startup.sh` | 161–165 | test.py invocation with `--device-type` |
| `measure_all.sh` | 138–144 | Existing ios-simulator routing pattern to replicate |
| `ios/measure_simulator_startup.sh` | 70–121 | Arg parsing interface |
| `ios/measure_simulator_startup.sh` | 440 | Output format (`Generic Startup \| avg \| min \| max`) |
| `external/performance/.../runner.py` | 71 | `choices=['android','ios']` — no simulator support |
| `external/performance/.../runner.py` | 695–870 | iOS physical device measurement flow |
| `init.sh` | 53–73 | `resolve_platform_config` for ios/ios-simulator |
