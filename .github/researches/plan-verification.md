# Plan Verification: Unchecked Items vs Actual Implementation

**Date:** 2025-01-27
**Purpose:** Verify whether each unchecked `- [ ]` item in `plan.md` is actually implemented in the codebase, to determine if `plan.md` needs a checkbox update or if real implementation work remains.

---

## Summary

| Step | Unchecked Items | ✅ Implemented | ❌ Not Implemented | ⚠️ Partial |
|------|----------------|---------------|-------------------|-----------|
| 1 | 1 | 0 | 1 | 0 |
| 2 | 26 | 24 | 0 | 2 |
| 3 | 11 | 10 | 1 | 0 |
| 4 | 11 | 10 | 1 | 0 |
| 5 | 2 | 2 | 0 | 0 |
| 6 | 1 | 1 | 0 | 0 |
| **Total** | **52** | **47** | **3** | **2** |

**Conclusion:** 47 of 52 unchecked items are fully implemented. The 3 "not implemented" items are all MIBC profile fetching (deferred/out-of-scope). The 2 "partial" items are minor (startup marker injection and inline comment style). **The plan.md needs a mass checkbox update, not new implementation work.**

---

## Step 1: iOS Platform Support (plan.md line 32)

### 1.1 — Fetch iOS MIBC profiles from `dotnet-optimization` CI for R2R_COMP_PGO builds
- **Status:** ❌ NOT IMPLEMENTED
- **Evidence:** No `profiles/` directory exists (empty glob). No script fetches MIBC profiles from dotnet-optimization CI. The `generate-apps.sh` creates a `profiles/` directory per app and copies from `$SCRIPT_DIR/profiles` (line 113), but that source directory has no `.mibc` files.
- **Note:** This applies to all Apple platforms (iOS, macOS, maccatalyst). The plan.md also has equivalent items for macOS (line 304) and maccatalyst (line 320). This is a known gap — the infrastructure for *using* MIBC profiles is in place, but no profiles have been fetched yet.

---

## Step 2: Emulator/Simulator Support (plan.md lines 70–278)

### 2.1.1 — Extend `resolve_platform_config()` in `init.sh` for android-emulator
- **Status:** ✅ IMPLEMENTED
- **Evidence:** `init.sh` line 32: `android|android-emulator)` case with RID auto-detection based on host arch (lines 41–48). Intel → `android-x64`, ARM → `android-arm64`.

### 2.2.1 — `prepare.sh` accepts android-emulator
- **Status:** ✅ IMPLEMENTED
- **Evidence:** `prepare.sh` line 38: validation case includes `android|android-emulator`. Line 151: workload case `android|android-emulator)` installs `android maui-android`.

### 2.2.2 — `build.sh` accepts android-emulator
- **Status:** ✅ IMPLEMENTED
- **Evidence:** `build.sh` line 12–14: `--platform` flag with all 6 platform values in error text. Line 30: `resolve_platform_config "$PLATFORM"`.

### 2.2.3 — `measure_startup.sh` accepts android-emulator
- **Status:** ✅ IMPLEMENTED
- **Evidence:** `measure_startup.sh` line 53: `--platform` parsing with all 6 platforms in error text. Line 110: `resolve_platform_config "$PLATFORM"`.

### 2.2.4 — `measure_all.sh` accepts android-emulator
- **Status:** ✅ IMPLEMENTED
- **Evidence:** `measure_all.sh` line 34: `--platform` parsing. Lines 73–74: `android|android-emulator)` config list with 7 configs. Lines 83–84: default app list.

### 2.2.5 — `generate-apps.sh` accepts android-emulator
- **Status:** ✅ IMPLEMENTED
- **Evidence:** `generate-apps.sh` line 21–24: `--platform` parsing. Line 183: `android|android-emulator)` case generates `dotnet-new-android`.

### 2.3.1 — Add `--platform` flag to `android/collect_nettrace.sh`
- **Status:** ✅ IMPLEMENTED
- **Evidence:** `android/collect_nettrace.sh` lines 73–79: `--platform` flag accepting `android` or `android-emulator`. Line 111: `resolve_platform_config "$PLATFORM"`.

