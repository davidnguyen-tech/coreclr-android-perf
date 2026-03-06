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

**Goal:** Enable startup measurement on Android emulators and iOS simulators using compound platform values (`android-emulator`, `ios-simulator`). No physical device required.

**Design decision:** Use **Option C — Compound platform values** from the research. Platform values like `ios-simulator` and `android-emulator` share configuration with their base platform via `|` pattern matching in bash `case` statements. Only the RID and device interaction layer differ.

**Priority order:** iOS simulator first (higher CI value — no code signing, no device), then Android emulator.

### Step 2.0 — Investigate dotnet/performance submodule ⬅️ DO FIRST

**Why:** The `test.py devicestartup --device-type` parameter controls how the dotnet/performance harness deploys and measures apps. We don't know if it supports simulator/emulator values. This blocks Steps 2.2–2.5.

- [ ] **2.0.1** Initialize submodule: run `git submodule update --init --recursive` to populate `external/performance/`
- [ ] **2.0.2** Check scenario directories: `ls external/performance/src/scenarios/generic*` — are there separate simulator directories (e.g., `genericiossimulatorstartup`)?
- [ ] **2.0.3** Check `test.py` device-type handling: search for `device.type`, `device_type`, `DeviceType` in `external/performance/src/scenarios/` and the test harness code to determine accepted values
- [ ] **2.0.4** Check xharness target selection: does test.py pass `--target` to xharness based on device type? Does `ios` device type work for simulators, or is a separate value needed?
- [ ] **2.0.5** Document findings: update this plan with the actual device-type values, scenario directories, and any test.py changes needed

**Files to examine:**
- `external/performance/src/scenarios/genericiosstartup/test.py`
- `external/performance/src/scenarios/genericandroidstartup/test.py`
- Any shared harness code imported by these test.py files

**Acceptance criteria:** We know the exact `--device-type` value to pass for iOS simulator and Android emulator, and whether any test.py modifications are needed.

### Step 2.1 — Add compound platform values to `init.sh`

Add `ios-simulator` and `android-emulator` cases to `resolve_platform_config()`. These share all configuration with their base platform except the RID (and potentially `PLATFORM_DEVICE_TYPE`).

