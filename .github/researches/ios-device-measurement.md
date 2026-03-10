# iOS Physical Device Measurement — Broken State & Fix Path

Deep investigation of the `--platform ios` (physical device) measurement path: what's broken,
why, and how to fix it by following the pattern established by the other Apple platforms.

---

## Architecture: What Happens Today When You Run `--platform ios`

### The Broken Flow

```
measure_startup.sh --platform ios
  ├── Routing check: ios-simulator? → NO (line 97)
  ├── Routing check: osx? → NO (line 107)
  ├── Routing check: maccatalyst? → NO (line 117)
  ├── Falls through to generic test.py path (line 272-282)
  │
  ├── resolve_platform_config "ios"  (init.sh line 53-73)
  │     PLATFORM_TFM = "net11.0-ios"
  │     PLATFORM_RID = "ios-arm64"
  │     PLATFORM_DEVICE_TYPE = "ios"
  │     PLATFORM_SCENARIO_DIR = "$SCENARIOS_DIR/genericiosstartup"  ← DOES NOT EXIST
  │     PLATFORM_PACKAGE_GLOB = "*.app"
  │     PLATFORM_PACKAGE_LABEL = "APP"
  │
  ├── cd "$PLATFORM_SCENARIO_DIR"  (line 272)
  │     → FAILS: directory doesn't exist → exits with error
  │
  └── (never reached) python3 test.py devicestartup --device-type ios ...
```

**First failure point**: `cd "$PLATFORM_SCENARIO_DIR"` at `measure_startup.sh:272` fails because
`external/performance/src/scenarios/genericiosstartup/` does not exist in the dotnet/performance
submodule. The error message is: `"Error: dotnet/performance scenario directory not found."`

### If the Directory DID Exist (the second failure)

Even if `genericiosstartup/` were created, the `test.py devicestartup --device-type ios` path in
`runner.py` uses `sudo log collect --device` (line 802-810) which requires passwordless sudo
(via sudoer entry) — blocks on the password prompt if not configured, which was mistakenly
reported as a hang.

### `measure_all.sh` Has the Same Problem

In `measure_all.sh` (lines 148-160), the dispatch logic:
- `ios-simulator` → dedicated `ios/measure_simulator_startup.sh` ✅
- `osx` → dedicated `osx/measure_osx_startup.sh` ✅
- `maccatalyst` → dedicated `maccatalyst/measure_maccatalyst_startup.sh` ✅
- **Everything else** (including `ios` device) → `measure_startup.sh` → broken test.py path ❌

The `PLATFORM_DEVICE_TYPE` for `ios` is `"ios"` (not `"ios-simulator"`), so it hits the `else`
branch and falls through to `measure_startup.sh`.

---

## The Missing Scenario Directory

### Verification

Searched `external/performance/src/scenarios/` for `genericiosstartup`:
- `ls` of the directory: **not listed** (confirmed by `view` of the scenarios directory)
- `glob **/genericiosstartup/**`: **no matches**
- `glob genericios*`: **no matches**

Other scenario directories that DO exist for iOS in the submodule:
- `mauiios/test.py` — EXENAME = `'MauiiOSDefault'`
- `helloios/test.py` — EXENAME = `'HelloiOS'`
- `netios/test.py` — EXENAME = `'NetiOSDefault'`

These are all specific app scenarios, NOT a generic startup scenario.

Similarly missing for macOS/Mac Catalyst:
- `genericmacosstartup/` (referenced at `init.sh:79`) — ❌ does not exist
- `genericmaccatalyststartup/` (referenced at `init.sh:88`) — ❌ does not exist

**Note**: The macOS and Mac Catalyst paths never hit this because they're routed to dedicated
scripts before reaching the `cd "$PLATFORM_SCENARIO_DIR"` line. Only iOS device hits this bug.

---

## The `sudo log collect --device` Sudo Requirement (runner.py)

### What runner.py Does for iOS Device

File: `external/performance/src/scenarios/shared/runner.py`, lines 695-961

The iOS device measurement flow:

1. **Device detection** (lines 712-730): `xharness apple state` → parse `Connected Devices:` output
   for device name, UDID, and version

2. **App install** (lines 732-742): `xharness apple install --app <path> --target ios-device`