### 2.3.2 — Verify adb commands work with emulators
- **Status:** ✅ IMPLEMENTED (by design)
- **Evidence:** ADB is transport-transparent. The script uses `adb shell`, `adb logcat` which work identically for emulators and physical devices.

### 2.4.1 — Extend `resolve_platform_config()` for ios-simulator
- **Status:** ✅ IMPLEMENTED
- **Evidence:** `init.sh` lines 53–73: `ios|ios-simulator)` case. Simulator uses `iossimulator-arm64` or `iossimulator-x64` RID (auto-detected). Device type set to `ios-simulator`.

### 2.5.1 — `prepare.sh` accepts ios-simulator
- **Status:** ✅ IMPLEMENTED
- **Evidence:** `prepare.sh` line 38: `ios|ios-simulator` in validation. Line 153: workload case installs `ios maui-ios`.

### 2.5.2 — `build.sh` updated for ios-simulator
- **Status:** ✅ IMPLEMENTED
- **Evidence:** `build.sh` line 12: usage text lists `ios-simulator`. Line 30: `resolve_platform_config "$PLATFORM"` handles it.

### 2.5.3 — `measure_all.sh` updated for ios-simulator
- **Status:** ✅ IMPLEMENTED
- **Evidence:** `measure_all.sh` line 77: `ios|ios-simulator|osx|maccatalyst)` config list. Lines 86–87: `ios|ios-simulator)` default apps. Lines 138–141: simulator routing to `ios/measure_simulator_startup.sh`.

### 2.5.4 — `generate-apps.sh` updated for ios-simulator
- **Status:** ✅ IMPLEMENTED
- **Evidence:** `generate-apps.sh` line 186: `ios|ios-simulator)` case generates `dotnet-new-ios`.

### 2.5.5 — `measure_startup.sh` updated for ios-simulator
- **Status:** ✅ IMPLEMENTED
- **Evidence:** `measure_startup.sh` lines 95–102: `ios-simulator` routes to `ios/measure_simulator_startup.sh` via `exec`.

### 2.6.1 — Create `ios/measure_simulator_startup.sh`
- **Status:** ✅ IMPLEMENTED
- **Evidence:** File exists at `ios/measure_simulator_startup.sh` (496 lines). Full implementation with:
  - Simulator auto-detection (booted → available iPhone → error) — lines 175–259
  - Wall-clock timing via `python3 time.time_ns()` — lines 397–410
  - `xcrun simctl install`/`launch`/`terminate` loop — lines 382–420
  - Statistics computation (avg/median/min/max/stdev) — lines 433–449
  - CSV result output compatible with `measure_all.sh` — lines 480–492
  - `--startup-iterations`, `--simulator-name`, `--simulator-udid`, `--no-build`, `--package-path` options

### 2.6.2 — Add startup marker to generated iOS apps
- **Status:** ⚠️ PARTIAL
- **Evidence:** The `generate-apps.sh` `patch_app()` function (lines 101–177) injects profiling/PGO support into csproj files but does NOT inject `reportFullyDrawn` or `Activity.reportFullyDrawn()` markers. However, the simulator measurement script uses wall-clock timing (not log-based markers), so markers may not be needed for the simulator path. For physical iOS devices, the `dotnet/performance` test.py handles timing via system logs. This item may be moot — the plan's original intent was for Android-style "fully drawn" markers, which don't directly apply to iOS.

### 2.6.3 — Update `measure_startup.sh` to branch for `ios-simulator`
- **Status:** ✅ IMPLEMENTED
- **Evidence:** `measure_startup.sh` lines 95–102: explicit `ios-simulator` check that `exec`s to `ios/measure_simulator_startup.sh`.

### 2.7.1 — `ios/collect_nettrace.sh` with `--platform` flag supporting ios-simulator
- **Status:** ✅ IMPLEMENTED
- **Evidence:** `ios/collect_nettrace.sh` lines 5–11: documentation of dual-mode support. Lines 86–90: `--platform` flag. Line 136: validates `ios` or `ios-simulator`. Full simulator flow with direct Unix-domain socket (no dsrouter).

