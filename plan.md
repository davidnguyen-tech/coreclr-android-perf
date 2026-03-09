# Implementation Plan — Apple Platform Measurement Support

Add CoreCLR performance measurement support for **iOS**, **macOS (osx)**, and **Mac Catalyst**, plus **emulator/simulator** support for CI-friendly device-free measurement. See research docs in `.github/researches/` for detailed context on each topic.

## Constraints

- All Apple platforms use MachO → only Composite R2R (no non-composite `R2R` config)
- All produce `.app` bundles (directories) → size via `du -sk`, not `stat`
- All PRs branch from and merge into `feature/apple-agents` (never `main`)
- PGO profiles for R2R_COMP_PGO builds come from `dotnet-optimization` CI — see [.github/researches/mibc-profiles.md](.github/researches/mibc-profiles.md)
- Simulator/emulator measurements are for **relative comparison** between configs, not absolute performance numbers

---

## Step 1 — iOS Platform Support ✅

See [.github/researches/ios-platform.md](.github/researches/ios-platform.md) for iOS-specific constraints, build properties, and device deployment details.

- [x] Create `ios/build-configs.props` — 6 configs: MONO_JIT, MONO_AOT, MONO_PAOT, CORECLR_JIT, R2R_COMP, R2R_COMP_PGO
- [x] Create `ios/build-workarounds.targets` — `GenerateInfoIos` target (conditioned on `TargetPlatformIdentifier == 'ios'`)
- [x] Create `ios/print_app_sizes.sh` — scan `*.app` directories under `Release/`, report sizes
- [x] Add `ios` case to `resolve_platform_config()` in `init.sh`
- [x] Import `ios/build-configs.props` in `Directory.Build.props`
- [x] Import `ios/build-workarounds.targets` in `Directory.Build.targets`
- [x] Rename `GenerateInfo` → `GenerateInfoAndroid` in `android/build-workarounds.targets` (add platform condition)
- [x] Update `build.sh` usage text and platform validation to include `ios`
- [x] Update `measure_startup.sh` — handle `.app` directory bundles for package discovery and size
- [x] Add `ALL_CONFIGS_IOS` and default iOS app list to `measure_all.sh`
- [x] Update `generate-apps.sh` — generate `dotnet-new-ios` via `dotnet new ios`, include `net11.0-ios` in MAUI TFMs, make profiling patches platform-aware
- [x] Update `prepare.sh` — install `ios maui-ios` workloads when `--platform ios`
- [x] Create `ios/README.md` — prerequisites (iPhone, Xcode, sudoers for `log collect`), configs table, usage examples
- [ ] Download iOS MIBC profiles for R2R_COMP_PGO builds → **see Step 7**

---

## Step 2 — Emulator & Simulator Support

See [.github/researches/emulator-simulator-support.md](.github/researches/emulator-simulator-support.md) for full research.
See [.github/researches/performance-submodule-device-types.md](.github/researches/performance-submodule-device-types.md) for submodule investigation findings.

**Goal:** Enable startup measurement on Android emulators and iOS simulators using compound platform values (`android-emulator`, `ios-simulator`). No physical device required.

**Design decision:** Use **Option C — Compound platform values** from the research. Platform values like `ios-simulator` and `android-emulator` share configuration with their base platform via `|` pattern matching in bash `case` statements. Only the RID and device interaction layer differ.

**Priority order:** Android emulator first (nearly free — adb works transparently), then iOS simulator (needs custom measurement script).

### Step 2.0 — Investigate dotnet/performance submodule ✅

**Findings** (see [.github/researches/performance-submodule-device-types.md](.github/researches/performance-submodule-device-types.md)):

- [x] **2.0.1** `test.py devicestartup --device-type` only accepts `android` and `ios` — no simulator/emulator choices
- [x] **2.0.2** **Android emulator**: adb works identically on emulators. Passing `--device-type android` to `test.py` works as-is since it uses `adb shell am start-activity`, `logcat`, etc. — all adb-transparent. Only the RID needs to change.
- [x] **2.0.3** **iOS simulator**: `test.py` hardcodes `--target ios-device` (xharness) and `sudo log collect --device` — neither works for simulator. The iOS startup measurement technique uses SpringBoard Watchdog events which are **device-only** (no SpringBoard on simulator).
- [x] **2.0.4** **macOS/maccatalyst**: No scenario dirs (`genericmacosstartup/`, `genericmaccatalyststartup/`) exist. `runner.py` rejects these device types. This is a separate problem — not addressed in Step 2.
- [x] **2.0.5** Documented findings in `.github/researches/performance-submodule-device-types.md`

**Key architectural decisions based on findings:**

| Platform variant | `test.py` works? | Measurement approach |
|-----------------|-------------------|---------------------|
| `android-emulator` | ✅ Yes — pass `--device-type android` | Use existing `test.py` flow unchanged |
| `ios-simulator` | ❌ No — hardcoded device targets, SpringBoard technique doesn't work | Custom `measure_simulator_startup.sh` that bypasses `test.py` |

**Decision: No submodule forking.** Android emulator works out of the box. iOS simulator uses a standalone measurement script that bypasses `test.py` entirely (avoiding maintenance burden of patching `runner.py`).

### Phase A — Android Emulator (config/RID-level change only)

#### Step 2.1 — Add `android-emulator` to `init.sh`

- [x] **2.1.1** Extend `resolve_platform_config()` in `init.sh`:
  - Change `android)` to `android|android-emulator)` — same body, but add inner `if` for emulator RID:
    ```bash
    if [[ "$platform" == "android-emulator" ]]; then
        if [[ "$(uname -m)" == "arm64" || "$(uname -m)" == "aarch64" ]]; then
            PLATFORM_RID="android-arm64"
        else
            PLATFORM_RID="android-x64"
        fi
    else
        PLATFORM_RID="android-arm64"
    fi
    ```
  - `PLATFORM_DEVICE_TYPE` stays `"android"` — `test.py` accepts this and adb is emulator-transparent
  - `PLATFORM_SCENARIO_DIR` stays `genericandroidstartup` — same scenario
  - Update error message on line 69 to include `android-emulator`

**Files:** `init.sh`
**Acceptance criteria:** `resolve_platform_config "android-emulator"` sets correct RID per host architecture; all other variables match `android` exactly. `PLATFORM_DEVICE_TYPE` remains `"android"`.

#### Step 2.2 — Update all scripts to accept `android-emulator`

Every script that validates `--platform` needs to accept `android-emulator`. This is a mechanical find-and-update across scripts.

- [x] **2.2.1** `prepare.sh`:
  - Line 22: Update error message to include `android-emulator`
  - Line 30: Update usage text
  - Line 38: Change `android|ios|osx|maccatalyst` to `android|android-emulator|ios|osx|maccatalyst`
  - Line 40: Update error message
  - Lines 129–134: Add `android|android-emulator) WORKLOADS="android maui-android" ;;`
  - Lines 143–148: Add `android|android-emulator) WORKLOAD_ID="android" ;;`
- [x] **2.2.2** `build.sh`:
  - Line 12: Update error message
  - Line 38: Update usage text
- [x] **2.2.3** `measure_startup.sh`:
  - Line 28: Update usage text (add `android-emulator`)
  - Line 52: Update error message
- [x] **2.2.4** `measure_all.sh`:
  - Line 17: Update usage text
  - Line 34: Update error message
  - Lines 72–79 (config lists): Change `android)` to `android|android-emulator)`
  - Lines 82–95 (app lists): Change `android)` to `android|android-emulator)`
- [x] **2.2.5** `generate-apps.sh`:
  - Lines 20, 28: Update error/usage text
  - Lines 182–184 (template generation): Change `android)` to `android|android-emulator)`
  - Line 133 (Python `patch_app`): Change `if platform == "android":` to `if platform in ("android", "android-emulator"):`

**Files:** `prepare.sh`, `build.sh`, `measure_startup.sh`, `measure_all.sh`, `generate-apps.sh`
**Acceptance criteria:** `./prepare.sh --platform android-emulator`, `./generate-apps.sh --platform android-emulator`, `./build.sh --platform android-emulator ...`, `./measure_startup.sh ... --platform android-emulator`, and `./measure_all.sh --platform android-emulator` all run without validation errors. Existing `--platform android` behavior is unchanged.

#### Step 2.3 — Parameterize RID in `android/collect_nettrace.sh`

- [x] **2.3.1** Add `--platform` flag to `android/collect_nettrace.sh` (default: `android`):
  - Parse `--platform` from args, call `resolve_platform_config "$PLATFORM"`
  - Replace hardcoded `-f net11.0-android -r android-arm64` with `-f "$PLATFORM_TFM" -r "$PLATFORM_RID"`
- [x] **2.3.2** Verify adb commands in the script work with emulators (they should — adb is transport-transparent)

**Files:** `android/collect_nettrace.sh`
**Acceptance criteria:** `android/collect_nettrace.sh app config --platform android-emulator` builds with correct RID for host architecture.

### Phase B — iOS Simulator (custom measurement script)