3. **Measurement loop** (lines 747-934): For each iteration:
   a. Wait 10 seconds between iterations (line 749)
   b. Launch via `xharness apple mlaunch -- --launchdev <path> --devname <UDID>` (lines 753-759)
   c. Parse PID from mlaunch stdout (lines 793-797)
   d. Wait 5 seconds for app to start (line 800)
   e. **Collect device logs** (lines 802-810):
      ```python
      collectCmd = [
          'sudo', 'log', 'collect', '--device',
          '--start', runCmdTimestamp.strftime("%Y-%m-%d %H:%M:%S%z"),
          '--output', logarchive_filename,
      ]
      ```
   f. Parse SpringBoard Watchdog events from the logarchive (lines 838-847)
   g. Kill app via `xharness apple mlaunch -- --killdev=<PID>` (lines 813-821)

4. **Uninstall** (lines 937-947): `xharness apple uninstall --app <bundleID> --target ios-device`

### Why `sudo log collect --device` Blocks Without Passwordless Sudo

`sudo log collect --device` collects logs from a connected iOS device. This command requires
sudo privileges and will prompt for a password. On modern macOS/iOS combinations, this command:
- Requires a device that's been "trusted" (developer mode enabled)
- May require the device to be connected via USB (not just WiFi)
- **Blocks on the sudo password prompt** if the terminal isn't interactive or passwordless sudo isn't configured — this was mistakenly reported as an indefinite hang, but with a passwordless sudoer entry it works fine
- Has no timeout mechanism — `runner.py` calls `RunCommand(collectCmd)` which blocks until the password prompt is resolved

This is a **known issue** in the dotnet/performance infrastructure — it requires passwordless
sudo configuration, which is non-trivial in CI environments. The alternative approaches are:
1. Use `log stream --device` (streaming, not collecting — needs to be started BEFORE launch)
2. Use `xcrun devicectl device log` (newer API, Xcode 15+)
3. Bypass log collection entirely and use alternative timing mechanisms

---

## How Working Apple Platforms Measure Startup

### Common Pattern

All three working Apple platforms follow the **same architecture**:

```
Platform-specific script (e.g., osx/measure_osx_startup.sh)
  ├── source init.sh + tools/apple_measure_lib.sh
  ├── Parse arguments (app name, build config, --startup-iterations, etc.)
  ├── resolve_platform_config "<platform>"
  ├── Build the app (or locate pre-built .app bundle)
  ├── Extract Info.plist metadata (bundle ID, executable name)
  ├── Optional: trace collection (extra iteration with EventPipe env vars)
  ├── Measurement loop (N iterations):
  │     ├── Clean state (terminate/uninstall previous instance)
  │     ├── START_NS = get_timestamp_ns()
  │     ├── Launch the app
  │     ├── Wait for startup completion indicator
  │     ├── END_NS = get_timestamp_ns()
  │     └── ELAPSED_MS = elapsed_ms(START_NS, END_NS)
  ├── compute_stats() → avg, median, min, max, stdev, count
  ├── print_measurement_summary() → "Generic Startup | avg | min | max"
  └── save_results_csv()
```

### Platform-Specific Differences

| Aspect | macOS (`osx`) | Mac Catalyst | iOS Simulator |
|--------|--------------|--------------|---------------|
| **Script** | `osx/measure_osx_startup.sh` | `maccatalyst/measure_maccatalyst_startup.sh` | `ios/measure_simulator_startup.sh` |
| **Launch** | `open "$APP_BUNDLE"` (line 387) | `open "$APP_BUNDLE"` (line 387) | `xcrun simctl launch "$SIM_UDID" "$BUNDLE_ID"` (line 529) |
| **Startup indicator** | `wait_for_window` — AppleScript polls System Events for window (line 397) | `wait_for_window` — same AppleScript (line 397) | `wait_for_log_event` — polls `log stream` for first process event (line 540) |
| **Install** | Not needed (runs from built location) | Not needed | `xcrun simctl install "$SIM_UDID" "$APP_BUNDLE"` (line 515) |
| **Terminate** | `kill <PID>` via ps lookup (line 283-298) | `kill <PID>` via ps lookup (line 283-298) | `xcrun simctl terminate "$SIM_UDID" "$BUNDLE_ID"` (line 511) |
| **Uninstall** | Not needed | Not needed | `xcrun simctl uninstall "$SIM_UDID" "$BUNDLE_ID"` (line 512) |
| **Info.plist path** | `$APP/Contents/Info.plist` | `$APP/Contents/Info.plist` | `$APP/Info.plist` (flat bundle) |
| **Executable path** | `$APP/Contents/MacOS/<name>` | `$APP/Contents/MacOS/<name>` | N/A (simctl handles it) |
| **Trace collection** | EventPipe env vars, direct exec of binary | EventPipe env vars, direct exec of binary | `SIMCTL_CHILD_` prefixed env vars via simctl |