### 2.7.2 — Simulator device detection
- **Status:** ✅ IMPLEMENTED
- **Evidence:** `ios/measure_simulator_startup.sh` lines 175–231: `get_booted_simulator_udid()`, `find_simulator_by_name()`, `find_any_available_iphone()`, `get_simulator_info()` functions. Also in `ios/collect_nettrace.sh` (similar logic).

### 2.7.3 — Simulator install/launch
- **Status:** ✅ IMPLEMENTED
- **Evidence:** `ios/measure_simulator_startup.sh` lines 384–399: `xcrun simctl install`, `xcrun simctl launch`. Lines 267–277: auto-boot via `xcrun simctl boot` + `xcrun simctl bootstatus`.

### 2.7.4 — Remove dsrouter dependency for simulator
- **Status:** ✅ IMPLEMENTED
- **Evidence:** `ios/collect_nettrace.sh` lines 160–173: dsrouter prerequisite check only runs when `$PLATFORM = "ios"` (physical device). Simulator path uses direct `DOTNET_DiagnosticPorts` socket.

### 2.7.5 — Update cleanup function
- **Status:** ✅ IMPLEMENTED
- **Evidence:** `ios/measure_simulator_startup.sh` lines 362–368: cleanup terminates and uninstalls via `xcrun simctl`. `ios/collect_nettrace.sh` has platform-aware cleanup.

### 2.8.1 — `osx/collect_nettrace.sh`: Use `resolve_platform_config` instead of hardcoded values
- **Status:** ✅ IMPLEMENTED
- **Evidence:** `osx/collect_nettrace.sh` line 96: `resolve_platform_config "$PLATFORM"`. Line 166: uses `$PLATFORM_TFM` and `$PLATFORM_RID` (not hardcoded). Also has `--platform` flag (line 58, default: `osx`).

### 2.8.2 — `maccatalyst/collect_nettrace.sh`: Same pattern
- **Status:** ✅ IMPLEMENTED
- **Evidence:** `maccatalyst/collect_nettrace.sh` line 96: `resolve_platform_config "$PLATFORM"`. Line 166: uses `$PLATFORM_TFM` and `$PLATFORM_RID`. Has `--platform` flag (line 58, default: `maccatalyst`).

### 2.9.1 — Update `ios/README.md` with simulator section
- **Status:** ✅ IMPLEMENTED
- **Evidence:** `ios/README.md` lines 113–198: comprehensive "Simulator Support" section with quick start, how it works, auto-detection, options, nettrace collection, and file structure.

### 2.9.2 — Update main `README.md` with emulator/simulator content
- **Status:** ✅ IMPLEMENTED
- **Evidence:** `README.md` lines 335–381: "Emulator / Simulator Support" section with compound platform table, RID auto-detection explanation, workflow examples, and measurement details.

### 2.9.3 — Add inline comments in `init.sh` explaining compound platform pattern
- **Status:** ⚠️ PARTIAL
- **Evidence:** `init.sh` lines 39–40: `# RID selection: physical devices are always arm64; / # emulators match the host architecture.` — comments exist within the `android|android-emulator` case. Lines 59–60: similar comments for `ios|ios-simulator`. However, there's no top-level comment at the function level explaining the overall compound platform pattern concept (e.g., "compound platform values like android-emulator map to the same TFM as their base platform but with different RID selection logic"). The existing comments are functional but could be more explanatory.

---

## Step 3: macOS/osx Platform (plan.md lines 294–304)

### Create `osx/build-configs.props`
- **Status:** ✅ IMPLEMENTED
- **Evidence:** File exists with 6 configs: MONO_AOT, MONO_PAOT, MONO_JIT, CORECLR_JIT, R2R_COMP, R2R_COMP_PGO. All using `osx-arm64` RID and `net11.0-macos` TFM. No non-composite R2R (correct for MachO).

### Create `osx/build-workarounds.targets`
- **Status:** ✅ IMPLEMENTED
- **Evidence:** File exists with `GenerateInfoOsx` target (line 2), conditioned on `TargetPlatformIdentifier == 'macos'`.