- [ ] **2.1.1** Extend `resolve_platform_config()` in `init.sh` (lines 31–72):
  - Change `android)` to `android|android-emulator)` — same body, but add inner `if` for emulator RID:
    ```
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
  - Change `ios)` to `ios|ios-simulator)` — same body, but add inner `if` for simulator RID:
    ```
    if [[ "$platform" == "ios-simulator" ]]; then
        if [[ "$(uname -m)" == "arm64" ]]; then
            PLATFORM_RID="iossimulator-arm64"
        else
            PLATFORM_RID="iossimulator-x64"
        fi
    else
        PLATFORM_RID="ios-arm64"
    fi
    ```
  - **Note:** `PLATFORM_DEVICE_TYPE` value depends on Step 2.0 findings. If test.py needs a different value for simulators, set it conditionally here. If `ios` works for both, keep it as-is.
  - Update error message on line 69 to include `android-emulator, ios-simulator`

**Files:** `init.sh`
**Acceptance criteria:** `resolve_platform_config "ios-simulator"` sets `PLATFORM_RID=iossimulator-arm64` (on Apple Silicon) and `PLATFORM_TFM=net11.0-ios`. All other variables match `ios`.

### Step 2.2 — Update platform validation in all scripts

Every script that validates the `--platform` flag needs to accept the new compound values.

- [ ] **2.2.1** `prepare.sh` (line 38): Add `android-emulator|ios-simulator` to the validation case pattern
- [ ] **2.2.2** `prepare.sh` (lines 22, 30, 40): Update error messages/usage text to include new values
- [ ] **2.2.3** `prepare.sh` (lines 129–134): Map compound platforms to base workloads:
  - `android-emulator` → `WORKLOADS="android maui-android"` (same as `android`)
  - `ios-simulator` → `WORKLOADS="ios maui-ios"` (same as `ios`)
  - Use `|` pattern: `android|android-emulator) WORKLOADS="android maui-android" ;;`
- [ ] **2.2.4** `prepare.sh` (lines 143–148): Map compound platforms to base workload IDs:
  - `android|android-emulator) WORKLOAD_ID="android" ;;`
  - `ios|ios-simulator) WORKLOAD_ID="ios" ;;`
- [ ] **2.2.5** `build.sh` (lines 12, 39): Update error/usage text to include new platform values
- [ ] **2.2.6** `measure_startup.sh` (lines 28, 52): Update error/usage text
- [ ] **2.2.7** `measure_all.sh` (lines 17, 34): Update error/usage text
- [ ] **2.2.8** `generate-apps.sh` (lines 20, 28): Update error/usage text

**Files:** `prepare.sh`, `build.sh`, `measure_startup.sh`, `measure_all.sh`, `generate-apps.sh`
**Acceptance criteria:** All scripts accept `--platform ios-simulator` and `--platform android-emulator` without validation errors.

### Step 2.3 — Update `generate-apps.sh` for compound platforms

The template generation and profiling patches must map compound platform names to their base template.

- [ ] **2.3.1** `generate-apps.sh` (lines 182–195): Add compound platform cases to the template generation `case` block:
  - `ios-simulator` generates the same `dotnet-new-ios` app as `ios` (same template, same TFM — the RID at build time differentiates)
  - `android-emulator` generates the same `dotnet-new-android` app as `android`
  - Use `|` pattern: `android|android-emulator)` and `ios|ios-simulator)`
- [ ] **2.3.2** `generate-apps.sh` — Verify that `patch_app()` (lines 101–177) works for compound platforms:
  - Line 133: `if platform == "android":` — needs to also match `android-emulator`. Change to `if platform in ("android", "android-emulator"):`
  - The profiling environment file (`android/env.txt`, `android/env-nettrace.txt`) applies to emulators too — no separate file needed

**Files:** `generate-apps.sh`
**Acceptance criteria:** `./generate-apps.sh --platform ios-simulator` produces `dotnet-new-ios` and MAUI apps with `net11.0-ios` TFM. `./generate-apps.sh --platform android-emulator` produces `dotnet-new-android` and MAUI apps with `net11.0-android` TFM.

### Step 2.4 — Update `measure_all.sh` for compound platforms

Add config lists and default app lists for the new platform values.

- [ ] **2.4.1** `measure_all.sh` (lines 72–79): Add config lists for compound platforms:
  - `ios-simulator` → same 6 configs as `ios` (MachO → no non-composite R2R)
  - `android-emulator` → same 7 configs as `android`
  - Use `|` pattern: `android|android-emulator)` and `ios|ios-simulator)`
- [ ] **2.4.2** `measure_all.sh` (lines 82–95): Add default app lists:
  - `ios-simulator` → same apps as `ios`: `dotnet-new-ios dotnet-new-maui dotnet-new-maui-samplecontent`
  - `android-emulator` → same apps as `android`: `dotnet-new-android dotnet-new-maui dotnet-new-maui-samplecontent`
  - Use `|` pattern

**Files:** `measure_all.sh`
**Acceptance criteria:** `./measure_all.sh --platform ios-simulator` iterates over the correct 6 configs × 3 apps.

### Step 2.5 — Parameterize hardcoded RIDs in `collect_nettrace.sh` scripts

All four `collect_nettrace.sh` scripts hardcode their RID in the `dotnet build` command. Parameterize them to use `$PLATFORM_RID` from `init.sh` (which they already source).

- [ ] **2.5.1** `android/collect_nettrace.sh` line 211: Replace `-r android-arm64` with `-r "$PLATFORM_RID"` and `-f net11.0-android` with `-f "$PLATFORM_TFM"`
  - Add `resolve_platform_config` call near the top if not already present, or accept `--platform` flag
  - **Decision:** These scripts currently don't accept `--platform`. Add platform detection: default to the base platform (e.g., `android`) but allow override. Or simpler: just use the variables from `init.sh` after calling `resolve_platform_config`.
- [ ] **2.5.2** `ios/collect_nettrace.sh` lines 272–274: Replace `-f net11.0-ios -r ios-arm64` with `-f "$PLATFORM_TFM" -r "$PLATFORM_RID"`
- [ ] **2.5.3** `osx/collect_nettrace.sh` line 151: Replace `-f net11.0-macos -r osx-arm64` with `-f "$PLATFORM_TFM" -r "$PLATFORM_RID"`
- [ ] **2.5.4** `maccatalyst/collect_nettrace.sh` line 151: Replace `-f net11.0-maccatalyst -r maccatalyst-arm64` with `-f "$PLATFORM_TFM" -r "$PLATFORM_RID"`
- [ ] **2.5.5** Add `resolve_platform_config` calls to each script. Determine the platform from the script's directory (e.g., `android/collect_nettrace.sh` → `android`), or add a `--platform` flag.
  - **Recommended approach:** Each script calls `resolve_platform_config` with its base platform as default. For scripts that need emulator/simulator support (android, ios), add a `--platform` flag that allows `android-emulator` or `ios-simulator`.

**Files:** `android/collect_nettrace.sh`, `ios/collect_nettrace.sh`, `osx/collect_nettrace.sh`, `maccatalyst/collect_nettrace.sh`
**Acceptance criteria:** Each script uses `$PLATFORM_TFM` and `$PLATFORM_RID` instead of hardcoded values. Building with `--platform android-emulator` on an Apple Silicon host produces an `android-arm64` build; on x64 host, `android-x64`.

### Step 2.6 — iOS simulator `collect_nettrace.sh` support

The iOS simulator runs apps on the host machine, so nettrace collection follows the **macOS/maccatalyst pattern** (direct diagnostic port, no dsrouter bridge). This is a significant simplification over the device flow.

- [ ] **2.6.1** Add simulator detection to `ios/collect_nettrace.sh`:
  - Accept `--platform` flag (default: `ios`). When `--platform ios-simulator`, use simulator flow.
  - **Alternative:** Create a separate `ios/collect_nettrace_simulator.sh` script. This avoids complex branching but duplicates setup code.
  - **Recommended:** Add a conditional branch within `ios/collect_nettrace.sh` since most setup (arg parsing, validation, build) is shared. Only the device-detection, dsrouter, install, and launch steps differ.
- [ ] **2.6.2** Simulator device detection (replaces lines 140–168):
  - Use `xcrun simctl list devices available -j` instead of `xcrun devicectl list devices`
  - Auto-select a booted simulator, or boot one if none is running
  - Accept `--device-id` to target a specific simulator UDID
- [ ] **2.6.3** Simulator install/launch (replaces lines 308–339):
  - Install: `xcrun simctl install <UDID> <app-bundle-path>` or `xharness apple install --target ios-simulator-64`
  - Launch: `xcrun simctl launch <UDID> <bundle-id>` (with env vars for diagnostics)
  - Key advantage: env vars can be passed directly on `simctl launch` command line instead of `MtouchExtraArgs --setenv`
- [ ] **2.6.4** Remove dsrouter dependency for simulator:
  - Skip dsrouter startup (no `--forward-port iOS`)
  - Use direct diagnostic socket (like `osx/collect_nettrace.sh` pattern)
  - Set `DOTNET_DiagnosticPorts` via `xcrun simctl launch --env:DOTNET_DiagnosticPorts=...`
- [ ] **2.6.5** Update cleanup function (lines 205–227):
  - For simulator: `xcrun simctl uninstall <UDID> <bundle-id>` or `xharness apple uninstall --target ios-simulator-64`
  - No dsrouter cleanup needed

**Files:** `ios/collect_nettrace.sh`
**Reference:** `osx/collect_nettrace.sh` (lines 140–200) for the direct diagnostic port pattern
**Acceptance criteria:** `ios/collect_nettrace.sh app config --platform ios-simulator` collects a nettrace without dsrouter, using simulator deployment.

### Step 2.7 — Documentation

- [ ] **2.7.1** Update `ios/README.md` — add simulator section explaining:
  - Usage: `--platform ios-simulator`
  - No code signing or provisioning profile required
  - Measurements are for relative comparison only (simulator ≠ device performance)
  - Xcode simulator runtime must be installed
- [ ] **2.7.2** Update main `README.md` — add `android-emulator` and `ios-simulator` to the platform list, usage examples, and any prerequisites section
- [ ] **2.7.3** Add inline comments in `init.sh` explaining the compound platform pattern for future platform additions

**Files:** `ios/README.md`, `README.md`, `init.sh`

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
Step 2.0 (submodule investigation)
  ├── blocks → Step 2.1 (PLATFORM_DEVICE_TYPE value)
  ├── blocks → Step 2.4 (scenario dir for measure_all)
  └── blocks → Step 2.5–2.6 (nettrace flow)

Step 2.1 (init.sh)
  └── blocks → Step 2.2 (validation), 2.3 (generate), 2.4 (measure_all)

Step 2.2 (validation) — independent of 2.3, 2.4, 2.5

Step 2.5 (RID parameterization)
  └── blocks → Step 2.6 (simulator nettrace)

Step 2.7 (docs) — after all other Step 2 sub-steps
```