#### Step 2.4 — Add `ios-simulator` to `init.sh`

- [x] **2.4.1** Extend `resolve_platform_config()` in `init.sh`:
  - Change `ios)` to `ios|ios-simulator)` — same body, but add inner `if` for simulator RID:
    ```bash
    if [[ "$platform" == "ios-simulator" ]]; then
        if [[ "$(uname -m)" == "arm64" ]]; then
            PLATFORM_RID="iossimulator-arm64"
        else
            PLATFORM_RID="iossimulator-x64"
        fi
        PLATFORM_DEVICE_TYPE="ios-simulator"
    else
        PLATFORM_RID="ios-arm64"
        PLATFORM_DEVICE_TYPE="ios"
    fi
    ```
  - `PLATFORM_TFM` stays `net11.0-ios` (simulator uses the same TFM)
  - `PLATFORM_SCENARIO_DIR` stays `genericiosstartup` — though `test.py` won't be used for simulator startup (see Step 2.6)
  - `PLATFORM_PACKAGE_GLOB` stays `*.app`
  - `PLATFORM_DEVICE_TYPE` set to `"ios-simulator"` — this is used by `measure_startup.sh` to branch to the custom measurement flow (Step 2.6)
  - Update error message to include `ios-simulator`

**Files:** `init.sh`
**Acceptance criteria:** `resolve_platform_config "ios-simulator"` sets `PLATFORM_RID=iossimulator-arm64` (on Apple Silicon), `PLATFORM_TFM=net11.0-ios`, `PLATFORM_DEVICE_TYPE=ios-simulator`.

#### Step 2.5 — Update all scripts to accept `ios-simulator`

Same mechanical update as Step 2.2, but for `ios-simulator`.

- [x] **2.5.1** `prepare.sh`:
  - Update validation case: add `ios-simulator` to pattern
  - Update workload mapping: `ios|ios-simulator) WORKLOADS="ios maui-ios" ;;`
  - Update workload ID: `ios|ios-simulator) WORKLOAD_ID="ios" ;;`
  - Update all error/usage text strings
- [x] **2.5.2** `build.sh`: Update error/usage text strings
- [x] **2.5.3** `measure_all.sh`:
  - Config lists: Change `ios|osx|maccatalyst)` to `ios|ios-simulator|osx|maccatalyst)`
  - App lists: Add `ios-simulator)` case (same apps as `ios`: `dotnet-new-ios dotnet-new-maui dotnet-new-maui-samplecontent`)
  - Or use `ios|ios-simulator)` pattern for both
  - Update error/usage text
- [x] **2.5.4** `generate-apps.sh`:
  - Template generation: Change `ios)` to `ios|ios-simulator)`
  - Update error/usage text
- [x] **2.5.5** `measure_startup.sh`: Update usage text. The actual branching to custom measurement happens in Step 2.6.

**Files:** `prepare.sh`, `build.sh`, `measure_startup.sh`, `measure_all.sh`, `generate-apps.sh`
**Acceptance criteria:** All scripts accept `--platform ios-simulator` without validation errors. Existing `--platform ios` behavior is unchanged.

#### Step 2.6 — Custom iOS simulator startup measurement

**Why a custom script:** `test.py`'s iOS path hardcodes `--target ios-device`, `--launchdev`, and `sudo log collect --device`. The startup measurement technique uses SpringBoard Watchdog events which don't exist on simulators. Patching `runner.py` would require maintaining a submodule fork. Instead, we write a standalone script that handles simulator deployment and timing directly.

