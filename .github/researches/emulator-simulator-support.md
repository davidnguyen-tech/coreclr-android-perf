# Emulator & Simulator Support Research

Adding Android emulator and iOS simulator support to enable startup performance measurement without physical devices.

---

## Architecture

### Current State: Physical Devices Only

Every script in the repository assumes a physical device:

| Platform | RID (hardcoded) | Device Interaction | Assumption |
|----------|-----------------|-------------------|------------|
| Android | `android-arm64` | `adb` | Physical ARM64 Android device |
| iOS | `ios-arm64` | `xcrun devicectl`, xharness `--target ios-device` | Physical iPhone |
| macOS | `osx-arm64` | Local execution | Host machine |
| Mac Catalyst | `maccatalyst-arm64` | Local execution | Host machine |

macOS and Mac Catalyst run locally and have no emulator/simulator concept — they need no changes.

### Proposed State: Device Type Awareness

Add a `--device-type` concept that modifies the RID and xharness target without duplicating all platform configuration. The key insight is that **most configuration is shared** between device and emulator/simulator — only the RID and device interaction layer differ.

---

## Key Files — Where Device Assumptions Live

### 1. `init.sh` (lines 28–73) — RID selection

`resolve_platform_config()` hardcodes the RID per platform:

```
Line 34: PLATFORM_RID="android-arm64"
Line 43: PLATFORM_RID="ios-arm64"
Line 52: PLATFORM_RID="osx-arm64"
Line 61: PLATFORM_RID="maccatalyst-arm64"
```

**Impact:** This is the single source of truth for RID. Changing it here propagates to `build.sh` (line 95), `measure_startup.sh` (line 98), and `measure_all.sh` (via `measure_startup.sh`).

**Important:** The `-r $PLATFORM_RID` on the `dotnet build` command line overrides the `<RuntimeIdentifier>` in `build-configs.props`, so the build-configs files don't need separate emulator/simulator variants.

### 2. `build-configs.props` (all platforms) — Redundant RID

Every PropertyGroup in every `build-configs.props` file repeats the RID:

- `android/build-configs.props`: `<RuntimeIdentifier>android-arm64</RuntimeIdentifier>` (7 occurrences, lines 5, 14, 22, 32, 43, 54, 66)
- `ios/build-configs.props`: `<RuntimeIdentifier>ios-arm64</RuntimeIdentifier>` (6 occurrences, lines 4, 12, 19, 28, 37, 46)
- `osx/build-configs.props`: same pattern with `osx-arm64`
- `maccatalyst/build-configs.props`: same pattern with `maccatalyst-arm64`

**Impact:** Since command-line `-r` overrides project `<RuntimeIdentifier>`, these are effectively redundant when building via `build.sh` or `measure_startup.sh`. However, they serve as defaults for standalone `dotnet build` invocations. For emulator/simulator support, the command-line `-r` override is sufficient — no need to create separate build-configs files.

### 3. `collect_nettrace.sh` scripts — Hardcoded RIDs

These scripts bypass `init.sh`'s `PLATFORM_RID` and hardcode:

- `android/collect_nettrace.sh` line 211: `-f net11.0-android -r android-arm64`
- `ios/collect_nettrace.sh` line 274: `-f net11.0-ios -r ios-arm64`
- `osx/collect_nettrace.sh` line 151: `-f net11.0-macos -r osx-arm64`
- `maccatalyst/collect_nettrace.sh` line 151: `-f net11.0-maccatalyst -r maccatalyst-arm64`

**Impact:** These would need parameterization to support alternate RIDs.

### 4. `ios/collect_nettrace.sh` (lines 141–168) — Physical device detection

Device detection explicitly filters for wired (USB) connections:

```python
devices = [d for d in data.get('result', {}).get('devices', [])
           if d.get('connectionProperties', {}).get('transportType') == 'wired']
```

And the cleanup uses `--target ios-device`:

```bash
"$XHARNESS" apple uninstall --app "$BUNDLE_ID" --target ios-device ...
```

**Impact:** Must change device detection and xharness targets for simulator.

### 5. `ios/README.md` line 8 — Explicit statement

> "**Physical iPhone** (arm64) — iOS Simulator is not supported for accurate startup measurements"

