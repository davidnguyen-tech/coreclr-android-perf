# Performance Submodule — Device Type Values & Simulator/Emulator Support

Research into what `--device-type` values `test.py` accepts in the dotnet/performance submodule,
how each code path works, and whether simulator/emulator is supported.

---

## Architecture

### Submodule Location & Status

- **Submodule**: `external/performance` → `https://github.com/dotnet/performance.git`
- **Config**: `.gitmodules` (line 1-3)
- **Not initialized** in the `apple-agents` worktree; investigated via the `ios-measurements` worktree at:
  `/Users/nguyendav/repos/coreclr-android-perf.worktrees/ios-measurements/external/performance/`

### Entry Point Flow

```
measure_startup.sh
  └─ python3 test.py devicestartup --device-type <TYPE> --package-path ... --package-name ...
       └─ shared/runner.py  →  Runner.parseargs()  →  Runner.run()
```

---

## Key Files

| File | Path (relative to `external/performance/src/scenarios/`) | Purpose |
|------|----------------------------------------------------------|---------|
| `runner.py` | `shared/runner.py` | Central argument parser + test runner; all device type logic |
| `const.py` | `shared/const.py` | String constants (`DEVICESTARTUP = "devicestartup"`, etc.) |
| `androidhelper.py` | `shared/androidhelper.py` | Android-specific ADB device setup/teardown |
| `util.py` | `shared/util.py` | `xharnesscommand()`, `xharness_adb()` helpers |
| `startup.py` | `shared/startup.py` | Startup trace parser (parses `runoutput.trace`) |
| `testtraits.py` | `shared/testtraits.py` | TestTraits class; lists valid test types |
| `test.py` | `genericandroidstartup/test.py` | Android scenario entry point |
| `test.py` | `genericiosstartup/test.py` | iOS scenario entry point |

---

## Device Type Values — What `--device-type` Accepts

### `devicestartup` subcommand (line 71 of `shared/runner.py`)

```python
devicestartupparser.add_argument('--device-type', choices=['android','ios'], ...)
```

**Only two values are accepted: `android` and `ios`.**

There is **no** `osx`, `maccatalyst`, `simulator`, or `emulator` option.

### Other subcommands

| Subcommand | `--device-type` choices | Line |
|------------|------------------------|------|
| `devicestartup` | `['android', 'ios']` | 71 |
| `devicememoryconsumption` | `['android']` | 85 |
| `devicepowerconsumption` | `['android']` | 103 (comment notes: "Only android is supported for now") |

---

## Code Path Branching by Device Type

### Android path (`runner.py` line 519)

```python
elif self.testtype == const.DEVICESTARTUP and self.devicetype == 'android':
```

- Uses `AndroidHelper` for full ADB-based device setup
- Installs via `xharness android install`
- Launches via `adb shell am start-activity -W -n <activity>`
- Captures startup time from `logcat` using regex on `Displayed` / `Fully drawn` messages
- Stops via `adb shell am force-stop`
- Uninstalls after measurement

### iOS path (`runner.py` line 695)

```python
elif self.testtype == const.DEVICESTARTUP and self.devicetype == 'ios':
```

- Gets device info via `xharness apple state` (parses Connected Devices output)
- Installs via `xharness apple install --target ios-device` (line 738, **hardcoded**)
- Launches via `xharness apple mlaunch -- --launchdev <path> --devname <UDID>` (line 756-759)
- Collects logs via `sudo log collect --device` (line 803-811)
- Measures startup from SpringBoard Watchdog events:
  - 4 events: 2 for time-to-main, 2 for time-to-first-draw
  - Total startup = time-to-main + time-to-first-draw
- Kills via `xharness apple mlaunch -- --killdev=<PID>`
- Uninstalls via `xharness apple uninstall --target ios-device` (line 943, **hardcoded**)

### macOS / Mac Catalyst — **NO CODE PATH EXISTS**

There is no `elif self.testtype == const.DEVICESTARTUP and self.devicetype == 'osx':` or equivalent.
The upstream dotnet/performance repo has **zero** support for macOS or Mac Catalyst device startup measurement.

---

## Scenario Directories

### Existing in the submodule

| Directory | Has `test.py` | Used by our repo? |
|-----------|--------------|-------------------|
| `genericandroidstartup/` | ✅ | ✅ (`init.sh` line 37) |
| `genericiosstartup/` | ✅ | ✅ (`init.sh` line 45) |
| `mauiandroid/` | ✅ | ❌ |
| `mauiios/` | ✅ | ❌ |
| `mauimaccatalyst/` | ✅ | ❌ |
| `mauidesktop/` | ✅ | ❌ |
| `helloandroid/` | ✅ | ❌ |
| `helloios/` | ✅ | ❌ |

