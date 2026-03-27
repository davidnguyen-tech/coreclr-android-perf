# Platform Measurement Readiness Assessment

**Date:** 2025-01-20
**Goal:** Determine which platforms can run startup measurements RIGHT NOW on this Mac.

## Executive Summary

| Platform | Can Measure Now? | Blocker | Fix Difficulty |
|----------|-----------------|---------|----------------|
| **ios-simulator** | ✅ YES | — | Done |
| **osx** | ❌ NO | TWO blockers: missing scenario dir + test.py rejects `osx` device type | **Easy** — needs custom script like ios-simulator |
| **maccatalyst** | ❌ NO | TWO blockers: missing scenario dir + test.py rejects `maccatalyst` device type; also no apps generated yet | **Easy** — same fix pattern as osx |
| **ios (device)** | ❌ NO | No physical iPhone connected; scenario dir missing; needs `sudo` | **Hard** — hardware dependency |
| **android** | ❌ NO | No Android device/emulator; wrong workloads installed | **Hard** — hardware dependency |
| **android-emulator** | ❌ NO | Same as android | **Hard** — emulator setup needed |

**Key Insight:** `osx` and `maccatalyst` are the ONLY platforms that can be unlocked quickly on this Mac — they run apps directly on the host machine with no external device needed. Both need **custom measurement scripts** (following the `ios/measure_simulator_startup.sh` pattern) because test.py doesn't support them.

---

## Detailed Analysis

### 1. `ios-simulator` — ✅ WORKS

**Routing:** `measure_all.sh` line 138 checks `$PLATFORM_DEVICE_TYPE == "ios-simulator"` and routes directly to `ios/measure_simulator_startup.sh`, completely bypassing `measure_startup.sh` and test.py.

**Measurement method:** Wall-clock timing of `xcrun simctl launch` using `python3 time.time_ns()` for sub-millisecond precision (`ios/measure_simulator_startup.sh` lines 397-410).

**Apps available:** `dotnet-new-ios`, `dotnet-new-maui`, `dotnet-new-maui-samplecontent` — all generated with `net11.0-ios` TFM.

**Why it works:** Custom script — doesn't depend on test.py or scenario directories at all.

---

### 2. `osx` — ❌ BROKEN (Fixable, Easy)

**Failure chain (two independent blockers):**

1. **Blocker 1 — Missing scenario directory:**
   - `init.sh` line 79: `PLATFORM_SCENARIO_DIR="$SCENARIOS_DIR/genericmacosstartup"`
   - `measure_startup.sh` line 234: `cd "$PLATFORM_SCENARIO_DIR" || { echo "Error: ..."; exit 1; }`
   - **`genericmacosstartup/` does NOT exist** in `external/performance/src/scenarios/`
   - Only `genericandroidstartup/` exists. No iOS, macOS, or maccatalyst generic startup dirs.

2. **Blocker 2 — test.py rejects `osx` device type:**
   - `runner.py` line 71: `choices=['android','ios']` — only `android` and `ios` are valid
   - `init.sh` line 78: `PLATFORM_DEVICE_TYPE="osx"` — would be rejected by argparse
   - Even if the scenario dir existed, `python3 test.py devicestartup --device-type osx` would fail

**Apps:** No `dotnet-new-macos` app exists yet (apps were generated with `--platform ios-simulator`, not `--platform osx`). `prepare.sh --platform osx` has NOT been run.

**Workloads:** Not installed. `versions.log` shows only `ios` workload. `osx` needs `macos` workload.

**Fix approach:** Create `osx/measure_osx_startup.sh` following the `ios/measure_simulator_startup.sh` pattern. macOS .app bundles can be launched with:
```bash
open -W -n "$APP_BUNDLE"  # -W waits for app to exit, -n opens new instance
```
Or for startup-only timing:
```bash
open -a "$APP_BUNDLE"     # launches app (doesn't wait)
```
Then time with `python3 time.time_ns()`. After launch, kill with `kill` or `pkill`. Add routing in `measure_all.sh` similar to line 138-140.

**Prerequisites:** Run `prepare.sh --platform osx` first to install `macos` workload and generate `dotnet-new-macos` app.

---

### 3. `maccatalyst` — ❌ BROKEN (Fixable, Easy)