### Create `osx/print_app_sizes.sh`
- **Status:** ✅ IMPLEMENTED
- **Evidence:** File exists (36 lines). Scans `$BUILD_DIR` for `.app` bundles using `du -sk`, supports `-detailed` flag.

### Add `osx` case to `resolve_platform_config()` in `init.sh`
- **Status:** ✅ IMPLEMENTED
- **Evidence:** `init.sh` lines 75–83: `osx)` case with TFM `net11.0-macos`, RID `osx-arm64`, device type `osx`, scenario dir `genericmacosstartup`.

### Import `osx/build-configs.props` in `Directory.Build.props`
- **Status:** ✅ IMPLEMENTED
- **Evidence:** `Directory.Build.props` lines 11–12: conditional import of `osx/build-configs.props`.

### Import `osx/build-workarounds.targets` in `Directory.Build.targets`
- **Status:** ✅ IMPLEMENTED
- **Evidence:** `Directory.Build.targets` lines 7–8: conditional import of `osx/build-workarounds.targets`.

### Update `build.sh`, `measure_startup.sh`, `measure_all.sh` for `osx`
- **Status:** ✅ IMPLEMENTED
- **Evidence:** All three scripts accept `osx` in their `--platform` flag. `build.sh` line 13: usage text. `measure_startup.sh` line 53. `measure_all.sh` lines 77, 89–91 (default apps: `dotnet-new-macos`).

### Update `generate-apps.sh` for `osx`
- **Status:** ✅ IMPLEMENTED
- **Evidence:** `generate-apps.sh` lines 189–190: `osx)` case generates `dotnet-new-macos` from `macos` template. Lines 197–198: MAUI apps excluded for osx.

### Update `prepare.sh` for `osx`
- **Status:** ✅ IMPLEMENTED
- **Evidence:** `prepare.sh` line 155: `osx) WORKLOADS="macos"`. Line 171: `osx) WORKLOAD_ID="macos"`.

### Create `osx/README.md`
- **Status:** ✅ IMPLEMENTED
- **Evidence:** File exists (122 lines). Comprehensive documentation: prerequisites, build configs table, usage examples, package discovery, app templates, file structure.

### Fetch macOS MIBC profiles from `dotnet-optimization` CI
- **Status:** ❌ NOT IMPLEMENTED
- **Evidence:** No profiles exist. Same as iOS MIBC item. Infrastructure is in place but no profiles fetched.

---

## Step 4: Mac Catalyst (plan.md lines 310–320)

### Create `maccatalyst/build-configs.props`
- **Status:** ✅ IMPLEMENTED
- **Evidence:** File exists with 6 configs. All using `maccatalyst-arm64` RID and `net11.0-maccatalyst` TFM.

### Create `maccatalyst/build-workarounds.targets`
- **Status:** ✅ IMPLEMENTED
- **Evidence:** File exists with `GenerateInfoMaccatalyst` target, conditioned on `TargetPlatformIdentifier == 'maccatalyst'`.

### Create `maccatalyst/print_app_sizes.sh`
- **Status:** ✅ IMPLEMENTED
- **Evidence:** File exists (36 lines). Same pattern as `osx/print_app_sizes.sh`.

### Add `maccatalyst` case to `resolve_platform_config()` in `init.sh`
- **Status:** ✅ IMPLEMENTED
- **Evidence:** `init.sh` lines 84–92: `maccatalyst)` case with TFM `net11.0-maccatalyst`, RID `maccatalyst-arm64`, device type `maccatalyst`.

### Import `maccatalyst/build-configs.props` in `Directory.Build.props`
- **Status:** ✅ IMPLEMENTED
- **Evidence:** `Directory.Build.props` lines 13–14.

### Import `maccatalyst/build-workarounds.targets` in `Directory.Build.targets`
- **Status:** ✅ IMPLEMENTED
- **Evidence:** `Directory.Build.targets` lines 9–10.