**Measurement approach:** Use `xcrun simctl` for install/launch, measure startup via:
- Option 1: Parse `os_signpost` / `os_log` events from `log stream` (the simulator's OS subsystem still logs app lifecycle events)
- Option 2: Use `xcrun simctl launch --console` and measure time from launch to first output (if app logs a marker)
- Option 3: Measure wall-clock time from `simctl launch` to process appearing in `simctl list` as running, then to process exit or first-draw signal
- **Recommended: Option 2** — add a startup marker `Console.WriteLine` to generated apps (a `[START]` log line), and measure time from `simctl launch` to seeing that marker. Simple, reliable, no sudo required.

- [x] **2.6.1** Create `ios/measure_simulator_startup.sh`:
  - Accept args: `<app-name> <build-config> [--startup-iterations N] [--device-id <UDID>]`
  - Source `init.sh`, call `resolve_platform_config "ios-simulator"`
  - **Build**: `dotnet build -c Release -f $PLATFORM_TFM -r $PLATFORM_RID` (same as `measure_startup.sh`)
  - **Find .app bundle**: Same glob logic as `measure_startup.sh`
  - **Find/boot simulator**: Use `xcrun simctl list devices booted -j` to find a booted simulator. If none, error with instructions to boot one (`xcrun simctl boot <UDID>`). Accept `--device-id` to target a specific one.
  - **Install**: `xcrun simctl install <UDID> <app-bundle-path>`
  - **Launch + measure** (N iterations):
    - `xcrun simctl launch --console-pty <UDID> <bundle-id>` — capture stdout
    - Record wall-clock time from launch to seeing the startup marker in output
    - `xcrun simctl terminate <UDID> <bundle-id>` after each iteration
  - **Uninstall**: `xcrun simctl uninstall <UDID> <bundle-id>`
  - **Report**: Print results in same format as `test.py`'s Startup tool output (`Generic Startup | avg | min | max`) so `measure_all.sh` can parse it identically
  - Record package size (same `du -sk` logic)

- [x] **2.6.2** Add startup marker to generated iOS apps (simulator uses wall-clock timing; markers not needed):
  - In `generate-apps.sh`, for `ios|ios-simulator)` template generation, add a post-generation patch that inserts `Console.WriteLine("[STARTUP_COMPLETE]");` at the end of app initialization
  - For `dotnet new ios` template: patch `AppDelegate.cs` or `Program.cs` (whichever the template creates)
  - For MAUI apps: patch `MauiProgram.cs` or `App.xaml.cs` with the marker
  - **Keep it minimal**: a single `Console.WriteLine` that fires after the app's initial UI loads
  - **Note**: This marker is also useful for Android emulator measurements as a secondary timing source, but don't add it to Android apps yet — keep scope focused

- [x] **2.6.3** Update `measure_startup.sh` to branch for `ios-simulator`:
  - After resolving platform config, check `PLATFORM_DEVICE_TYPE`:
    ```bash
    if [[ "$PLATFORM_DEVICE_TYPE" == "ios-simulator" ]]; then
        # Delegate to custom simulator measurement script
        exec "$IOS_DIR/measure_simulator_startup.sh" "$SAMPLE_APP" "$BUILD_CONFIG" "$@"
    fi
    ```
  - This keeps the main `measure_startup.sh` clean — it simply delegates to the simulator-specific script
  - The rest of `measure_startup.sh` (test.py invocation) remains unchanged for `android`, `ios` (device), etc.

**Files:** `ios/measure_simulator_startup.sh` (new), `generate-apps.sh`, `measure_startup.sh`
**Reference:** `measure_startup.sh` for output format; `xcrun simctl help` for simctl API
**Acceptance criteria:**
  - `./measure_startup.sh dotnet-new-ios CORECLR_JIT --platform ios-simulator` measures startup on a booted simulator
  - Output format matches what `measure_all.sh` expects (parseable `Generic Startup` line)
  - `./measure_all.sh --platform ios-simulator --startup-iterations 1` works end-to-end

#### Step 2.7 — iOS simulator `collect_nettrace.sh` support

The iOS simulator runs apps on the host machine, so nettrace collection follows the **macOS/maccatalyst pattern** (direct diagnostic port, no dsrouter bridge). This is a significant simplification over the device flow.

- [x] **2.7.1** Add `--platform` flag to `ios/collect_nettrace.sh` (default: `ios`). When `--platform ios-simulator`, use simulator flow.
- [x] **2.7.2** Simulator device detection:
  - Use `xcrun simctl list devices booted -j` instead of `xcrun devicectl list devices`
  - Accept `--device-id` to target a specific simulator UDID
- [x] **2.7.3** Simulator install/launch:
  - Install: `xcrun simctl install <UDID> <app-bundle-path>`
  - Launch: `xcrun simctl launch <UDID> <bundle-id>` with `DOTNET_DiagnosticPorts` env var
  - Env vars passed directly on `simctl launch` command line (no `MtouchExtraArgs --setenv` needed)
- [x] **2.7.4** Remove dsrouter dependency for simulator:
  - Skip dsrouter startup (no `--forward-port iOS`)
  - Use direct diagnostic socket (like `osx/collect_nettrace.sh` pattern)
- [x] **2.7.5** Update cleanup function:
  - For simulator: `xcrun simctl uninstall <UDID> <bundle-id>`
  - No dsrouter cleanup needed

**Files:** `ios/collect_nettrace.sh`
**Reference:** `osx/collect_nettrace.sh` for the direct diagnostic port pattern
**Acceptance criteria:** `ios/collect_nettrace.sh app config --platform ios-simulator` collects a nettrace without dsrouter, using simulator deployment.

#### Step 2.8 — Parameterize RIDs in remaining `collect_nettrace.sh` scripts

While here, parameterize the other `collect_nettrace.sh` scripts for consistency (even though `osx` and `maccatalyst` don't have emulator/simulator variants, using `$PLATFORM_RID` from `resolve_platform_config` is cleaner).

- [x] **2.8.1** `osx/collect_nettrace.sh`: Replace hardcoded `-f net11.0-macos -r osx-arm64` with `-f "$PLATFORM_TFM" -r "$PLATFORM_RID"`. Add `resolve_platform_config "osx"` call near the top.
- [x] **2.8.2** `maccatalyst/collect_nettrace.sh`: Same pattern — replace hardcoded values, add `resolve_platform_config "maccatalyst"`.

**Files:** `osx/collect_nettrace.sh`, `maccatalyst/collect_nettrace.sh`
**Acceptance criteria:** Each script uses `$PLATFORM_TFM` and `$PLATFORM_RID` from `resolve_platform_config` instead of hardcoded values.

### Phase C — Documentation

#### Step 2.9 — Documentation

- [x] **2.9.1** Update `ios/README.md` — add simulator section:
  - Usage: `--platform ios-simulator`
  - No code signing or provisioning profile required
  - Must have a booted simulator (`xcrun simctl boot <UDID>`)
  - Measurements are for relative comparison only (simulator ≠ device performance)
  - Xcode simulator runtime must be installed
- [x] **2.9.2** Update main `README.md`:
  - Add `android-emulator` and `ios-simulator` to the platform list
  - Add usage examples for both
  - Note prerequisites (booted emulator/simulator)
- [x] **2.9.3** Add inline comments in `init.sh` explaining the compound platform pattern for future additions (comments exist within each case block)

**Files:** `ios/README.md`, `README.md`, `init.sh`

### Known Gap — macOS / Mac Catalyst startup measurement

**Status:** Blocked. No scenario directories (`genericmacosstartup/`, `genericmaccatalyststartup/`) exist in the dotnet/performance submodule. `runner.py` rejects `osx` and `maccatalyst` device types. These platforms currently support **build and nettrace collection only** — not startup timing via `measure_startup.sh`.

**Future approach:** Create standalone `osx/measure_startup.sh` and `maccatalyst/measure_startup.sh` scripts (similar to `ios/measure_simulator_startup.sh`) that bypass `test.py` entirely and use platform-native timing. This is tracked separately and should not block emulator/simulator support.

---

## Step 3 — macOS (osx) Platform Support

See [.github/researches/osx-platform.md](.github/researches/osx-platform.md) for macOS-specific constraints, available configs, and startup measurement approach.

- [x] Create `osx/build-configs.props` — configs for macOS (research which Mono AOT configs apply)
- [x] Create `osx/build-workarounds.targets` — `GenerateInfoMacos` target
- [x] Create `osx/print_app_sizes.sh` — .app bundle size scanning
- [x] Add `osx` case to `resolve_platform_config()` in `init.sh`
- [x] Import `osx/build-configs.props` in `Directory.Build.props`
- [x] Import `osx/build-workarounds.targets` in `Directory.Build.targets`
- [x] Update `build.sh`, `measure_startup.sh`, `measure_all.sh` for `osx` platform
- [x] Update `generate-apps.sh` — generate `dotnet-new-macos` via `dotnet new macos`
- [x] Update `prepare.sh` — install `macos` workloads
- [x] Create `osx/README.md`
- [ ] Download macOS MIBC profiles if available → **see Step 7**

## Step 4 — Mac Catalyst Platform Support

See [.github/researches/maccatalyst-platform.md](.github/researches/maccatalyst-platform.md) for Mac Catalyst specifics (MAUI-only, no standalone template).

- [x] Create `maccatalyst/build-configs.props` — 6 configs (same set as iOS)
- [x] Create `maccatalyst/build-workarounds.targets` — `GenerateInfoMacCatalyst` target
- [x] Create `maccatalyst/print_app_sizes.sh`
- [x] Add `maccatalyst` case to `resolve_platform_config()` in `init.sh`
- [x] Import `maccatalyst/build-configs.props` in `Directory.Build.props`
- [x] Import `maccatalyst/build-workarounds.targets` in `Directory.Build.targets`
- [x] Update `build.sh`, `measure_startup.sh`, `measure_all.sh` for `maccatalyst` platform
- [x] Update `generate-apps.sh` — no standalone template; MAUI apps only with `net11.0-maccatalyst` TFM
- [x] Update `prepare.sh` — install `maccatalyst maui-maccatalyst` workloads
- [x] Create `maccatalyst/README.md`
- [ ] Download Mac Catalyst MIBC profiles if available → **see Step 7**

## Step 5 — Apple .nettrace Collection

See [.github/researches/apple-nettrace.md](.github/researches/apple-nettrace.md) for diagnostics bridge differences between Android and Apple platforms.

- [x] Create `ios/collect_nettrace.sh` — device trace collection via xcrun devicectl + dsrouter
- [x] Create desktop-style .nettrace collection for macOS/maccatalyst (direct process, no device bridge)

## Step 6 — Documentation

- [x] Update main `README.md` — add all Apple platforms to prerequisites, usage examples, project structure tree, config availability table

---

## Dependencies

```
Phase A (Android emulator) — self-contained, can ship independently
  Step 2.1 (init.sh android-emulator)
    └── Step 2.2 (validation in all scripts)
        └── Step 2.3 (android collect_nettrace RID parameterization)

Phase B (iOS simulator) — depends on Phase A for shared script updates
  Step 2.4 (init.sh ios-simulator)
    └── Step 2.5 (validation in all scripts)
        ├── Step 2.6 (custom simulator startup measurement + measure_startup.sh branching)
        ├── Step 2.7 (simulator nettrace support)
        └── Step 2.8 (remaining collect_nettrace RID parameterization)

Phase C (documentation) — after Phases A and B
  Step 2.9 (docs)
```

**Recommended commit order:**
1. **Phase A commit 1:** 2.1 + 2.2 — Android emulator: init.sh + all script validation updates
2. **Phase A commit 2:** 2.3 — Android collect_nettrace RID parameterization
3. **Phase B commit 1:** 2.4 + 2.5 — iOS simulator: init.sh + all script validation updates
4. **Phase B commit 2:** 2.6 — Custom simulator startup measurement script + measure_startup.sh branching
5. **Phase B commit 3:** 2.7 — iOS simulator nettrace support
6. **Phase B commit 4:** 2.8 — Remaining collect_nettrace RID parameterization
7. **Phase C commit:** 2.9 — Documentation

**Note:** Phase A can be shipped as a standalone PR. Phase B can be a separate PR.

## Testing Strategy

### Android Emulator (Phase A)
1. `./prepare.sh --platform android-emulator` — installs `android` workload (same as device)
2. `./generate-apps.sh --platform android-emulator` — produces `dotnet-new-android` and MAUI apps
3. `./build.sh --platform android-emulator dotnet-new-android CORECLR_JIT build 1` — builds with correct RID
4. `./measure_startup.sh dotnet-new-android CORECLR_JIT --platform android-emulator` — runs on emulator via `test.py --device-type android`
5. Verify on Apple Silicon: RID should be `android-arm64` (same as device — ARM emulator)
6. `android/collect_nettrace.sh dotnet-new-android CORECLR_JIT --platform android-emulator` — nettrace on emulator

### iOS Simulator (Phase B)
1. `./prepare.sh --platform ios-simulator` — installs `ios` workload (same as device)
2. `./generate-apps.sh --platform ios-simulator` — produces `dotnet-new-ios` and MAUI apps (with startup marker)
3. `./build.sh --platform ios-simulator dotnet-new-ios CORECLR_JIT build 1` — builds with `iossimulator-arm64` RID
4. `./measure_startup.sh dotnet-new-ios CORECLR_JIT --platform ios-simulator` — delegates to `ios/measure_simulator_startup.sh`, measures on booted simulator
5. `./measure_all.sh --platform ios-simulator --startup-iterations 1` — full sweep with 1 iteration, verifies output format compatibility
6. `ios/collect_nettrace.sh dotnet-new-ios CORECLR_JIT --platform ios-simulator` — nettrace on simulator (no dsrouter)

### Regression
- Verify `--platform android` and `--platform ios` (physical device) still work identically after changes
- All existing scripts must accept old platform values unchanged
- `generate-apps.sh --platform android` must not inject the startup marker (only `ios-simulator` needs it initially)

## Risks

| Risk | Severity | Mitigation |
|------|----------|------------|
| `iossimulator-arm64` MIBC profiles unavailable | Medium | `R2R_COMP_PGO` may fail or produce suboptimal results. Can skip this config for simulator initially. |
| Startup marker timing accuracy on simulator | Medium | Wall-clock from `simctl launch` to `Console.WriteLine` includes process spawn overhead. This is acceptable for relative comparison between configs. Document that absolute numbers differ from device. |
| `xcrun simctl launch --console-pty` output buffering | Medium | `Console.WriteLine` may be buffered. Test with `--console` vs `--console-pty` flags. May need `[Console]::Out.Flush()` or unbuffered stdout. |
| `android-x64` build configs untested on Intel hosts | Low | Apple Silicon is the primary host. Document x64 as best-effort. |
| Simulator boot/lifecycle management | Medium | Start simple: require a booted simulator, don't auto-manage lifecycle. Document `xcrun simctl boot` as prerequisite. Error clearly if no simulator is booted. |
| macOS/maccatalyst startup measurement gap | Low | Known and documented. These platforms support build + nettrace but not startup timing via `measure_startup.sh`. Separate future task. |
| `measure_all.sh` parsing output format from custom script | Medium | `ios/measure_simulator_startup.sh` must output `Generic Startup | avg | min | max` in the exact same format as `test.py`'s Startup tool. Test this parsing carefully. |

---

## Step 0 — Fix Apple Platform Build Failures (Prerequisite) ✅

> **Completed in PR #15.**

These fixes address build infrastructure bugs that block **all Apple platforms** from completing `prepare.sh` and building MAUI apps on macOS. They must be applied before any Apple platform work can proceed end-to-end.

**Research:** [.github/researches/apple-workload-failures.md](.github/researches/apple-workload-failures.md)

**Grouping rationale:** All four fixes are tightly related build infrastructure issues with the same root theme — the repo was originally Android-only and several scripts have Android-specific assumptions that break Apple platforms. A single PR is appropriate because (a) the changes are small and non-overlapping, (b) they share a single validation procedure, and (c) splitting them would leave the repo in a broken intermediate state for Apple.

### Task 0.1 — Stop overwriting NuGet.config in `prepare.sh` (Critical) ✅

**File:** `prepare.sh`, lines 110–115

**Problem:** `prepare.sh` downloads `NuGet.config` from `dotnet/android` main branch, overwriting the repo's committed config. The `dotnet/android` config has Android-specific darc feeds but lacks `dotnet11-transport` and other feeds needed for Apple workload packages (iOS, macOS, maccatalyst). This is why `dotnet workload install ios` fails with "missing NuGet package" errors while Android works fine.

**Change:** Remove the `curl` download block (lines 110–115) entirely. The repo's committed `NuGet.config` already has the correct feeds (`dotnet-public`, `dotnet-eng`, `dotnet11`, `dotnet11-transport`, `dotnet-tools`, plus the Android darc feed).

```bash
# REMOVE these lines (110-115):
# Download NuGet.config file from dotnet/android repo
curl -L -o "$NUGET_CONFIG" https://raw.githubusercontent.com/dotnet/android/main/NuGet.config
if [ $? -ne 0 ] || [ ! -f "$NUGET_CONFIG" ]; then
    echo "Error: Failed to download or locate NuGet.config file."
    exit 1
fi
```

**Acceptance criteria:** After `prepare.sh` completes, `NuGet.config` in the repo root is identical to the committed version (not replaced by an Android-specific one).

### Task 0.2 — Fix invalid `maui-macos` workload ID in `prepare.sh` (Critical) ✅

**File:** `prepare.sh`, line 134

**Problem:** For `--platform osx`, the script tries to install workloads `"macos maui-macos"`. The workload `maui-macos` does not exist in any .NET version. MAUI targets macOS through Mac Catalyst (`maui-maccatalyst`), not native macOS (AppKit). Valid MAUI workload IDs are: `maui-android`, `maui-ios`, `maui-maccatalyst`, `maui-tizen`, `maui-windows`.

**Change:** Line 134 — change `"macos maui-macos"` to `"macos"`:

```bash
# BEFORE:
osx)          WORKLOADS="macos maui-macos" ;;

# AFTER:
osx)          WORKLOADS="macos" ;;
```

**Acceptance criteria:** `./prepare.sh --platform osx` installs only the `macos` workload without errors. No attempt to install a non-existent `maui-macos` workload.

### Task 0.3 — Skip MAUI app generation for `osx` platform (Important) ✅

**Files:** `generate-apps.sh` (lines 197–199), `measure_all.sh` (lines 89–90)

**Problem:** MAUI apps cannot target `net11.0-macos`. MAUI supports macOS only through Mac Catalyst (`net11.0-maccatalyst`). Currently:
- `generate-apps.sh` generates MAUI apps unconditionally for all platforms (lines 197–199), so `--platform osx` generates MAUI apps that will fail to build with `net11.0-macos` TFM
- `measure_all.sh` includes `dotnet-new-maui` and `dotnet-new-maui-samplecontent` in the `osx` app list (lines 89–90), so `--platform osx` would attempt to measure apps that can't build

**Changes:**

1. **`generate-apps.sh`** — Wrap the MAUI app generation (lines 197–199) in a platform guard that skips `osx`:
   ```bash
   # BEFORE (lines 197-199):
   # MAUI apps work for all platforms
   generate_app "maui" "dotnet-new-maui"
   generate_app "maui" "dotnet-new-maui-samplecontent" "--sample-content"

   # AFTER:
   # MAUI apps work for all platforms except osx (MAUI targets macOS via maccatalyst, not native macos)
   if [ "$PLATFORM" != "osx" ]; then
       generate_app "maui" "dotnet-new-maui"
       generate_app "maui" "dotnet-new-maui-samplecontent" "--sample-content"
   else
       echo "Skipping MAUI apps for osx platform (MAUI targets macOS via maccatalyst, not native macos)"
   fi
   ```

2. **`measure_all.sh`** — Remove MAUI apps from the `osx` default app list (lines 89–90):
   ```bash
   # BEFORE:
   osx)
       APPS=("dotnet-new-macos" "dotnet-new-maui" "dotnet-new-maui-samplecontent")
       ;;

   # AFTER:
   osx)
       APPS=("dotnet-new-macos")
       ;;
   ```

**Acceptance criteria:**
- `./generate-apps.sh --platform osx` generates only `dotnet-new-macos`, skipping MAUI apps with a clear message
- `./measure_all.sh --platform osx` only attempts to measure `dotnet-new-macos`
- `./generate-apps.sh --platform ios` still generates MAUI apps (no regression)
- `./generate-apps.sh --platform maccatalyst` still generates MAUI apps (no regression)

### Task 0.4 — Update `rollback.json` band to preview.3 (Medium) ✅

**File:** `rollback.json`

**Problem:** SDK is `11.0.100-preview.3` (from `global.json`) but `rollback.json` pins all workloads to `11.0.100-preview.1` band. Cross-band rollback can fail because preview.1 manifests may reference packages incompatible with the preview.3 SDK. While rollback is opt-in (`-userollback` flag), it should be kept consistent.

**Change:** Update all band specifiers from `11.0.100-preview.1` to `11.0.100-preview.3`. The version numbers before the `/` may also need updating to match what's published for the preview.3 band — if the exact versions are unknown, add a comment noting that the versions need to be discovered from the preview.3 manifest.

```json
{
    "microsoft.net.sdk.android": "36.1.99-preview.3.XXXXX/11.0.100-preview.3",
    "microsoft.net.sdk.ios": "26.2.XXXXX-net11-p3/11.0.100-preview.3",
    "microsoft.net.sdk.maccatalyst": "26.2.XXXXX-net11-p3/11.0.100-preview.3",
    "microsoft.net.sdk.macos": "26.2.XXXXX-net11-p3/11.0.100-preview.3",
    "microsoft.net.sdk.maui": "11.0.0-preview.3.XXXXX/11.0.100-preview.3",
    "microsoft.net.sdk.tvos": "26.2.XXXXX-net11-p3/11.0.100-preview.3",
    "microsoft.net.workload.mono.toolchain.net9": "11.0.100-preview.3.XXXXX/11.0.100-preview.3",
    "microsoft.net.workload.mono.toolchain.current": "11.0.100-preview.3.XXXXX/11.0.100-preview.3"
}
```

**Discovery approach:** After applying Tasks 0.1–0.3, run `./prepare.sh -f --platform ios` (without `-userollback`). Then inspect the installed manifest versions via `.dotnet/dotnet workload --info` to discover the actual versions for preview.3. Update `rollback.json` with those versions.

**Acceptance criteria:** All band specifiers in `rollback.json` use `11.0.100-preview.3`. `./prepare.sh -f --platform ios -userollback` completes without band mismatch errors.

---

### Step 0 — Dependencies

```
Task 0.1 (NuGet.config) ─┐
Task 0.2 (workload ID)  ─┼── All independent, can be applied in any order
Task 0.3 (MAUI/osx skip) ┘
                           └── Task 0.4 (rollback.json) — depends on 0.1–0.3 for version discovery
```

### Step 0 — Testing Strategy

**Single validation sequence** (after applying all four fixes):

```bash
# 1. Verify NuGet.config is not overwritten
cp NuGet.config NuGet.config.expected
./prepare.sh -f --platform ios
diff NuGet.config NuGet.config.expected  # Should show no differences

# 2. Verify all Apple workloads install
./prepare.sh -f --platform ios           # Should succeed (was: missing NuGet package)
./prepare.sh -f --platform osx           # Should succeed (was: invalid maui-macos workload)
./prepare.sh -f --platform maccatalyst   # Should succeed (was: missing NuGet package)

# 3. Verify MAUI apps skipped for osx
./generate-apps.sh --platform osx        # Should only generate dotnet-new-macos
ls apps/                                 # Should NOT contain dotnet-new-maui*

# 4. Verify MAUI apps still generated for other platforms
rm -rf apps/
./generate-apps.sh --platform ios        # Should generate dotnet-new-ios + MAUI apps
ls apps/                                 # Should contain dotnet-new-maui, dotnet-new-maui-samplecontent

# 5. Verify Android is not regressed
./prepare.sh -f --platform android       # Should still work
./generate-apps.sh --platform android    # Should still generate all apps

# 6. Verify rollback (if updated)
./prepare.sh -f --platform ios -userollback  # Should succeed with preview.3 bands
```

### Step 0 — Risks

| Risk | Severity | Mitigation |
|------|----------|------------|
| Removing NuGet.config download may break Android if committed config lacks a needed Android feed | Low | The committed `NuGet.config` already has the `darc-pub-dotnet-android-*` feed (line 11). Verify Android still works after the change. |
| Apple workload packages may not be on `dotnet11-transport` for this specific preview version | Medium | This is Root Cause 4 from the research (preview package availability gap). If packages are missing even with correct feeds, the SDK preview version may need updating. This is a separate issue from the config fix. |
| `rollback.json` preview.3 versions unknown until workloads are installed | Low | Task 0.4 is ordered last. Run `dotnet workload --info` after Tasks 0.1–0.3 to discover correct versions. If rollback is not urgently needed, mark Task 0.4 as deferred. |
| Removing MAUI from `osx` reduces test coverage for macOS | Low | MAUI on Mac is only available through `maccatalyst` platform. The `maccatalyst` platform already has MAUI apps in its app list. No coverage is actually lost — it was never possible to build MAUI for native macOS. |

---

## Task 3 — Custom App Measurement Support ✅

> **Completed in PRs #16, #17, #18.**

See [.github/researches/custom-app-measurement.md](.github/researches/custom-app-measurement.md) for full research, including architecture analysis, design options, and risk assessment.

**Goal:** Enable users to measure startup performance of their own apps — either from source code or from pre-built binaries (`.apk`/`.app`). This complements the existing generated template apps (`dotnet-new-android`, `dotnet-new-ios`, etc.) with user-provided apps for real-world performance analysis.

**Key insight from research:** The pipeline already supports arbitrary app names in `apps/` — `build.sh`, `measure_startup.sh`, and `measure_all.sh --app <name>` all work with any app that follows the `apps/<name>/<name>.csproj` convention. The main gaps are:
1. `prepare.sh -f` destroys the entire `apps/` directory, deleting any custom app source
2. No way to measure a pre-built binary without going through the build stage
3. No documentation of the custom app workflow

**Design decisions:**
- **Source-based:** Use a git-tracked `custom-apps/` directory for custom app source. Apps are copied into `apps/` after generation, surviving `prepare.sh -f` resets. This is Option A1 from the research — cleanest separation with no risk of data loss.
- **Pre-built:** Add `--prebuilt --package-path <path>` flags to `measure_startup.sh` to skip the build stage and measure an existing binary directly. This is Option B1 from the research — minimal change, maximum flexibility.
- **No `measure_all.sh` integration for pre-built:** Pre-built binaries are a single config — the "sweep all configs" model doesn't apply. Users use `measure_startup.sh` directly.

### Step 3.1 — Protect custom apps from `prepare.sh -f` wipe ✅

> **Completed in PR #16.**

**Problem:** `prepare.sh` line 85 runs `rm -rf "$APPS_DIR"`, destroying everything in `apps/` including user-placed custom apps. This is the **critical blocker** for source-based custom app support.

**Approach:** Change `prepare.sh` to selectively delete only known generated app directories instead of wiping the entire `apps/` directory. The known generated apps are deterministic — they come from `generate-apps.sh` template+name mappings.

- [x] **3.1.1** Replace `rm -rf "$APPS_DIR"` (line 85) with selective deletion of known generated apps:
  ```bash
  # Instead of: rm -rf "$APPS_DIR"
  # Delete only known generated app directories
  GENERATED_APPS=("dotnet-new-android" "dotnet-new-ios" "dotnet-new-macos" "dotnet-new-maui" "dotnet-new-maui-samplecontent")
  for app in "${GENERATED_APPS[@]}"; do
      rm -rf "${APPS_DIR:?}/$app"
  done
  ```
  Keep the `GENERATED_APPS` list in sync with the app names used in `generate-apps.sh` (lines 184, 187, 189, 199–200). Add a comment noting this coupling.

- [x] **3.1.2** Ensure `apps/` directory is created if it doesn't exist (it currently gets created by `generate-apps.sh`, but with selective deletion the directory might already exist with custom apps):
  ```bash
  mkdir -p "$APPS_DIR"
  ```
  Add this after the selective deletion block, before calling `generate-apps.sh`.

**Files:** `prepare.sh`
**Acceptance criteria:**
- `prepare.sh -f --platform ios` does NOT delete a manually-placed `apps/my-custom-app/` directory
- `prepare.sh -f --platform ios` still removes `apps/dotnet-new-ios/`, `apps/dotnet-new-maui/`, etc. before regenerating
- `generate-apps.sh` still works correctly after `prepare.sh -f` (apps are regenerated from scratch)

---

### Step 3.2 — Create `custom-apps/` directory with registration ✅

> **Completed in PR #16.**

**Goal:** Provide a git-tracked directory where users can version-control their custom app source code. A registration step copies these into `apps/` so the existing build/measure pipeline works unchanged.

- [x] **3.2.1** Create `custom-apps/` directory structure:
  ```
  custom-apps/
  └── README.md           ← Conventions, naming rules, platform requirements
  ```
  The `README.md` should document:
  - Directory naming: `custom-apps/<app-name>/<app-name>.csproj` (must match)
  - The csproj must include the target platform's TFM in `<TargetFrameworks>` (e.g., `net11.0-ios`)
  - App name must not start with `Microsoft.`, `System.`, `Mono.`, `Xamarin.` (assembly name collision guard)
  - `Directory.Build.props/targets` from the repo root will automatically apply — this is expected and provides `_BuildConfig` support
  - PGO/R2R_COMP_PGO: Custom apps need a `profiles/` subdirectory with `.mibc` files, or should skip the `R2R_COMP_PGO` config
  - NuGet dependencies: The repo's `NuGet.config` has limited feeds (no nuget.org). Custom apps with external NuGet packages may need the user to add feeds to `NuGet.config`

- [x] **3.2.2** Add `.gitkeep` or the `README.md` to `custom-apps/` so the directory is tracked in git. Do NOT add `custom-apps/` to `.gitignore`.

- [x] **3.2.3** Add a registration step to `prepare.sh` that copies custom apps into `apps/` after `generate-apps.sh` completes:
  ```bash
  # Register custom apps (after generate-apps.sh)
  CUSTOM_APPS_DIR="$SCRIPT_DIR/custom-apps"
  if [ -d "$CUSTOM_APPS_DIR" ]; then
      for custom_app in "$CUSTOM_APPS_DIR"/*/; do
          [ -d "$custom_app" ] || continue
          app_name=$(basename "$custom_app")
          # Skip README and non-app directories
          [ -f "$custom_app/$app_name.csproj" ] || continue
          target="$APPS_DIR/$app_name"
          if [ -d "$target" ]; then
              echo "Custom app '$app_name' already exists in apps/, skipping copy."
          else
              echo "Registering custom app: $app_name"
              cp -r "$custom_app" "$target"
          fi
      done
  fi
  ```
  Place this after the `generate-apps.sh` call (line 196–200) and before the "Environment setup complete" message.

- [x] **3.2.4** Validate the csproj naming convention during registration. If `custom-apps/<name>/` exists but `<name>.csproj` is missing, print a warning:
  ```
  Warning: custom-apps/<name>/ does not contain <name>.csproj — skipping. Expected: custom-apps/<name>/<name>.csproj
  ```

**Files:** `custom-apps/README.md` (new), `prepare.sh`
**Acceptance criteria:**
- A user places `custom-apps/my-app/my-app.csproj` and runs `prepare.sh -f --platform ios` → `apps/my-app/` exists after completion
- A directory `custom-apps/notes/` with no csproj is ignored with a warning
- `custom-apps/README.md` explains the conventions clearly
- Custom apps survive `prepare.sh -f` (they're re-copied from `custom-apps/` into `apps/`)

---

### Step 3.3 — Pre-built binary measurement in `measure_startup.sh` ✅

> **Completed in PR #17.**

**Goal:** Allow users to measure startup of a pre-built `.apk` or `.app` without building from source. This addresses the use case where the binary was built externally (CI pipeline, different machine, third-party app).

- [x] **3.3.1** Add `--prebuilt`, `--package-path <path>`, and `--package-name <name>` flags to `measure_startup.sh`:
  - `--prebuilt` — Skip the build stage entirely. Requires `--package-path`.
  - `--package-path <path>` — Path to the `.apk` file or `.app` bundle directory. Implies `--prebuilt`.
  - `--package-name <name>` — Package name (Android) or bundle ID (iOS/macOS). Optional — auto-extracted if omitted (see 3.3.2).
  - When `--prebuilt` is set:
    - Skip the build stage (lines 97–111)
    - Skip csproj-based package name lookup (lines 91–95)
    - Use `--package-path` directly instead of the `find` glob (line 114)
    - Still compute package size (lines 120–134 — this logic already handles both files and directories)
    - Still run the `test.py` measurement (lines 158–162)
    - Use a synthetic `RESULT_NAME` like `prebuilt_<basename>_<timestamp>` instead of `${SAMPLE_APP}_${BUILD_CONFIG}`
  - When `--prebuilt` is set, the positional `<app-name>` and `<build-config>` arguments become optional (not needed since we're not building). Adjust the argument parsing to handle this.

- [x] **3.3.2** Auto-extract bundle ID / package name when `--package-name` is not provided:
  - **iOS/macOS (.app bundles):** Use PlistBuddy to read `CFBundleIdentifier`:
    ```bash
    PACKAGE_NAME=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$PACKAGE_PATH/Info.plist" 2>/dev/null)
    ```
    This pattern already exists in `ios/measure_simulator_startup.sh` lines 308–321.
  - **Android (.apk files):** Use `aapt2` from the Android SDK:
    ```bash
    PACKAGE_NAME=$(aapt2 dump badging "$PACKAGE_PATH" 2>/dev/null | grep "^package:" | sed "s/.*name='\([^']*\)'.*/\1/")
    ```
    If `aapt2` is not available, fall back to requiring `--package-name`.
  - If auto-extraction fails and `--package-name` was not provided, error with a clear message explaining how to provide it.

- [x] **3.3.3** Validate the pre-built binary exists and is the expected type:
  - If `--platform` is `android*` and `--package-path` doesn't end in `.apk`, warn (but don't fail — could be a different extension)
  - If `--platform` is `ios*|osx|maccatalyst` and `--package-path` isn't a directory ending in `.app`, warn
  - If the path doesn't exist, error immediately

- [x] **3.3.4** Update `print_usage()` in `measure_startup.sh` to document the new flags with examples:
  ```
  Pre-built measurement:
    --prebuilt                   Skip build, measure existing binary
    --package-path <path>        Path to .apk or .app bundle (implies --prebuilt)
    --package-name <name>        Package name / bundle ID (auto-detected if omitted)

  Examples:
    $0 --prebuilt --package-path ~/builds/MyApp-Signed.apk --platform android
    $0 --prebuilt --package-path ~/builds/MyApp.app --platform ios
  ```

**Files:** `measure_startup.sh`
**Acceptance criteria:**
- `./measure_startup.sh --prebuilt --package-path /path/to/app.apk --platform android` measures startup without building
- `./measure_startup.sh --prebuilt --package-path /path/to/App.app --platform ios` measures startup, auto-extracting bundle ID from Info.plist
- `./measure_startup.sh --prebuilt --package-path /path/to/app.apk --package-name com.example.app --platform android` uses the provided package name
- Missing `--package-path` with `--prebuilt` produces a clear error
- Missing `--package-name` with `--prebuilt` for Android where `aapt2` isn't available produces a clear error explaining the flag

---

### Step 3.4 — Pre-built binary measurement in `ios/measure_simulator_startup.sh` ✅

> **Completed in PR #17.**

**Goal:** Extend the existing `--no-build` flag in `ios/measure_simulator_startup.sh` to support external package paths, enabling pre-built app measurement on the iOS simulator.

The script already has `--no-build` (line 109–112) which skips the build stage but still expects the `.app` bundle to be in the standard `$APP_DIR/bin/` location. We need to add `--package-path` to specify an external bundle location.

- [x] **3.4.1** Add `--package-path <path>` flag to `ios/measure_simulator_startup.sh`:
  - When provided with `--no-build`, use this path directly instead of the `find` glob (lines 287–295)
  - Validate the path exists and is a directory ending in `.app`
  - Bundle ID extraction (lines 308–321) already reads from the `.app/Info.plist` — this works regardless of where the bundle is located

- [x] **3.4.2** Make positional `<app-name>` and `<build-config>` arguments optional when `--no-build --package-path` is used:
  - The app name can be derived from the bundle path basename (e.g., `MyApp.app` → `MyApp`)
  - The build config can default to `PREBUILT` for result file naming
  - Adjust the argument validation at lines 61–68 to allow this

- [x] **3.4.3** Update `print_usage()` to document the `--package-path` flag with pre-built examples:
  ```
  Examples:
    $0 --no-build --package-path ~/builds/MyApp.app
    $0 --no-build --package-path ~/builds/MyApp.app --simulator-name 'iPhone 16'
  ```

**Files:** `ios/measure_simulator_startup.sh`
**Acceptance criteria:**
- `ios/measure_simulator_startup.sh --no-build --package-path /path/to/MyApp.app` installs and measures the pre-built app on a booted simulator
- Bundle ID is auto-extracted from `Info.plist` within the provided `.app` bundle
- Results are saved with a meaningful filename (e.g., `MyApp_PREBUILT_simulator.csv`)

---

### Step 3.5 — Example custom app and end-to-end documentation ✅

> **Completed in PR #18.**

**Goal:** Provide a minimal working example in `custom-apps/` and comprehensive documentation covering both source-based and pre-built workflows.

- [x] **3.5.1** Create a minimal example custom app in `custom-apps/`:
  ```
  custom-apps/
  ├── README.md             ← (from Step 3.2)
  └── hello-custom/
      └── hello-custom.csproj
  ```
  The example should be:
  - A minimal iOS app (simplest template — single `AppDelegate.cs` + csproj)
  - Multi-TFM if possible: `<TargetFrameworks>net11.0-ios;net11.0-android</TargetFrameworks>` to demonstrate cross-platform support
  - Include a comment in the csproj explaining the `_BuildConfig` property group inheritance
  - Include a note about PGO profiles (either provide an empty `profiles/` directory or document that `R2R_COMP_PGO` should be skipped)

- [x] **3.5.2** Update the main `README.md` with a "Custom App Measurement" section:
  - **Source-based workflow:**
    1. Place app source in `custom-apps/<app-name>/<app-name>.csproj`
    2. Run `prepare.sh -f --platform <platform>` (copies custom apps into `apps/`)
    3. Build: `./build.sh --platform <platform> <app-name> <config> build 1`
    4. Measure: `./measure_startup.sh <app-name> <config> --platform <platform>`
    5. Or: `./measure_all.sh --platform <platform> --app <app-name>`
  - **Pre-built workflow:**
    1. `./measure_startup.sh --prebuilt --package-path /path/to/app.apk --platform android`
    2. `./measure_startup.sh --prebuilt --package-path /path/to/App.app --platform ios`
    3. `ios/measure_simulator_startup.sh --no-build --package-path /path/to/App.app`
  - **Conventions and requirements** (brief — link to `custom-apps/README.md` for details)
  - **Limitations:** NuGet feed restrictions, PGO profile requirements, `Directory.Build.props` inheritance

- [x] **3.5.3** Update `custom-apps/README.md` (from Step 3.2) with:
  - The hello-custom example walkthrough
  - Troubleshooting section: common errors (csproj name mismatch, missing TFM, NuGet restore failures, `Directory.Build.props` conflicts)
  - Platform compatibility matrix (which TFMs work with which `--platform` values)

**Files:** `custom-apps/hello-custom/hello-custom.csproj` (new), `custom-apps/README.md` (update), `README.md` (update)
**Acceptance criteria:**
- `prepare.sh -f --platform ios` copies `hello-custom` into `apps/`
- `build.sh --platform ios hello-custom CORECLR_JIT build 1` builds successfully
- `measure_startup.sh hello-custom CORECLR_JIT --platform ios` measures successfully
- Documentation covers both workflows with copy-paste-ready commands

---

### Task 3 — Dependencies

```
Step 3.1 (protect custom apps in prepare.sh)
  └── Step 3.2 (custom-apps/ directory + registration)
        └── Step 3.5 (example app + documentation)

Step 3.3 (prebuilt in measure_startup.sh) — independent of 3.1/3.2
Step 3.4 (prebuilt in simulator script) — independent of 3.1/3.2, can parallel 3.3

Step 3.5 depends on 3.1 + 3.2 (source-based workflow) and 3.3 + 3.4 (pre-built docs)
```

**Recommended PR / commit order:**
1. **PR 1:** Steps 3.1 + 3.2 — Source-based custom app infrastructure (prepare.sh protection + custom-apps/ directory)
2. **PR 2:** Steps 3.3 + 3.4 — Pre-built binary measurement (measure_startup.sh + simulator script)
3. **PR 3:** Step 3.5 — Example app + end-to-end documentation

PRs 1 and 2 are independent and can be developed in parallel.

### Task 3 — Testing Strategy

#### Source-Based Custom Apps (Steps 3.1 + 3.2)

```bash
# 1. Place a custom app
mkdir -p custom-apps/test-custom
cat > custom-apps/test-custom/test-custom.csproj << 'EOF'
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <TargetFrameworks>net11.0-ios</TargetFrameworks>
    <OutputType>Exe</OutputType>
  </PropertyGroup>
</Project>
EOF

# 2. Run prepare.sh -f — custom app should survive and be registered
./prepare.sh -f --platform ios
ls apps/test-custom/  # Should exist

# 3. Verify generated apps were regenerated (not stale)
ls apps/dotnet-new-ios/  # Should exist (freshly generated)

# 4. Build and measure the custom app
./build.sh --platform ios test-custom CORECLR_JIT build 1
./measure_all.sh --platform ios --app test-custom --startup-iterations 1

# 5. Run prepare.sh -f again — custom app should still survive
./prepare.sh -f --platform ios
ls apps/test-custom/  # Should still exist
```

#### Pre-Built Binary Measurement (Steps 3.3 + 3.4)

```bash
# 1. Build an app normally first
./build.sh --platform ios dotnet-new-ios CORECLR_JIT build 1

# 2. Find the built .app bundle
APP_BUNDLE=$(find apps/dotnet-new-ios -name "*.app" -path "*/Release/*" | head -1)

# 3. Measure the pre-built binary (no rebuild)
./measure_startup.sh --prebuilt --package-path "$APP_BUNDLE" --platform ios

# 4. Test auto-extraction of bundle ID
./measure_startup.sh --prebuilt --package-path "$APP_BUNDLE" --platform ios
# Should auto-extract bundle ID from Info.plist

# 5. Test with explicit package name
./measure_startup.sh --prebuilt --package-path "$APP_BUNDLE" --package-name com.companyname.dotnet_new_ios --platform ios

# 6. iOS simulator pre-built
./ios/measure_simulator_startup.sh --no-build --package-path "$APP_BUNDLE"

# 7. Error cases
./measure_startup.sh --prebuilt --platform ios  # Should error: --package-path required
./measure_startup.sh --prebuilt --package-path /nonexistent.app --platform ios  # Should error: path doesn't exist
```

#### Regression

- `prepare.sh -f --platform android` still works (no custom apps → same behavior as before)
- `measure_startup.sh dotnet-new-android CORECLR_JIT --platform android` still works (no `--prebuilt` → same behavior)
- `measure_all.sh --platform ios` still uses default app list (no custom apps in defaults)
- `generate-apps.sh --platform ios` still generates template apps correctly

### Task 3 — Risks

| Risk | Severity | Mitigation |
|------|----------|------------|
| `GENERATED_APPS` list in `prepare.sh` gets out of sync with `generate-apps.sh` | Medium | Add a comment in both files noting the coupling. Consider extracting the list to a shared variable in `init.sh`. |
| Custom apps with `Directory.Build.props` conflicts | Medium | Document in `custom-apps/README.md` that the repo's `Directory.Build.props` is inherited automatically. Custom apps should not have their own `Directory.Build.props` — or if they do, they must use `<Import>` carefully. |
| NuGet restore failures for custom apps with external dependencies | Medium | Document in `custom-apps/README.md` that nuget.org is not in the repo's `NuGet.config`. Users must add feeds manually or use `--source` during restore. |
| Bundle ID auto-extraction fails for unusual app structures | Low | Provide clear error messages explaining `--package-name` as fallback. PlistBuddy is always available on macOS; `aapt2` may not be on PATH for Android. |
| Pre-built binary architecture mismatch (e.g., device .app on simulator) | Medium | Validate and warn but don't block — the deployment/launch step will fail with a clear error from simctl/adb. |
| `measure_startup.sh` argument parsing complexity increases significantly | Medium | Keep the `--prebuilt` path as a clean early-exit branch. Parse flags first, then branch: if `--prebuilt`, validate prebuilt requirements and skip to measurement; else, validate source requirements and build first. |
| Custom apps without PGO profiles fail on `R2R_COMP_PGO` config | Low | Document that `R2R_COMP_PGO` requires `.mibc` profiles in `<app>/profiles/`. Without them, the build succeeds but R2R compilation may not include PGO optimizations (the `--partial` flag allows this gracefully). |

---

## Step 7 — MIBC Profile Download Script

See [.github/researches/mibc-profiles.md](.github/researches/mibc-profiles.md) for full research, including NuGet V3 API details, package naming, internal structure, and integration points.

**Goal:** Create a `download-mibc.sh` script that downloads MIBC (Managed Image Based Compilation) profiles from the public Azure Artifacts NuGet feed. These profiles are consumed by `R2R_COMP_PGO` builds to guide crossgen2's ReadyToRun compilation for PGO-optimized native images.

**Motivation:** The repo already has full `R2R_COMP_PGO` infrastructure — `generate-apps.sh` copies `profiles/*.mibc` into apps, patches csproj with `_ReadyToRunPgoFiles`, and crossgen2 uses `--mibc` flags. The only missing piece is **downloading the profiles** into the `profiles/` directory. This step completes the PGO pipeline and replaces the "deferred — stretch goal" items in Steps 1, 3, and 4.

**Design decisions:**
- **Shell script approach** — consistent with repo conventions (`prepare.sh`, `build.sh`, etc.)
- **NuGet V3 flat container API** — public, no auth required, packages are ZIP files
- **`dotnet-tools` feed** — already in `NuGet.config` (line 20), confirmed as primary feed for optimization packages
- **Graceful 404 handling** — some platform packages may not exist; warn and exit 0 (not an error)
- **Simulator fallback** — `iossimulator-arm64` profiles likely don't exist; fall back to `ios-arm64`

### Overview

**Script:** `download-mibc.sh` (new file at repo root)

**Interface:**
```
./download-mibc.sh [--platform <platform>] [--version <version>]
```

| Flag | Description | Default |
|------|-------------|---------|
| `--platform <platform>` | Target platform (same values as other scripts) | `android` |
| `--version <version>` | Pin a specific package version | Latest (queried from feed) |

**Behavior:**
1. Resolve `PLATFORM_RID` from `--platform` via `init.sh`'s `resolve_platform_config()`
2. Construct package ID: `optimization.{RID}.MIBC.Runtime` (e.g., `optimization.ios-arm64.MIBC.Runtime`)
3. Query the NuGet V3 flat container API for available versions
4. Select the latest version (or the user-specified `--version`)
5. Download the `.nupkg` file
6. Extract `data/*.mibc` files into `profiles/`
7. Clean up the downloaded `.nupkg`
8. Log the downloaded version

**Output:** `.mibc` files in `profiles/` directory (gitignored, consumed by `generate-apps.sh`)

### Step 7.1 — Create `download-mibc.sh`

- [ ] **7.1.1** Create the script file at repo root: `download-mibc.sh`

  **Script structure** (follow existing patterns from `prepare.sh`, `build.sh`):

  ```
  #!/bin/bash
  source "$(dirname "$0")/init.sh"
  # Parse arguments
  # Resolve platform config
  # Determine package ID and RID
  # Query versions from feed
  # Download nupkg
  # Extract MIBC files
  # Clean up
  # Log results
  ```

  **Argument parsing** — follow the exact pattern from `prepare.sh` lines 10–34:
  - Parse `--platform` (default: `android`) and `--version` (default: empty → latest)
  - Validate `--platform` has a value (not empty or starts with `--`)
  - Validate `--version` has a value if provided
  - Unknown flags → error with usage message
  - Add `print_usage()` function matching the style of `measure_all.sh` lines 11–28

  **Platform config resolution:**
  - Call `resolve_platform_config "$PLATFORM" || exit 1`
  - Use `$PLATFORM_RID` to construct the package ID

  **Simulator/emulator RID fallback:**
  - After resolving `PLATFORM_RID`, check for simulator/emulator RIDs that likely have no MIBC packages
  - Map: `iossimulator-arm64` → `ios-arm64`, `iossimulator-x64` → `ios-arm64`
  - Map: `android-x64` → `android-arm64` (emulator on x64 host; arm64 profiles are more likely to exist)
  - Store the original RID in `ORIGINAL_RID` and the download RID in `DOWNLOAD_RID`
  - Print a notice when falling back: `"Note: No MIBC profiles for $ORIGINAL_RID, using $DOWNLOAD_RID profiles instead"`
  - **Do NOT fall back for**: `android-arm64`, `ios-arm64`, `osx-arm64`, `maccatalyst-arm64` — these are the primary targets

  **Package ID construction:**
  - `PACKAGE_ID="optimization.${DOWNLOAD_RID}.MIBC.Runtime"`
  - `LOWERCASED_ID=$(echo "$PACKAGE_ID" | tr '[:upper:]' '[:lower:]')` — NuGet flat container requires lowercase in URLs

  **Constants:**
  - `FLAT_CONTAINER_URL="https://pkgs.dev.azure.com/dnceng/public/_packaging/dotnet-tools/nuget/v3/flat2"`
  - `PROFILES_DIR="$SCRIPT_DIR/profiles"`

- [ ] **7.1.2** Implement version query logic

  **Query available versions:**
  ```bash
  VERSIONS_URL="${FLAT_CONTAINER_URL}/${LOWERCASED_ID}/index.json"
  HTTP_CODE=$(curl -s -o /tmp/mibc-versions.json -w "%{http_code}" "$VERSIONS_URL")
  ```

  **Handle HTTP responses:**
  - `200` → parse versions JSON
  - `404` → package does not exist on this feed. Print warning: `"Warning: MIBC package '$PACKAGE_ID' not found on dotnet-tools feed. R2R_COMP_PGO builds will proceed without PGO profiles (--partial ensures this is safe)."` Exit 0 (not an error — the build will still work with `--partial`).
  - Other → print error with HTTP code, exit 1

  **Parse versions** — use `python3` (already a prerequisite, used in `prepare.sh` line 86):
  ```bash
  VERSION=$(python3 -c "import json,sys; v=json.load(sys.stdin)['versions']; print(v[-1])" < /tmp/mibc-versions.json)
  ```
  This selects the last element (latest version, since NuGet returns versions in ascending order).

  **Version override:**
  - If `--version` was provided, use that value directly instead of querying
  - Still query the versions list to validate the version exists:
    ```bash
    python3 -c "import json,sys; v=json.load(sys.stdin)['versions']; assert sys.argv[1] in v, f'Version {sys.argv[1]} not found'" "$USER_VERSION" < /tmp/mibc-versions.json
    ```
  - If validation fails, print the available versions and exit 1

- [ ] **7.1.3** Implement download and extraction

  **Download the nupkg:**
  ```bash
  NUPKG_URL="${FLAT_CONTAINER_URL}/${LOWERCASED_ID}/${VERSION}/${LOWERCASED_ID}.${VERSION}.nupkg"
  NUPKG_FILE="/tmp/${LOWERCASED_ID}.${VERSION}.nupkg"
  curl -L -f -o "$NUPKG_FILE" "$NUPKG_URL"
  ```
  - Use `-f` to fail on HTTP errors (non-2xx)
  - Check exit code; if non-zero, print error with URL and exit 1

  **Extract MIBC files:**
  ```bash
  mkdir -p "$PROFILES_DIR"
  unzip -j -o "$NUPKG_FILE" 'data/*.mibc' -d "$PROFILES_DIR"
  ```
  - `-j` — junk paths (flatten `data/` prefix, extract directly into `profiles/`)
  - `-o` — overwrite existing files without prompting

  **Validate extraction:**
  - Check that at least one `.mibc` file was extracted:
    ```bash
    MIBC_COUNT=$(find "$PROFILES_DIR" -name "*.mibc" -maxdepth 1 | wc -l)
    ```
  - If zero, warn: `"Warning: No .mibc files found in package $PACKAGE_ID $VERSION"`

  **Cleanup:**
  - `rm -f "$NUPKG_FILE"` — remove the downloaded nupkg (it can be large)
  - `rm -f /tmp/mibc-versions.json` — remove the versions cache

- [ ] **7.1.4** Implement logging and output

  **Console output** — print clear, informative messages at each stage:
  ```
  === Downloading MIBC profiles ===
  Platform: ios (RID: ios-arm64)
  Package: optimization.ios-arm64.MIBC.Runtime
  Version: 1.0.0-prerelease.25.12345.2 (latest)
  Downloading from: https://pkgs.dev.azure.com/...
  Extracting to: /path/to/profiles/
  Extracted 3 MIBC profile(s):
    - scenario1.mibc
    - scenario2.mibc
    - scenario3.mibc
  === MIBC profile download complete ===
  ```

  **`versions.log` integration:**
  - Append a line to `$VERSIONS_LOG`: `"mibc profiles: $PACKAGE_ID $VERSION"`
  - Use `>>` (append), not `>` (overwrite), since `versions.log` is populated by `prepare.sh`
  - Only append if `$VERSIONS_LOG` is set and writable

  **List extracted files:**
  - After extraction, list the `.mibc` files in `profiles/` so the user can see what was downloaded

- [ ] **7.1.5** Add `--help` flag

  Follow `measure_all.sh` pattern (lines 11–28):
  ```
  Usage: ./download-mibc.sh [options]

  Downloads MIBC (PGO) profiles for ReadyToRun Composite PGO builds.

  Options:
    --platform <name>    Target platform: android, android-emulator, ios, ios-simulator, osx, maccatalyst (default: android)
    --version <version>  Pin a specific MIBC package version (default: latest)
    --help               Show this help message

  The downloaded profiles are placed in profiles/ and are automatically
  picked up by generate-apps.sh for R2R_COMP_PGO builds.

  Examples:
    ./download-mibc.sh --platform ios                    # Latest iOS profiles
    ./download-mibc.sh --platform android --version 1.0.0-prerelease.25.12345.2
  ```

**Files:** `download-mibc.sh` (new)

**Acceptance criteria:**
- `./download-mibc.sh --platform ios` downloads MIBC profiles into `profiles/` (or warns gracefully if package doesn't exist)
- `./download-mibc.sh --platform android --version 1.0.0-prerelease.25.12345.2` downloads the specific version
- `./download-mibc.sh --platform ios-simulator` falls back to `ios-arm64` profiles with a notice
- `./download-mibc.sh --help` prints usage
- Invalid `--version` prints available versions and exits 1
- The script is executable (`chmod +x`)
- No authentication required — uses public feed only

---

### Step 7 — Dependencies

```
Step 7.1 — self-contained, no dependencies on other steps
  7.1.1 (script skeleton + arg parsing)
    └── 7.1.2 (version query)
        └── 7.1.3 (download + extraction)
            └── 7.1.4 (logging)
  7.1.5 (help) — independent, can be done with 7.1.1
```

This is a **single PR** with one commit. All sub-items (7.1.1–7.1.5) are parts of the same file and should be implemented together.

### Step 7 — Testing Strategy

```bash
# 1. Basic download — latest version for a known platform
./download-mibc.sh --platform android
ls profiles/*.mibc    # Should contain at least one .mibc file
cat versions.log      # Should contain "mibc profiles: optimization.android-arm64.MIBC.Runtime ..."

# 2. Specific version
./download-mibc.sh --platform android --version 1.0.0-prerelease.25.12345.2
# Should download exactly that version

# 3. Invalid version
./download-mibc.sh --platform android --version 99.99.99
# Should error with available versions listed

# 4. Platform that may not have profiles
./download-mibc.sh --platform osx
# Should either download profiles or warn gracefully (exit 0)

# 5. Simulator fallback
./download-mibc.sh --platform ios-simulator
# Should print notice about falling back to ios-arm64, then download

# 6. Help
./download-mibc.sh --help
# Should print usage and exit 0

# 7. End-to-end integration — verify generate-apps.sh picks up profiles
./download-mibc.sh --platform ios
./generate-apps.sh --platform ios
ls apps/dotnet-new-ios/profiles/*.mibc    # Should contain copied .mibc files

# 8. Idempotency — running twice should overwrite cleanly
./download-mibc.sh --platform ios
./download-mibc.sh --platform ios
# No errors, profiles/ contains same files
```

### Step 7 — Risks

| Risk | Severity | Mitigation |
|------|----------|------------|
| MIBC packages may not exist for Apple platforms (`ios-arm64`, `osx-arm64`, etc.) | High | Handle HTTP 404 gracefully — warn and exit 0. The `--partial` crossgen2 flag ensures R2R_COMP_PGO builds succeed without profiles (just without PGO optimization). Verify package existence during development by testing the versions URL manually. |
| Feed URL changes in future .NET versions | Low | The `dotnet-tools` feed URL is a well-known constant. Hardcode it with a comment. If it changes, a single line edit fixes it. |
| `python3` not available | Low | Already a prerequisite for the repo (used in `prepare.sh` line 86, `generate-apps.sh` lines 74, 123). Validated in `prepare.sh` line 75. |
| Large nupkg download on slow connections | Low | MIBC packages are typically small (< 10 MB). The download is a single HTTP request. Consider adding `--progress-bar` to curl for visibility. |
| `unzip` not extracting `data/*.mibc` if internal structure differs across versions | Low | The `data/` directory is the documented and observed path for all known optimization packages (confirmed in MAUI reference). If the structure changes, the extraction will silently produce zero files — caught by the post-extraction validation (Step 7.1.3). |
| Temp file collisions if script is run concurrently | Low | Use a unique temp directory (`mktemp -d`) instead of fixed `/tmp/mibc-*` paths. Clean up in a `trap` handler. |
| NuGet versions list is empty (feed returns `{"versions": []}`) | Low | Check that the parsed version is non-empty before proceeding. Print an error: "No versions found for package..." |