### Missing (referenced by our `init.sh` but don't exist upstream)

| Directory | Referenced in `init.sh` | Exists upstream? |
|-----------|------------------------|-----------------|
| `genericmacosstartup/` | Line 54 | ❌ |
| `genericmaccatalyststartup/` | Line 63 | ❌ |

**These directories must be created locally** as thin wrappers (like `genericiosstartup/test.py`).

---

## Simulator / Emulator Support

### Summary: **NOT SUPPORTED**

- Zero references to `simulator`, `simctl`, or `emulator` in the `shared/` Python code
- The `--device-type` argument has no `simulator`/`emulator` variant
- The iOS path hardcodes `--target ios-device` for xharness install/uninstall
- The iOS path uses `--launchdev` (device launch), not `--launchsim` (simulator launch)
- The iOS path parses `Connected Devices:` output from `xharness apple state`
- The iOS log collection uses `sudo log collect --device` (physical device log stream)
- Android uses physical ADB commands throughout

### What would be needed for simulator/emulator support

1. **New `--device-type` choices**: Add `'ios-simulator'` and `'android-emulator'` to the argparse choices
2. **iOS simulator**:
   - Change xharness target from `ios-device` to `ios-simulator-64` or `ios-simulator`
   - Use `--launchsim` instead of `--launchdev`
   - Use `xcrun simctl` for device management
   - Log collection would need different approach (no `--device` flag for simulator logs)
3. **Android emulator**:
   - RID changes from `android-arm64` to `android-x64` (for x86_64 emulator) or stays `android-arm64` (for ARM emulator)
   - ADB commands might work unchanged if emulator is connected via ADB
   - Startup timing may differ significantly (not representative of real device)

---

## How `measure_startup.sh` Invokes `test.py`

From `measure_startup.sh` lines 153-157:

```bash
python3 test.py devicestartup \
    --device-type "$PLATFORM_DEVICE_TYPE" \
    --package-path "$PACKAGE_PATH" \
    --package-name "$PACKAGE_NAME" \
    "$@"
```

`PLATFORM_DEVICE_TYPE` is set by `resolve_platform_config()` in `init.sh`:

| Platform | `PLATFORM_DEVICE_TYPE` | `PLATFORM_SCENARIO_DIR` |
|----------|----------------------|------------------------|
| `android` | `"android"` (line 35) | `genericandroidstartup` |
| `ios` | `"ios"` (line 44) | `genericiosstartup` |
| `osx` | `"osx"` (line 53) | `genericmacosstartup` ⚠️ doesn't exist |
| `maccatalyst` | `"maccatalyst"` (line 62) | `genericmaccatalyststartup` ⚠️ doesn't exist |

**Problem**: `init.sh` passes `"osx"` and `"maccatalyst"` as device types, but `runner.py` only
accepts `['android', 'ios']`. Passing `"osx"` or `"maccatalyst"` will cause an argparse error.

---

## iOS Measurement Technique Details

The iOS startup measurement uses **SpringBoard Watchdog events** (lines 826-837):

1. OS starts the app → Watchdog begins monitoring with 20s timeout
2. App loads dylibs, calls `main()` → Watchdog stops ("time-to-main")
3. Watchdog begins monitoring again → App draws first frame → Watchdog stops ("time-to-first-draw")
4. Total startup = time-to-main + time-to-first-draw

Events are collected via:
```bash
log show --predicate '(process == "SpringBoard") && (category == "Watchdog")' \
  --info --style ndjson <logarchive>
```

This technique:
- ✅ Works on physical iOS devices
- ❌ Would NOT work on simulators (SpringBoard Watchdog events are device-only)
- ❓ Unknown if it works on Mac Catalyst (SpringBoard doesn't exist on macOS)

---

## Risks & Implications

1. **macOS / Mac Catalyst need entirely new measurement code** — cannot reuse iOS or Android paths
2. **Scenario directories must be created** — `genericmacosstartup/` and `genericmaccatalyststartup/`
3. **`runner.py` must be modified** — either:
   - Add `'osx'` and `'maccatalyst'` to the `choices` list and add new `elif` branches, OR
   - Bypass `test.py` entirely for macOS/maccatalyst with custom measurement scripts
4. **macOS/maccatalyst measurement approach** — since these run locally, options include:
   - Direct `open -a <app>` + timing via process launch observation
   - `xcrun devicectl` (only for iOS devices, not applicable)
   - Custom timing using `NSLog` markers + `log show`
   - Process-level timing with `time` or `dtrace`
5. **Submodule modification** — changing `runner.py` means maintaining a fork of dotnet/performance, or submitting upstream PRs