**Recommended commit order within a single PR:**
1. 2.0 — Submodule investigation (may be a separate exploratory PR / commit)
2. 2.1 + 2.2 — Core platform plumbing (init.sh + validation in all scripts)
3. 2.3 — generate-apps.sh update
4. 2.4 — measure_all.sh update
5. 2.5 — RID parameterization in collect_nettrace.sh scripts
6. 2.6 — iOS simulator nettrace support
7. 2.7 — Documentation

## Testing Strategy

### iOS Simulator
1. `./prepare.sh --platform ios-simulator` — installs `ios` workload (same as device)
2. `./generate-apps.sh --platform ios-simulator` — produces `dotnet-new-ios` and MAUI apps
3. `./build.sh --platform ios-simulator dotnet-new-ios CORECLR_JIT build 1` — builds with `iossimulator-arm64` RID
4. `./measure_startup.sh dotnet-new-ios CORECLR_JIT --platform ios-simulator` — runs startup measurement on simulator
5. `./measure_all.sh --platform ios-simulator --startup-iterations 1` — full sweep with 1 iteration
6. `ios/collect_nettrace.sh dotnet-new-ios CORECLR_JIT --platform ios-simulator` — nettrace on simulator

### Android Emulator
1. `./prepare.sh --platform android-emulator` — installs `android` workload
2. `./build.sh --platform android-emulator dotnet-new-android CORECLR_JIT build 1` — builds with correct RID
3. `./measure_startup.sh dotnet-new-android CORECLR_JIT --platform android-emulator` — runs on emulator
4. Verify on Apple Silicon: RID should be `android-arm64` (same as device)

### Regression
- Verify `--platform android` and `--platform ios` (physical device) still work identically after changes
- All existing scripts must accept old platform values unchanged

## Risks

| Risk | Severity | Mitigation |
|------|----------|------------|
| `test.py` doesn't support simulator device type | **Critical** | Step 2.0 investigates first. If unsupported, we may need to fork test.py or implement custom measurement. |
| `iossimulator-arm64` MIBC profiles unavailable | Medium | `R2R_COMP_PGO` may fail or produce suboptimal results. Can skip this config for simulator initially. |
| iOS watchdog kills simulator app during nettrace | Low | Simulators are more lenient than devices. Direct diagnostic port (no dsrouter) connects faster. |
| `android-x64` build configs untested on Intel hosts | Low | Apple Silicon is the primary host. Document x64 as best-effort. |
| Simulator boot/lifecycle management | Medium | Start simple: require a booted simulator, don't auto-manage lifecycle. Document `xcrun simctl boot` as prerequisite. |