**Identical failure chain to `osx`:**

1. **Blocker 1 — Missing scenario directory:**
   - `init.sh` line 88: `PLATFORM_SCENARIO_DIR="$SCENARIOS_DIR/genericmaccatalyststartup"`
   - `genericmaccatalyststartup/` does NOT exist

2. **Blocker 2 — test.py rejects `maccatalyst` device type:**
   - `runner.py` line 71: `choices=['android','ios']`
   - `init.sh` line 86: `PLATFORM_DEVICE_TYPE="maccatalyst"` — would be rejected

**Apps:** No maccatalyst apps generated. The MAUI apps currently have TFM `net11.0-ios` (generated for ios-simulator). For maccatalyst, need `prepare.sh --platform maccatalyst` which generates MAUI apps with `net11.0-maccatalyst` TFM.

**Workloads:** Not installed. Need `maccatalyst` and `maui-maccatalyst`.

**Fix approach:** Same as osx. Create `maccatalyst/measure_maccatalyst_startup.sh`. Mac Catalyst apps produce `.app` bundles that run natively on macOS. Launch mechanism is identical to osx:
```bash
open -W -n "$APP_BUNDLE"
```

**Note:** Mac Catalyst has no standalone template — it's MAUI-only (`generate-apps.sh` line 192-194 shows the `maccatalyst` case skips native template generation). Apps: `dotnet-new-maui`, `dotnet-new-maui-samplecontent`.

---

### 4. `ios` (Physical Device) — ❌ BROKEN (Hard to Fix)

**Multiple blockers:**

1. **No physical iPhone connected** — hardware requirement
2. **Missing scenario directory:** `genericiosstartup/` does NOT exist
3. **Requires `sudo`:** test.py iOS path (runner.py lines 802-810) uses `sudo log collect --device` for timing via SpringBoard Watchdog events
4. **Complex measurement:** Uses xharness for install/launch/kill, parses iOS unified log for Watchdog events to compute time-to-main and time-to-first-draw (runner.py lines 825-934)

**test.py DOES support `--device-type ios`** (runner.py line 71, and the full iOS code path at lines 695-961). But it expects:
- A physical device connected (detected via `xharness apple state`)
- `sudo` access for `log collect --device`
- The `--target ios-device` xharness argument

**This platform cannot be tested on this Mac without a physical iPhone.**

---

### 5. `android` / `android-emulator` — ❌ BROKEN (Hard to Fix)

**Blockers:**
1. **No Android device connected** — no `adb` in environment, wrong workloads installed
2. **Wrong workloads:** `ios` workloads installed instead of `android`
3. **Scenario dir DOES exist:** `genericandroidstartup/` ✅
4. **test.py supports it:** `--device-type android` ✅

**Would need:** Physical Android device or emulator, `prepare.sh --platform android`, Android SDK with `adb`.

---

## How `measure_all.sh` Routes Each Platform

```
measure_all.sh
├── ios-simulator → ios/measure_simulator_startup.sh (line 138-140)
│                    Uses xcrun simctl launch + wall-clock timing
│                    ✅ WORKS
│
├── osx → measure_startup.sh (line 142-143)
│          → cd genericmacosstartup/ (FAILS - dir missing)
│          → even if existed: test.py --device-type osx (FAILS - invalid)
│          ❌ BROKEN
│
├── maccatalyst → measure_startup.sh (line 142-143)
│                  → cd genericmaccatalyststartup/ (FAILS - dir missing)
│                  → even if existed: test.py --device-type maccatalyst (FAILS - invalid)
│                  ❌ BROKEN
│
├── ios (device) → measure_startup.sh (line 142-143)
│                   → cd genericiosstartup/ (FAILS - dir missing)
│                   → even if existed: test.py --device-type ios (would work, but needs device + sudo)
│                   ❌ BROKEN
│
├── android → measure_startup.sh (line 142-143)
│              → cd genericandroidstartup/ (✅ exists)
│              → test.py --device-type android (✅ valid)
│              → but no device connected
│              ❌ BROKEN (env issue, not code issue)
│
└── android-emulator → same as android
                       ❌ BROKEN (env issue)
```

---

## The Fix Pattern

The proven pattern from `ios-simulator` is:

