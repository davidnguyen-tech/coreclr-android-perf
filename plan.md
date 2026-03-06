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
- [ ] Fetch iOS MIBC profiles from `dotnet-optimization` CI for R2R_COMP_PGO builds (see [Maestro channel 5172](https://maestro.dot.net/channel/5172/azdo:dnceng:internal:dotnet-optimization/build/latest))

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

- [ ] **2.1.1** Extend `resolve_platform_config()` in `init.sh`:
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

- [ ] **2.2.1** `prepare.sh`:
  - Line 22: Update error message to include `android-emulator`
  - Line 30: Update usage text
  - Line 38: Change `android|ios|osx|maccatalyst` to `android|android-emulator|ios|osx|maccatalyst`
  - Line 40: Update error message
  - Lines 129–134: Add `android|android-emulator) WORKLOADS="android maui-android" ;;`
  - Lines 143–148: Add `android|android-emulator) WORKLOAD_ID="android" ;;`
- [ ] **2.2.2** `build.sh`:
  - Line 12: Update error message
  - Line 38: Update usage text
- [ ] **2.2.3** `measure_startup.sh`:
  - Line 28: Update usage text (add `android-emulator`)
  - Line 52: Update error message
- [ ] **2.2.4** `measure_all.sh`:
  - Line 17: Update usage text
  - Line 34: Update error message
  - Lines 72–79 (config lists): Change `android)` to `android|android-emulator)`
  - Lines 82–95 (app lists): Change `android)` to `android|android-emulator)`
- [ ] **2.2.5** `generate-apps.sh`:
  - Lines 20, 28: Update error/usage text
  - Lines 182–184 (template generation): Change `android)` to `android|android-emulator)`
  - Line 133 (Python `patch_app`): Change `if platform == "android":` to `if platform in ("android", "android-emulator"):`

**Files:** `prepare.sh`, `build.sh`, `measure_startup.sh`, `measure_all.sh`, `generate-apps.sh`
**Acceptance criteria:** `./prepare.sh --platform android-emulator`, `./generate-apps.sh --platform android-emulator`, `./build.sh --platform android-emulator ...`, `./measure_startup.sh ... --platform android-emulator`, and `./measure_all.sh --platform android-emulator` all run without validation errors. Existing `--platform android` behavior is unchanged.

#### Step 2.3 — Parameterize RID in `android/collect_nettrace.sh`

- [ ] **2.3.1** Add `--platform` flag to `android/collect_nettrace.sh` (default: `android`):
  - Parse `--platform` from args, call `resolve_platform_config "$PLATFORM"`
  - Replace hardcoded `-f net11.0-android -r android-arm64` with `-f "$PLATFORM_TFM" -r "$PLATFORM_RID"`
- [ ] **2.3.2** Verify adb commands in the script work with emulators (they should — adb is transport-transparent)

**Files:** `android/collect_nettrace.sh`
**Acceptance criteria:** `android/collect_nettrace.sh app config --platform android-emulator` builds with correct RID for host architecture.

### Phase B — iOS Simulator (custom measurement script)

#### Step 2.4 — Add `ios-simulator` to `init.sh`

- [ ] **2.4.1** Extend `resolve_platform_config()` in `init.sh`:
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

- [ ] **2.5.1** `prepare.sh`:
  - Update validation case: add `ios-simulator` to pattern
  - Update workload mapping: `ios|ios-simulator) WORKLOADS="ios maui-ios" ;;`
  - Update workload ID: `ios|ios-simulator) WORKLOAD_ID="ios" ;;`
  - Update all error/usage text strings
- [ ] **2.5.2** `build.sh`: Update error/usage text strings
- [ ] **2.5.3** `measure_all.sh`:
  - Config lists: Change `ios|osx|maccatalyst)` to `ios|ios-simulator|osx|maccatalyst)`
  - App lists: Add `ios-simulator)` case (same apps as `ios`: `dotnet-new-ios dotnet-new-maui dotnet-new-maui-samplecontent`)
  - Or use `ios|ios-simulator)` pattern for both
  - Update error/usage text
- [ ] **2.5.4** `generate-apps.sh`:
  - Template generation: Change `ios)` to `ios|ios-simulator)`
  - Update error/usage text
- [ ] **2.5.5** `measure_startup.sh`: Update usage text. The actual branching to custom measurement happens in Step 2.6.

**Files:** `prepare.sh`, `build.sh`, `measure_startup.sh`, `measure_all.sh`, `generate-apps.sh`
**Acceptance criteria:** All scripts accept `--platform ios-simulator` without validation errors. Existing `--platform ios` behavior is unchanged.

#### Step 2.6 — Custom iOS simulator startup measurement

**Why a custom script:** `test.py`'s iOS path hardcodes `--target ios-device`, `--launchdev`, and `sudo log collect --device`. The startup measurement technique uses SpringBoard Watchdog events which don't exist on simulators. Patching `runner.py` would require maintaining a submodule fork. Instead, we write a standalone script that handles simulator deployment and timing directly.

**Measurement approach:** Use `xcrun simctl` for install/launch, measure startup via:
- Option 1: Parse `os_signpost` / `os_log` events from `log stream` (the simulator's OS subsystem still logs app lifecycle events)
- Option 2: Use `xcrun simctl launch --console` and measure time from launch to first output (if app logs a marker)
- Option 3: Measure wall-clock time from `simctl launch` to process appearing in `simctl list` as running, then to process exit or first-draw signal
- **Recommended: Option 2** — add a startup marker `Console.WriteLine` to generated apps (a `[START]` log line), and measure time from `simctl launch` to seeing that marker. Simple, reliable, no sudo required.

- [ ] **2.6.1** Create `ios/measure_simulator_startup.sh`:
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

- [ ] **2.6.2** Add startup marker to generated iOS apps:
  - In `generate-apps.sh`, for `ios|ios-simulator)` template generation, add a post-generation patch that inserts `Console.WriteLine("[STARTUP_COMPLETE]");` at the end of app initialization
  - For `dotnet new ios` template: patch `AppDelegate.cs` or `Program.cs` (whichever the template creates)
  - For MAUI apps: patch `MauiProgram.cs` or `App.xaml.cs` with the marker
  - **Keep it minimal**: a single `Console.WriteLine` that fires after the app's initial UI loads
  - **Note**: This marker is also useful for Android emulator measurements as a secondary timing source, but don't add it to Android apps yet — keep scope focused

- [ ] **2.6.3** Update `measure_startup.sh` to branch for `ios-simulator`:
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

- [ ] **2.7.1** Add `--platform` flag to `ios/collect_nettrace.sh` (default: `ios`). When `--platform ios-simulator`, use simulator flow.
- [ ] **2.7.2** Simulator device detection:
  - Use `xcrun simctl list devices booted -j` instead of `xcrun devicectl list devices`
  - Accept `--device-id` to target a specific simulator UDID
- [ ] **2.7.3** Simulator install/launch:
  - Install: `xcrun simctl install <UDID> <app-bundle-path>`
  - Launch: `xcrun simctl launch <UDID> <bundle-id>` with `DOTNET_DiagnosticPorts` env var
  - Env vars passed directly on `simctl launch` command line (no `MtouchExtraArgs --setenv` needed)
- [ ] **2.7.4** Remove dsrouter dependency for simulator:
  - Skip dsrouter startup (no `--forward-port iOS`)
  - Use direct diagnostic socket (like `osx/collect_nettrace.sh` pattern)
- [ ] **2.7.5** Update cleanup function:
  - For simulator: `xcrun simctl uninstall <UDID> <bundle-id>`
  - No dsrouter cleanup needed

**Files:** `ios/collect_nettrace.sh`
**Reference:** `osx/collect_nettrace.sh` for the direct diagnostic port pattern
**Acceptance criteria:** `ios/collect_nettrace.sh app config --platform ios-simulator` collects a nettrace without dsrouter, using simulator deployment.

#### Step 2.8 — Parameterize RIDs in remaining `collect_nettrace.sh` scripts

While here, parameterize the other `collect_nettrace.sh` scripts for consistency (even though `osx` and `maccatalyst` don't have emulator/simulator variants, using `$PLATFORM_RID` from `resolve_platform_config` is cleaner).

- [ ] **2.8.1** `osx/collect_nettrace.sh`: Replace hardcoded `-f net11.0-macos -r osx-arm64` with `-f "$PLATFORM_TFM" -r "$PLATFORM_RID"`. Add `resolve_platform_config "osx"` call near the top.
- [ ] **2.8.2** `maccatalyst/collect_nettrace.sh`: Same pattern — replace hardcoded values, add `resolve_platform_config "maccatalyst"`.

**Files:** `osx/collect_nettrace.sh`, `maccatalyst/collect_nettrace.sh`
**Acceptance criteria:** Each script uses `$PLATFORM_TFM` and `$PLATFORM_RID` from `resolve_platform_config` instead of hardcoded values.

### Phase C — Documentation

#### Step 2.9 — Documentation

- [ ] **2.9.1** Update `ios/README.md` — add simulator section:
  - Usage: `--platform ios-simulator`
  - No code signing or provisioning profile required
  - Must have a booted simulator (`xcrun simctl boot <UDID>`)
  - Measurements are for relative comparison only (simulator ≠ device performance)
  - Xcode simulator runtime must be installed
- [ ] **2.9.2** Update main `README.md`:
  - Add `android-emulator` and `ios-simulator` to the platform list
  - Add usage examples for both
  - Note prerequisites (booted emulator/simulator)
- [ ] **2.9.3** Add inline comments in `init.sh` explaining the compound platform pattern for future additions

**Files:** `ios/README.md`, `README.md`, `init.sh`

### Known Gap — macOS / Mac Catalyst startup measurement

**Status:** Blocked. No scenario directories (`genericmacosstartup/`, `genericmaccatalyststartup/`) exist in the dotnet/performance submodule. `runner.py` rejects `osx` and `maccatalyst` device types. These platforms currently support **build and nettrace collection only** — not startup timing via `measure_startup.sh`.

**Future approach:** Create standalone `osx/measure_startup.sh` and `maccatalyst/measure_startup.sh` scripts (similar to `ios/measure_simulator_startup.sh`) that bypass `test.py` entirely and use platform-native timing. This is tracked separately and should not block emulator/simulator support.

---

## Step 3 — macOS (osx) Platform Support

See [.github/researches/osx-platform.md](.github/researches/osx-platform.md) for macOS-specific constraints, available configs, and startup measurement approach.

- [ ] Create `osx/build-configs.props` — configs for macOS (research which Mono AOT configs apply)
- [ ] Create `osx/build-workarounds.targets` — `GenerateInfoMacos` target
- [ ] Create `osx/print_app_sizes.sh` — .app bundle size scanning
- [ ] Add `osx` case to `resolve_platform_config()` in `init.sh`
- [ ] Import `osx/build-configs.props` in `Directory.Build.props`
- [ ] Import `osx/build-workarounds.targets` in `Directory.Build.targets`
- [ ] Update `build.sh`, `measure_startup.sh`, `measure_all.sh` for `osx` platform
- [ ] Update `generate-apps.sh` — generate `dotnet-new-macos` via `dotnet new macos`
- [ ] Update `prepare.sh` — install `macos` workloads
- [ ] Create `osx/README.md`
- [ ] Fetch macOS MIBC profiles from `dotnet-optimization` CI if available

## Step 4 — Mac Catalyst Platform Support

See [.github/researches/maccatalyst-platform.md](.github/researches/maccatalyst-platform.md) for Mac Catalyst specifics (MAUI-only, no standalone template).

- [ ] Create `maccatalyst/build-configs.props` — 6 configs (same set as iOS)
- [ ] Create `maccatalyst/build-workarounds.targets` — `GenerateInfoMacCatalyst` target
- [ ] Create `maccatalyst/print_app_sizes.sh`
- [ ] Add `maccatalyst` case to `resolve_platform_config()` in `init.sh`
- [ ] Import `maccatalyst/build-configs.props` in `Directory.Build.props`
- [ ] Import `maccatalyst/build-workarounds.targets` in `Directory.Build.targets`
- [ ] Update `build.sh`, `measure_startup.sh`, `measure_all.sh` for `maccatalyst` platform
- [ ] Update `generate-apps.sh` — no standalone template; MAUI apps only with `net11.0-maccatalyst` TFM
- [ ] Update `prepare.sh` — install `maccatalyst maui-maccatalyst` workloads
- [ ] Create `maccatalyst/README.md`
- [ ] Fetch Mac Catalyst MIBC profiles from `dotnet-optimization` CI if available

## Step 5 — Apple .nettrace Collection

See [.github/researches/apple-nettrace.md](.github/researches/apple-nettrace.md) for diagnostics bridge differences between Android and Apple platforms.

- [ ] Create `ios/collect_nettrace.sh` — device trace collection via xcrun devicectl + dsrouter
- [ ] Create desktop-style .nettrace collection for macOS/maccatalyst (direct process, no device bridge)

## Step 6 — Documentation

- [ ] Update main `README.md` — add all Apple platforms to prerequisites, usage examples, project structure tree, config availability table

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