### Key Library Functions Used (from `tools/apple_measure_lib.sh`)

| Function | macOS | Mac Catalyst | iOS Simulator | iOS Device (needed) |
|----------|-------|-------------|---------------|---------------------|
| `get_timestamp_ns()` | ✅ | ✅ | ✅ | ✅ |
| `elapsed_ms()` | ✅ | ✅ | ✅ | ✅ |
| `wait_for_window()` | ✅ | ✅ | ❌ | ❌ (device has no AppleScript) |
| `start_log_stream()` | ❌ | ❌ | ✅ | ❌ (host `log stream` doesn't see device) |
| `wait_for_log_event()` | ❌ | ❌ | ✅ | ❌ |
| `compute_stats()` | ✅ | ✅ | ✅ | ✅ |
| `print_measurement_summary()` | ✅ | ✅ | ✅ | ✅ |
| `save_results_csv()` | ✅ | ✅ | ✅ | ✅ |
| `setup_eventpipe_env()` | ✅ | ✅ | ❌ | ❌ |
| `setup_simctl_eventpipe_env()` | ❌ | ❌ | ✅ | ❌ |

---

## Proposed Approach: Dedicated `ios/measure_device_startup.sh`

### Strategy

Create a dedicated iOS device measurement script (`ios/measure_device_startup.sh`) following the
same pattern as the other three Apple platforms. This bypasses the broken `test.py` / `runner.py`
path entirely.

### Device Detection

Use `xcrun devicectl list devices` (Xcode 15+) to find connected physical devices:
```bash
xcrun devicectl list devices --json-output /dev/stdout 2>/dev/null
```
This returns JSON with device UDID, name, OS version, connection state. Parse with `python3`.

Alternatively, `xharness apple state` (already installed by `prepare.sh`) outputs:
```
Connected Devices:
   DEVICENAME UDID    VERSION    iPhone iOS
```

### App Installation

Use `xharness apple install` (same as runner.py):
```bash
xharness apple install --app "$APP_BUNDLE" --target ios-device -o "$TRACES_DIR" -v
```

Or `xcrun devicectl device install app`:
```bash
xcrun devicectl device install app --device "$DEVICE_UDID" "$APP_BUNDLE"
```

### App Launch

Use `xcrun devicectl device process launch` (Xcode 15+):
```bash
xcrun devicectl device process launch --device "$DEVICE_UDID" "$BUNDLE_ID"
```

This is the modern replacement for `xharness apple mlaunch -- --launchdev`. It:
- Returns immediately after the app is launched
- Outputs the PID of the launched process
- Does NOT require sudo like `sudo log collect --device`

### Timing Mechanism — SpringBoard Watchdog Events via `log stream`

The key insight from `runner.py` (lines 825-837) is that iOS measures startup via **SpringBoard
Watchdog events**. The problem is the log COLLECTION method (`sudo log collect --device`)
requiring passwordless sudo configuration, not the log ANALYSIS.

**Alternative: Use `log stream --device` instead of `log collect --device`.**

`log stream --device` is a streaming alternative that:
- Does NOT require `sudo`
- Runs in the background (like `start_log_stream` in the simulator script)
- Can be filtered with `--predicate`
- Outputs ndjson when `--style ndjson` is used
- Must be started BEFORE the app launch to catch events

Proposed flow:
```bash
# Start device log stream BEFORE launching the app
log stream --device --predicate '(process == "SpringBoard") && (category == "Watchdog")' \
    --style ndjson --level info > "$LOG_FILE" &
LOG_PID=$!
sleep 0.5  # settle

# Record start timestamp
START_NS=$(get_timestamp_ns)

# Launch the app
xcrun devicectl device process launch --device "$DEVICE_UDID" "$BUNDLE_ID"

# Wait for the 4 Watchdog events (or timeout)
# Parse events from the streaming log file
# ...

END_NS=$(get_timestamp_ns)
kill $LOG_PID
```

### Simpler Fallback: Wall-Clock Timing with devicectl

If SpringBoard Watchdog events prove unreliable via `log stream --device`, a simpler approach:

```bash
START_NS=$(get_timestamp_ns)
xcrun devicectl device process launch --device "$DEVICE_UDID" "$BUNDLE_ID"
# Wait for some startup indicator...
END_NS=$(get_timestamp_ns)
```

The challenge is detecting when the app has finished starting. Options:
1. **Fixed delay** (crude): Wait a fixed time after launch — not useful for measurement
2. **Device log stream for process events**: `log stream --device --predicate "process == \"$APP_NAME\""`
   — detect first log event from the app (similar to simulator approach)
3. **SpringBoard Watchdog** (precise): As described above — measures time-to-main + time-to-first-draw

### App Termination

Use `xcrun devicectl device process terminate`:
```bash
# Find the app PID from launch output or by listing processes
xcrun devicectl device process terminate --device "$DEVICE_UDID" --pid "$APP_PID"
```

Or kill via xharness:
```bash
xharness apple mlaunch -- --killdev="$APP_PID" --devname "$DEVICE_UDID"
```

### App Uninstall

```bash
xharness apple uninstall --app "$BUNDLE_ID" --target ios-device -o "$TRACES_DIR" -v
```

Or:
```bash
xcrun devicectl device uninstall app --device "$DEVICE_UDID" "$BUNDLE_ID"
```

---

## Routing Changes Needed

### `measure_startup.sh` (add routing for `ios`)

At line 96, add an `ios` routing block before the fallthrough (similar to lines 97-124):

```bash
# ios device: route to dedicated script — test.py's iOS path uses 'sudo log collect' which requires passwordless sudo
if [[ "$PLATFORM" == "ios" ]]; then
    IOS_ARGS=("$SAMPLE_APP" "$BUILD_CONFIG")
    if [ "$PREBUILT" = true ]; then
        IOS_ARGS+=("--package-path" "$PREBUILT_PACKAGE_PATH")
    fi
    exec "$SCRIPT_DIR/ios/measure_device_startup.sh" "${IOS_ARGS[@]}" "$@"
fi
```

### `measure_all.sh` (add routing for `ios` device type)

At line 148, add before the `else` fallthrough:

```bash
elif [ "$PLATFORM_DEVICE_TYPE" = "ios" ]; then
    OUTPUT=$("$SCRIPT_DIR/ios/measure_device_startup.sh" "$app" "$config" \
        --startup-iterations "$ITERATIONS" $COLLECT_TRACE_FLAG "${EXTRA_ARGS[@]}" 2>&1)
```

### `init.sh` (optional: update PLATFORM_SCENARIO_DIR)

The `PLATFORM_SCENARIO_DIR` for iOS (line 55) can be left as-is since the dedicated script won't
use it. But it should probably be updated or left empty to avoid confusion:

```bash
PLATFORM_SCENARIO_DIR=""  # iOS device uses ios/measure_device_startup.sh directly
```

---

## Build & Deployment for Physical iOS Devices

### RID and TFM

From `init.sh:65` and `ios/build-configs.props`:
- **RID**: `ios-arm64` (hardcoded — physical devices are always arm64)
- **TFM**: `net11.0-ios`

### Build Command

```bash
dotnet build -c Release -f net11.0-ios -r ios-arm64 \
    -bl:"$BUILD_DIR/${SAMPLE_APP}_${BUILD_CONFIG}_ios.binlog" \
    "$APP_DIR/$SAMPLE_APP.csproj" \
    -p:_BuildConfig="$BUILD_CONFIG"
```

### Build Configs (from `ios/build-configs.props`)

6 configs (no non-composite R2R, matching `measure_all.sh:83`):
1. `MONO_JIT` — UseMonoRuntime=True, RunAOTCompilation=False
2. `MONO_AOT` — UseMonoRuntime=True, RunAOTCompilation=True, MtouchProfiledAOT=False
3. `MONO_PAOT` — UseMonoRuntime=True, RunAOTCompilation=True
4. `CORECLR_JIT` — UseMonoRuntime=False, RunAOTCompilation=False
5. `R2R_COMP` — PublishReadyToRun=True, PublishReadyToRunComposite=True
6. `R2R_COMP_PGO` — Same + PGO=True

### Code Signing

Physical iOS devices require **code signing**. The build should handle this via:
- Xcode-managed signing (auto-provisioning) — `<CodesignKey>` and `<CodesignProvision>` in csproj
- Or manual signing with a development certificate

The `ios/build-configs.props` does NOT set any code signing properties — this means the developer's
default signing configuration (from Xcode or environment) is used.

**Risk**: If no valid provisioning profile is available, the build will produce an `.app` that cannot
be installed on a physical device. The simulator doesn't require signing.

### .app Bundle Location After Build

From `init.sh:57`: `PLATFORM_PACKAGE_GLOB="*.app"`

The `.app` bundle is found via:
```bash
find "$APP_DIR" -name "*.app" -path "*/Release/*" | head -1
```

Typical path: `apps/<app>/bin/Release/net11.0-ios/ios-arm64/<AppName>.app`

### .app Bundle Structure (iOS vs macOS)

iOS `.app` bundles have a **flat structure** (different from macOS):
- `<AppName>.app/Info.plist` (NOT `Contents/Info.plist`)
- `<AppName>.app/<executable>` (NOT `Contents/MacOS/<executable>`)
- `<AppName>.app/*.dylib`

This matches what `ios/measure_simulator_startup.sh` uses (line 368-369):
```bash
PLIST_PATH="$APP_BUNDLE/Info.plist"
```

---

## `tools/apple_measure_lib.sh` — What Exists and What's Needed

### Current Functions

| Function | Lines | Purpose | iOS Device Usable? |
|----------|-------|---------|---------------------|
| `get_timestamp_ns()` | 52-54 | High-res timestamp | ✅ |
| `elapsed_ms()` | 59-63 | Compute elapsed ms | ✅ |
| `wait_for_window()` | 90-118 | AppleScript window detection | ❌ (device has no AppleScript) |
| `start_log_stream()` | 144-157 | Start host `log stream` | ❌ (doesn't see device logs) |
| `stop_log_stream()` | 162-172 | Stop log stream | ✅ (generic cleanup) |
| `wait_for_log_event()` | 191-238 | Poll log stream file | ✅ (if log stream file exists) |
| `wait_for_process()` | 257-274 | Wait for process by name | ❌ (device process not on host) |
| `compute_stats()` | 297-334 | Statistics computation | ✅ |
| `run_buildtime_parser()` | 363-445 | Parse binlog build time | ✅ |
| `print_measurement_summary()` | 464-473 | Format output for measure_all.sh | ✅ |
| `save_results_csv()` | 501-526 | Save detailed CSV | ✅ |
| `setup_eventpipe_env()` | 555-563 | Set EventPipe env vars | ❌ (can't set env on device) |
| `unset_eventpipe_env()` | 568-573 | Unset EventPipe env vars | ✅ |
| `collect_nettrace()` | 590-635 | Find/copy .nettrace file | ❓ (device trace collection is different) |
| `setup_simctl_eventpipe_env()` | 649-657 | Set SIMCTL_CHILD_ env vars | ❌ (simulator-specific) |
| `unset_simctl_eventpipe_env()` | 661-666 | Unset SIMCTL_CHILD_ env vars | ❌ |

### Functions Needed for iOS Device

New functions to add to `apple_measure_lib.sh`:

1. **`start_device_log_stream()`** — Start `log stream --device` with a predicate,
   outputting to a temp file (similar to `start_log_stream()` but with `--device` flag)

2. **`wait_for_device_watchdog_events()`** — Poll the device log stream file for
   the 4 SpringBoard Watchdog events, parse timestamps, return timing data

3. **`parse_watchdog_timing()`** — Extract time-to-main and time-to-first-draw from
   4 Watchdog events (the logic from `runner.py` lines 874-931, ported to bash/python)

4. **Device detection** — Find connected iOS device UDID (could be inline in the script
   rather than a library function)

---

## Risks and Unknowns

### High Risk

1. **`log stream --device` reliability**: Unlike the host `log stream`, device log streaming may:
   - Have latency (events appear with delay)
   - Drop events under high load
   - Require the device to be connected via USB (not WiFi)
   - Need `--level info` to see SpringBoard Watchdog events (info level, not debug)
   
2. **Code signing**: Physical device builds require a valid Apple Developer certificate and
   provisioning profile. This works differently in CI vs. local development. No signing
   configuration exists in `ios/build-configs.props`.

3. **SpringBoard Watchdog event format changes**: The runner.py code was written for
   iOS 16-17. Newer iOS versions may change the Watchdog event format or timing. The
   event messages are parsed with string matching (`runner.py:880-890`), which is fragile.

### Medium Risk

4. **`xcrun devicectl` availability**: `xcrun devicectl` requires Xcode 15+. If the
   build machine has an older Xcode, this won't work. The `xharness apple mlaunch` approach
   is more broadly compatible but may have its own issues.

5. **Device clock synchronization**: The runner.py approach relies on the device clock being
   in sync with the host clock (line 868-869). If using device-side timestamps from
   Watchdog events, this is fine (delta between device events). But if correlating host
   timestamps with device events, clock skew is a problem.

6. **Multiple connected devices**: The script needs to handle the case where multiple
   iOS devices are connected, or no device is connected.

### Low Risk / Known Solutions

7. **`.app` bundle format**: iOS bundles use flat structure (`Info.plist` at root, not
   `Contents/Info.plist`). The simulator script already handles this correctly, so the
   device script can follow the same pattern.

8. **Output format compatibility**: The `print_measurement_summary()` function already
   produces the `"Generic Startup | avg | min | max"` format that `measure_all.sh` parses.

---

## Summary of Changes Needed

| Component | Change | Effort |
|-----------|--------|--------|
| `ios/measure_device_startup.sh` | **Create**: New dedicated script following Apple platform pattern | Major (~400 lines) |
| `tools/apple_measure_lib.sh` | **Add**: Device log stream + Watchdog parsing functions | Medium (~100 lines) |
| `measure_startup.sh` | **Add**: Routing block for `--platform ios` → dedicated script | Small (~8 lines) |
| `measure_all.sh` | **Add**: `elif` for `PLATFORM_DEVICE_TYPE == "ios"` | Small (~3 lines) |
| `init.sh` | **Optional**: Clear `PLATFORM_SCENARIO_DIR` for iOS device | Trivial |

### Recommended Implementation Order

1. Add device log stream helpers to `apple_measure_lib.sh`
2. Create `ios/measure_device_startup.sh` (without Watchdog — use simple wall-clock + device log events first)
3. Add routing in `measure_startup.sh` and `measure_all.sh`
4. Test basic flow with a physical device
5. Enhance with SpringBoard Watchdog event parsing for precise timing
6. Add trace collection support

---

## Key File References

| File | Lines | What |
|------|-------|------|
| `init.sh` | 53-73 | `resolve_platform_config "ios"` — sets PLATFORM_SCENARIO_DIR to non-existent dir |
| `measure_startup.sh` | 96-124 | Routing blocks for simulator/osx/maccatalyst — iOS device falls through |
| `measure_startup.sh` | 272 | `cd "$PLATFORM_SCENARIO_DIR"` — fails for iOS device |
| `measure_all.sh` | 148-160 | Dispatch logic — iOS device falls to `else` (measure_startup.sh) |
| `runner.py` | 695-961 | iOS device measurement (SpringBoard Watchdog + `sudo log collect --device`) |
| `runner.py` | 802-810 | The `sudo log collect --device` command that requires passwordless sudo |
| `runner.py` | 825-837 | SpringBoard Watchdog event documentation |
| `runner.py` | 874-931 | Watchdog event timestamp parsing and timing calculation |
| `ios/build-configs.props` | 1-55 | 6 build configs, all `ios-arm64` |
| `ios/measure_simulator_startup.sh` | 500-562 | Simulator measurement loop (reference pattern) |
| `osx/measure_osx_startup.sh` | 379-416 | macOS measurement loop (reference pattern) |
| `tools/apple_measure_lib.sh` | 144-157 | `start_log_stream()` — model for device log stream |
| `tools/apple_measure_lib.sh` | 464-473 | `print_measurement_summary()` — output format |