1. **Create a custom measurement script** (`<platform>/measure_<platform>_startup.sh`) that:
   - Builds the app (or uses `--package-path` / `--no-build`)
   - Launches the .app bundle using platform-native commands
   - Times it with `python3 time.time_ns()` wall-clock timing
   - Runs N iterations, computes avg/median/min/max/stdev
   - Outputs the `Generic Startup | <avg> | <min> | <max>` line for `measure_all.sh` parsing

2. **Add routing in `measure_all.sh`** to check `PLATFORM_DEVICE_TYPE` and route to the custom script (like lines 138-140 do for ios-simulator)

3. **Also add routing in `measure_startup.sh`** early exit for the platform (like lines 95-102 do for ios-simulator)

### macOS/maccatalyst App Launch Commands

Both platforms produce `.app` bundles that run natively on macOS. Options for launching:

| Command | Behavior | Suitable? |
|---------|----------|-----------|
| `open -a /path/to.app` | Launches in background, returns immediately | ✅ Can time launch-to-return |
| `open -W -a /path/to.app` | Launches and waits for app to exit | ❌ App doesn't exit on its own |
| `open -W -n -a /path/to.app` | New instance, waits for exit | ❌ Same issue |
| Direct executable: `./Foo.app/Contents/MacOS/Foo` | Runs in foreground, blocks | ✅ More control, can measure process start |

For wall-clock timing, `open -a` + immediate `kill` (after launch returns) is the simplest approach, mirroring how `xcrun simctl launch` works.

---

## Required Setup Steps for Each Fixable Platform

### osx
```bash
# 1. Install SDK and macOS workloads (fresh env)
./prepare.sh --platform osx

# 2. Create the measurement script (new code)
# osx/measure_osx_startup.sh

# 3. Add routing in measure_all.sh and measure_startup.sh
```

### maccatalyst
```bash
# 1. Install SDK and maccatalyst workloads (fresh env)
./prepare.sh --platform maccatalyst

# 2. Create the measurement script (new code)
# maccatalyst/measure_maccatalyst_startup.sh

# 3. Add routing in measure_all.sh and measure_startup.sh
```

**Important:** `prepare.sh` resets the entire `.dotnet/` directory (line 98: `rm -rf "$DOTNET_DIR"`). Running it for a new platform will wipe the iOS workloads. The environments are NOT additive — you prepare for one platform at a time.

---

## Key Files Referenced

| File | Line(s) | Relevance |
|------|---------|-----------|
| `init.sh` | 28-98 | `resolve_platform_config()` — sets scenario dirs, device types |
| `measure_startup.sh` | 95-102 | ios-simulator routing bypass |
| `measure_startup.sh` | 234 | `cd "$PLATFORM_SCENARIO_DIR"` — fails for osx/maccatalyst |
| `measure_startup.sh` | 240-241 | `test.py --device-type` — rejects osx/maccatalyst |
| `measure_all.sh` | 138-144 | Platform routing (ios-simulator special case) |
| `measure_all.sh` | 72-78 | Config list (6 for Apple, 7 for Android) |
| `measure_all.sh` | 82-95 | Default app list per platform |
| `runner.py` | 71 | `choices=['android','ios']` — ONLY two valid device types |
| `ios/measure_simulator_startup.sh` | 1-496 | Template for custom measurement scripts |
| `generate-apps.sh` | 182-201 | App generation per platform |
| `prepare.sh` | 137-144 | Workload installation per platform |
| `versions.log` | 1-11 | Shows ios workloads currently installed |

---

## Risks and Unknowns

1. **`prepare.sh` is destructive** — switching platforms requires full environment reset. Cannot have iOS and macOS workloads installed simultaneously.
2. **Wall-clock timing accuracy** — `open -a` may return before the app is fully rendered. This is the same limitation as `xcrun simctl launch` timing.
3. **App codesigning** — macOS apps may need ad-hoc signing to run. Need to test if `dotnet build` produces launchable bundles without developer certificate.
4. **Gatekeeper** — macOS may block unsigned apps. May need `xattr -cr` or `spctl --add` workarounds.
5. **Kill mechanism** — After timing launch, need a reliable way to terminate the app. Options: `kill $(pgrep -f BundleId)`, `osascript -e 'tell application "X" to quit'`, or `pkill -f`.