**Impact:** This is a documentation constraint, not a technical one. Simulators can still provide useful comparative measurements.

### 6. `measure_startup.sh` (lines 153–157) — test.py invocation

```bash
python3 test.py devicestartup \
    --device-type "$PLATFORM_DEVICE_TYPE" \
    --package-path "$PACKAGE_PATH" \
    --package-name "$PACKAGE_NAME" \
    "$@"
```

**Impact:** The `PLATFORM_DEVICE_TYPE` value is what `dotnet/performance`'s test.py uses to determine how to deploy and measure. This is the critical parameter for emulator/simulator differentiation.

---

## Android Emulator Specifics

### RID Selection

| Host Architecture | Emulator Type | RID |
|-------------------|--------------|-----|
| x86_64 (Intel/AMD) | x86_64 emulator | `android-x64` |
| arm64 (Apple Silicon) | ARM64 emulator | `android-arm64` |

On Apple Silicon Macs (this repo's primary host), the Android emulator runs ARM64 images. This means the **RID is the same as physical device** (`android-arm64`). No RID change needed for Apple Silicon hosts.

On x86_64 hosts, the common emulator uses x86_64 images → `android-x64`.

**Recommendation:** Auto-detect host architecture to select RID:
```bash
if [[ "$(uname -m)" == "arm64" || "$(uname -m)" == "aarch64" ]]; then
    PLATFORM_RID="android-arm64"
else
    PLATFORM_RID="android-x64"
fi
```

### adb: Emulator vs Device

`adb devices` output differences:
```
# Physical device:
R58N31XXXXX    device

# Emulator:
emulator-5554  device
```

For this repository, **no changes are needed** — `adb` commands work identically for emulators and physical devices. The scripts don't parse device type from `adb devices`; they just use `adb` commands that target whatever is connected.

The only place that checks for a device is `android/collect_nettrace.sh` line 259:
```
echo "Check that a device is connected (adb devices) and that port 9000 is not in use."
```
This is just a help message, not a programmatic check.

### Logcat / Startup Measurement

Logcat-based startup measurement works **identically** on emulators. The `ActivityTaskManager: Displayed` and `ActivityTaskManager: Fully drawn` log entries are produced the same way.

### Build Config Differences

**None.** All MSBuild properties (UseMonoRuntime, RunAOTCompilation, PublishReadyToRun, etc.) are identical between emulator and device. Only the RID differs (and even that may not differ on Apple Silicon).

### dsrouter / .nettrace Collection

`android/collect_nettrace.sh` line 186:
```bash
"$DSROUTER" server-server \
    -ipcs "$IPC_NAME" \
    -tcps 127.0.0.1:9000 \
    --forward-port Android &
```

The `--forward-port Android` mode uses ADB for port forwarding. ADB port forwarding works identically for emulators and physical devices. **No changes needed.**

### dotnet/performance Device Type

The `--device-type android` value for `test.py devicestartup` should work for both emulators and physical devices. The dotnet/performance test harness uses xharness, which in turn uses adb — both work transparently with emulators.

### Summary: Android Emulator Impact

| Component | Change Needed? | Details |
|-----------|---------------|---------|
| `init.sh` RID | Maybe | Only if host is x86_64 (Apple Silicon → same RID) |
| `build-configs.props` | No | Command-line `-r` overrides |
| `build.sh` | No | Uses `$PLATFORM_RID` from init.sh |
| `measure_startup.sh` | No | Delegates to test.py |
| `collect_nettrace.sh` | Maybe | Hardcoded RID on line 211 needs parameterizing |
| `--device-type` | No | `android` works for both |
| Logcat timing | No | Identical |
| adb commands | No | Work for both |

**Verdict:** Android emulator support on Apple Silicon requires **zero or minimal changes** — the existing `android-arm64` RID and `adb`-based tooling work transparently. On x86_64 hosts, only the RID needs changing to `android-x64`.

---

## iOS Simulator Specifics

### RID Selection

| Host Architecture | RID |
|-------------------|-----|
| arm64 (Apple Silicon) | `iossimulator-arm64` |
| x86_64 (Intel Mac) | `iossimulator-x64` |

This is a **different RID** from the device RID (`ios-arm64`). The `iossimulator` prefix is required — it's a distinct .NET platform.

### TFM

The TFM remains `net11.0-ios` for both device and simulator. The RID differentiates them.

### xharness Targets

| Target | xharness value |
|--------|---------------|
| Physical device | `ios-device` |
| Simulator | `ios-simulator-64` (x64) or `ios-simulator` |

xharness `apple install` and `apple run` accept `--target` to specify device vs simulator:
```bash
# Device
xharness apple install --app MyApp.app --target ios-device
# Simulator
xharness apple install --app MyApp.app --target ios-simulator-64
```

### xcrun simctl (Simulator Management)

```bash
# List available simulators
xcrun simctl list devices available

# Boot a simulator
xcrun simctl boot <device-udid>

# Install app
xcrun simctl install <device-udid> /path/to/MyApp.app

# Launch app
xcrun simctl launch <device-udid> com.company.MyApp

# Shutdown simulator
xcrun simctl shutdown <device-udid>
```

### Code Signing

**Simulators do NOT require code signing or provisioning profiles.** This is a significant advantage:

- No Apple Developer account needed
- No device UDID registration
- No provisioning profile management
- Easier CI/CD setup

Build properties for simulator:
```xml
<CodesignKey>-</CodesignKey>
<!-- Or simply omit signing properties -->
```

When building with `iossimulator-arm64` RID, the .NET SDK automatically skips real code signing.

### ReadyToRun / MachO Constraint

The iOS simulator still uses **MachO** format (it's running native code on the host Mac). Therefore, the **composite-only R2R limitation still applies**. The same 6 configs work (no non-composite `R2R`).

### SpringBoard Timing on Simulators

iOS simulator startup timing can be measured via:

1. **System log (`log` command):** Works for simulator, but the log subsystem differs. SpringBoard timing data may not be available in the same format as on device.

2. **xharness timing:** xharness can measure startup on simulators using `--target ios-simulator-64`. The dotnet/performance test harness handles the timing collection.

3. **`xcrun simctl launch` output:** Can be parsed for basic launch timing.

**Key difference:** Simulator startup times are **not comparable** to device times. The simulator runs x86_64/arm64 code natively on the Mac, which is much faster than actual iOS device hardware. Measurements are useful for **relative comparison between configs** on the same simulator, not for absolute performance claims.

### dotnet/performance Device Type

The `test.py devicestartup` `--device-type` likely needs a different value for simulators. Examining the pattern:

- `init.sh` sets `PLATFORM_DEVICE_TYPE="ios"` (line 44)
- This maps to `genericiosstartup` scenario directory (line 45)

For simulator support, the dotnet/performance test harness needs to be told to use simulator deployment. The likely value is `ios` with xharness handling the `--target` flag differentiation, OR a separate device type like `ios-simulator`.

**This is the biggest unknown** and requires checking the dotnet/performance source once the submodule is initialized. The scenario directory `genericiosstartup` may support both device and simulator, or there may be a separate `genericiossimulatorstartup` directory.

### .nettrace Collection on Simulator

For `ios/collect_nettrace.sh`, simulator changes:

| Aspect | Device | Simulator |
|--------|--------|-----------|
| dsrouter | `--forward-port iOS` (usbmuxd) | Not needed (local) |
| Device detection | `xcrun devicectl` (wired) | `xcrun simctl list` |
| App install | `xharness --target ios-device` | `xharness --target ios-simulator-64` or `xcrun simctl install` |
| App launch | `xcrun devicectl device process launch` | `xcrun simctl launch` |
| App uninstall | `xharness --target ios-device` | `xharness --target ios-simulator-64` or `xcrun simctl uninstall` |
| Env vars | `MtouchExtraArgs --setenv` | Same, or direct env var on `simctl launch` |
| Diagnostics | Via dsrouter bridge | Direct (same machine) — more like macOS |

**Critically:** On simulator, the app runs **on the host machine**, so `.nettrace` collection could follow the macOS/maccatalyst pattern (direct diagnostic port, no dsrouter needed). This is dramatically simpler.

### Summary: iOS Simulator Impact

| Component | Change Needed? | Details |
|-----------|---------------|---------|
| `init.sh` RID | **Yes** | `iossimulator-arm64` (Apple Silicon) or `iossimulator-x64` (Intel) |
| `build-configs.props` | No | Command-line `-r` overrides |
| `build.sh` | No | Uses `$PLATFORM_RID` |
| `measure_startup.sh` | Maybe | `--device-type` value may need to change |
| `collect_nettrace.sh` | **Yes** | Different deployment flow, no dsrouter needed |
| `--device-type` | **Unknown** | Needs dotnet/performance verification |
| Code signing | **Yes** | Not needed (advantage) |
| xharness target | **Yes** | `ios-simulator-64` instead of `ios-device` |
| R2R configs | No | Still composite-only |

---

## Design Options for `init.sh`

### Option A: New Platform Values

Add new cases like `android-emulator`, `ios-simulator`:

```bash
case "$platform" in
    android)
        PLATFORM_RID="android-arm64"
        PLATFORM_DEVICE_TYPE="android"
        ...
        ;;
    android-emulator)
        PLATFORM_RID="android-arm64"  # or android-x64 on Intel
        PLATFORM_DEVICE_TYPE="android"
        ...
        ;;
    ios)
        PLATFORM_RID="ios-arm64"
        PLATFORM_DEVICE_TYPE="ios"
        ...
        ;;
    ios-simulator)
        PLATFORM_RID="iossimulator-arm64"
        PLATFORM_DEVICE_TYPE="ios"  # or "ios-simulator"
        ...
        ;;
esac
```

**Pros:**
- Explicit, easy to understand
- Each platform value maps to exactly one configuration
- Platform names are self-documenting

**Cons:**
- Duplicates most configuration between `android` and `android-emulator`
- Affects all scripts that parse/validate `--platform` (need to add new values everywhere)
- `measure_all.sh` config lists would need duplicate entries

### Option B: Separate `--device-type` Flag

Keep platform values as-is, add a `--device-type device|emulator|simulator` flag:

```bash
resolve_platform_config() {
    local platform="${1:-android}"
    local device_type="${2:-device}"  # device, emulator, simulator

    case "$platform" in
        android)
            PLATFORM_TFM="net11.0-android"
            if [[ "$device_type" == "emulator" ]]; then
                # RID depends on host architecture
                if [[ "$(uname -m)" == "arm64" ]]; then
                    PLATFORM_RID="android-arm64"
                else
                    PLATFORM_RID="android-x64"
                fi
            else
                PLATFORM_RID="android-arm64"
            fi
            PLATFORM_DEVICE_TYPE="android"
            ...
            ;;
        ios)
            PLATFORM_TFM="net11.0-ios"
            if [[ "$device_type" == "simulator" ]]; then
                if [[ "$(uname -m)" == "arm64" ]]; then
                    PLATFORM_RID="iossimulator-arm64"
                else
                    PLATFORM_RID="iossimulator-x64"
                fi
            else
                PLATFORM_RID="ios-arm64"
            fi
            ...
            ;;
    esac
}
```

**Pros:**
- Minimal duplication
- Platform configuration stays centralized
- Naturally handles host architecture detection
- Only RID and a few deployment details change

**Cons:**
- More complex `resolve_platform_config()` logic
- Every script that accepts `--platform` also needs to accept `--device-type`
- Combining two flags creates more parsing complexity

### Option C: Compound Platform Value (Recommended)

Use a compound platform value that includes the device type: `ios-simulator`, `android-emulator`. But map these to the same base platform for build configs, with overrides:

```bash
case "$platform" in
    android|android-emulator)
        PLATFORM_TFM="net11.0-android"
        PLATFORM_DIR="$ANDROID_DIR"
        PLATFORM_SCENARIO_DIR="$SCENARIOS_DIR/genericandroidstartup"
        PLATFORM_PACKAGE_GLOB="*-Signed.apk"
        PLATFORM_PACKAGE_LABEL="APK"
        PLATFORM_DEVICE_TYPE="android"
        if [[ "$platform" == "android-emulator" ]]; then
            if [[ "$(uname -m)" == "arm64" ]]; then
                PLATFORM_RID="android-arm64"
            else
                PLATFORM_RID="android-x64"
            fi
        else
            PLATFORM_RID="android-arm64"
        fi
        ;;
    ios|ios-simulator)
        PLATFORM_TFM="net11.0-ios"
        PLATFORM_DIR="$IOS_DIR"
        PLATFORM_PACKAGE_GLOB="*.app"
        PLATFORM_PACKAGE_LABEL="APP"
        if [[ "$platform" == "ios-simulator" ]]; then
            if [[ "$(uname -m)" == "arm64" ]]; then
                PLATFORM_RID="iossimulator-arm64"
            else
                PLATFORM_RID="iossimulator-x64"
            fi
            PLATFORM_DEVICE_TYPE="ios"  # or ios-simulator, TBD
            PLATFORM_SCENARIO_DIR="$SCENARIOS_DIR/genericiosstartup"  # TBD
        else
            PLATFORM_RID="ios-arm64"
            PLATFORM_DEVICE_TYPE="ios"
            PLATFORM_SCENARIO_DIR="$SCENARIOS_DIR/genericiosstartup"
        fi
        ;;
esac
```

**Pros:**
- Self-documenting platform names
- Shared logic via `|` pattern matching
- Only one parameter to parse and pass
- Clean validation: platform list is just longer

**Cons:**
- Still some duplication within the case body
- `prepare.sh` and `generate-apps.sh` need to map back to base platform for workloads/templates

**This is the recommended approach** because it minimizes changes while being explicit.

---

## dotnet/performance Submodule (Unknowns)

The submodule at `external/performance` (GitHub: `https://github.com/dotnet/performance.git`) is not initialized. Key unknowns:

### 1. `test.py devicestartup --device-type` Values

Referenced in `measure_startup.sh` line 154. Known values:
- `android` — used by `init.sh` line 35
- `ios` — used by `init.sh` line 44
- `osx` — used by `init.sh` line 53
- `maccatalyst` — used by `init.sh` line 62

**Unknown:** Does it accept `ios-simulator`? Does `ios` work for both device and simulator? Does test.py handle simulator deployment differently?

### 2. Scenario Directories

Referenced scenario directories:
- `src/scenarios/genericandroidstartup/` — `init.sh` line 36
- `src/scenarios/genericiosstartup/` — `init.sh` line 45
- `src/scenarios/genericmacosstartup/` — `init.sh` line 54
- `src/scenarios/genericmaccatalyststartup/` — `init.sh` line 63

**Unknown:** Are there separate simulator scenario directories (e.g., `genericiossimulatorstartup`)? Or does the same scenario handle both with `--device-type` differentiation?

### 3. Action Required

Initialize the submodule to resolve these unknowns:
```bash
git submodule update --init --recursive
```
Then check:
```bash
ls external/performance/src/scenarios/generic*
grep -r "device.type\|device_type\|DeviceType" external/performance/src/scenarios/
```

---

## Impact Analysis by Script

### `init.sh`

**Changes needed:** Add `android-emulator` and `ios-simulator` cases (or compound pattern matching) to `resolve_platform_config()`.

**Scope:** Lines 28–73. Add host-arch-aware RID selection.

### `prepare.sh`

**Changes needed:**
- Lines 37–43: Add new platform values to validation
- Lines 129–134: Map emulator/simulator platforms to their base workloads
  - `android-emulator` → same workloads as `android`: `android maui-android`
  - `ios-simulator` → same workloads as `ios`: `ios maui-ios`
- Lines 143–148: Same workload ID mapping for verification

**Scope:** Moderate — add mappings, not new logic.

### `build.sh`

**Changes needed:**
- Line 12: Update error message to include new platform values
- Line 39: Update usage text

**Scope:** Minimal — cosmetic only. Build logic is already fully abstracted.

### `measure_startup.sh`

**Changes needed:**
- Line 52: Update error message
- Potentially: `PLATFORM_DEVICE_TYPE` value for test.py (depends on dotnet/performance)

**Scope:** Minimal to moderate, depending on dotnet/performance requirements.

### `measure_all.sh`

**Changes needed:**
- Lines 72–79: Add `android-emulator` and `ios-simulator` config lists
- Lines 82–95: Add default app lists (same apps as device counterparts)
- Lines 33–34: Update error message

**Scope:** Moderate — add new cases.

### `generate-apps.sh`

**Changes needed:**
- Lines 17–32: Accept new platform values
- Lines 182–195: Map `android-emulator` to `android` template, `ios-simulator` to `ios` template
- No build-config changes needed

**Scope:** Minimal — map compound names to base template names.

### `collect_nettrace.sh` (all platforms)

**Changes needed for `android/collect_nettrace.sh`:**
- Line 211: Replace hardcoded `-r android-arm64` with parameterized RID
- Otherwise identical (adb works for both)

**Changes needed for `ios/collect_nettrace.sh`:**
- Lines 141–168: Different device detection (use `xcrun simctl` instead of `xcrun devicectl`)
- Lines 218–227: Different xharness target (`ios-simulator-64`)
- Lines 240–246: No dsrouter needed for simulator (direct diagnostic port)
- Lines 308–316: Different install mechanism
- Lines 331–339: Different launch mechanism (`xcrun simctl launch`)
- **Scope: Major** — significant flow differences, possibly a separate script

### `build-configs.props` (all platforms)

**No changes needed.** Command-line `-r` overrides `<RuntimeIdentifier>` in the props file.

### `build-workarounds.targets` (all platforms)

**No changes needed.** Platform conditions (`TargetPlatformIdentifier`) should match correctly for both device and simulator builds.

---

## Risks and Unknowns

### Critical

1. **dotnet/performance `--device-type` for simulator** — Without checking the submodule source, we don't know if test.py supports simulator deployment. If it doesn't, the startup measurement pipeline won't work and we'd need to implement custom measurement. **Must resolve before implementation.**

2. **iOS simulator startup timing accuracy** — Simulator runs on host hardware, so startup times are fundamentally different from device. Results are useful for comparing configs against each other, not for absolute performance numbers. **Must be documented clearly.**

### High

3. **`iossimulator` RID and workload availability** — The `iossimulator-arm64` RID requires the `ios` workload (same workload covers both). This needs verification with .NET 11 preview SDK.

4. **iOS simulator .nettrace collection** — The current `ios/collect_nettrace.sh` assumes physical device with dsrouter. Simulator collection should follow the macOS pattern (direct diagnostic port). This may warrant a separate script (`ios/collect_nettrace_simulator.sh`) or a parameterized approach.

### Medium

5. **Android x64 build configs** — On x86_64 hosts, `android-x64` RID may not support all build configurations (e.g., Mono AOT on x64). Needs testing.

6. **MIBC profiles** — PGO profiles from `dotnet-optimization` CI are architecture-specific. `iossimulator-arm64` may not have MIBC profiles available. `R2R_COMP_PGO` config may fail or produce suboptimal results.

7. **Simulator boot/lifecycle management** — Scripts would need to ensure a simulator is booted before measurement. This adds complexity (which simulator image? auto-boot? shutdown after?).

### Low

8. **CI/CD implications** — Emulator/simulator support would enable automated testing without physical devices. This is an opportunity but also needs CI infrastructure (emulator images, Xcode simulator runtimes installed).

---

## Recommendations

### Phase 1: Android Emulator (Low effort)

On Apple Silicon, **no code changes may be needed** — the existing `android-arm64` RID works for ARM emulators. The only change is documenting that emulators are supported.

For explicit emulator support (including x64 hosts):
1. Add `android-emulator` case to `init.sh` with host-arch-aware RID
2. Map `android-emulator` to `android` in `prepare.sh`, `generate-apps.sh`, `measure_all.sh`
3. No measurement changes — logcat and test.py work identically

### Phase 2: iOS Simulator (Moderate effort)

1. Add `ios-simulator` case to `init.sh` with `iossimulator-arm64` RID
2. **Resolve the dotnet/performance `--device-type` unknown first** — initialize submodule and check
3. Map `ios-simulator` to `ios` in `prepare.sh`, `generate-apps.sh`
4. Update `measure_all.sh` with simulator config list (same 6 configs)
5. For `.nettrace`, create `ios/collect_nettrace_simulator.sh` following macOS pattern
6. Document that simulator measurements are for relative comparison only

### Priority

1. **Initialize `external/performance` submodule** and investigate device types — this blocks all work
2. Android emulator on Apple Silicon — likely zero-change, just test and document
3. iOS simulator — moderate changes, significant CI benefit (no physical device needed)