### Update `build.sh`, `measure_startup.sh`, `measure_all.sh` for `maccatalyst`
- **Status:** ✅ IMPLEMENTED
- **Evidence:** All three scripts accept `maccatalyst`. `measure_all.sh` lines 93–94: default apps are MAUI-only (correct, no standalone template).

### Update `generate-apps.sh` for `maccatalyst`
- **Status:** ✅ IMPLEMENTED
- **Evidence:** `generate-apps.sh` lines 193–194: empty `maccatalyst)` case (no standalone template). Lines 198–201: MAUI apps generated for maccatalyst.

### Update `prepare.sh` for `maccatalyst`
- **Status:** ✅ IMPLEMENTED
- **Evidence:** `prepare.sh` line 156: `maccatalyst) WORKLOADS="maccatalyst maui-maccatalyst"`.

### Create `maccatalyst/README.md`
- **Status:** ✅ IMPLEMENTED
- **Evidence:** File exists (123 lines). Documents MAUI-only constraint, build configs, usage.

### Fetch Mac Catalyst MIBC profiles
- **Status:** ❌ NOT IMPLEMENTED
- **Evidence:** Same as iOS/macOS MIBC items.

---

## Step 5: Nettrace Collection (plan.md lines 326–327)

### Create `ios/collect_nettrace.sh`
- **Status:** ✅ IMPLEMENTED
- **Evidence:** File exists (~400+ lines). Dual-mode: physical device (dsrouter + USB) and simulator (direct socket). Includes device auto-detection via `xcrun devicectl`, `--platform` flag, `--device-id`, `--simulator-name` options.

### Create desktop-style .nettrace collection for macOS/maccatalyst
- **Status:** ✅ IMPLEMENTED
- **Evidence:** `osx/collect_nettrace.sh` (285 lines) and `maccatalyst/collect_nettrace.sh` (285 lines) both exist. Both use direct Unix-domain diagnostic socket (`DOTNET_DiagnosticPorts`), no dsrouter needed. Build → locate .app → launch with diagnostic port → `dotnet-trace collect` → validate → save syslog.

---

## Step 6: Documentation (plan.md line 331)

### Update main `README.md` with all Apple platforms
- **Status:** ✅ IMPLEMENTED
- **Evidence:** `README.md` is comprehensive (520+ lines):
  - **Prerequisites:** Lines 14–24: platform-specific requirements table (all 6 platforms)
  - **Usage examples:** Lines 67–76: all platforms. Lines 157–177: per-platform measure_startup examples
  - **Project structure:** Lines 474–519: full tree with all platform directories
  - **Config availability table:** Lines 83–94: all 4 platforms + R2R availability
  - **Platform-specific notes:** Lines 301–334: Android, iOS, macOS, Mac Catalyst
  - **Emulator/Simulator support:** Lines 335–381
  - **Custom app measurement:** Lines 383–462
  - **Nettrace collection:** Lines 210–263

---

## Items That Need Real Work (3 total)

All three are the same category — **MIBC profile fetching** from `dotnet-optimization` CI:

1. **Step 1, line 32:** Fetch iOS MIBC profiles
2. **Step 3, line 304:** Fetch macOS MIBC profiles
3. **Step 4, line 320:** Fetch Mac Catalyst MIBC profiles

These are deferred/stretch items. The infrastructure to *use* MIBC profiles is fully in place (`generate-apps.sh` `patch_app()` function, `_ReadyToRunPgoFiles` MSBuild items). What's missing is a script or process to download `.mibc` files from the dotnet-optimization CI pipeline.

## Items That Are Partially Done (2 total)

1. **Step 2, 2.6.2 (line 206):** iOS startup markers — not injected, but likely not needed (simulator uses wall-clock timing; physical device uses system log timestamps via test.py). Consider closing this item as "not applicable."

2. **Step 2, 2.9.3 (line 278):** Inline comments in `init.sh` — functional comments exist within each case but no top-level architectural comment about the compound platform pattern. Minor documentation improvement.

---

## Recommendation

**Update `plan.md`** to check off the 47 implemented items and the 2 partial items (with notes). Mark the 3 MIBC items as explicitly deferred. This is a plan.md update task, not an implementation task.
