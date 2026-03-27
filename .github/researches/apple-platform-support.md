# Apple Platform Support — Comprehensive Research

## Architecture Overview

This repository measures .NET mobile app startup performance by:
1. Installing a .NET SDK + platform workloads (`prepare.sh`)
2. Generating sample apps via `dotnet new` templates (`generate-apps.sh`)
3. Building apps with various runtime configurations (`build.sh`)
4. Measuring startup times using `dotnet/performance`'s `test.py devicestartup` harness (`measure_startup.sh`)
5. Aggregating results into CSV summaries (`measure_all.sh`)

Android is the reference implementation. iOS, macOS (osx), and Mac Catalyst need to be added following the same patterns.

---

## Key Files — Complete Analysis

### `init.sh` (lines 1–53)

Central configuration hub. Defines all shared path variables and `resolve_platform_config()`.

**Variables defined (lines 4–20):**
- `SCRIPT_DIR`, `BUILD_DIR`, `TOOLS_DIR`, `DOTNET_DIR`, `LOCAL_DOTNET`, `LOCAL_PACKAGES`
- `APPS_DIR`, `VERSIONS_LOG`, `NUGET_CONFIG`, `GLOBAL_JSON`
- `PERF_DIR` → `external/performance`
- `SCENARIOS_DIR` → `$PERF_DIR/src/scenarios`
- `TRACES_DIR`, `RESULTS_DIR`
- `ANDROID_DIR`, `IOS_DIR`

**`resolve_platform_config()` (lines 26–53):**

Sets 7 platform-specific variables per platform:

| Variable | Android | iOS (partial) |
|----------|---------|---------------|
| `PLATFORM_TFM` | `net11.0-android` | `net11.0-ios` |
| `PLATFORM_RID` | `android-arm64` | `ios-arm64` |
| `PLATFORM_DEVICE_TYPE` | `android` | `ios` |
| `PLATFORM_SCENARIO_DIR` | `genericandroidstartup` | `genericiosstartup` |
| `PLATFORM_PACKAGE_GLOB` | `*-Signed.apk` | `*.app` |
| `PLATFORM_PACKAGE_LABEL` | `APK` | `APP` |
| `PLATFORM_DIR` | `$ANDROID_DIR` | `$IOS_DIR` |

**Gaps for Apple platforms:**
- No `osx` or `maccatalyst` cases exist
- No `OSX_DIR` or `MACCATALYST_DIR` variables defined
- Error message at line 49 only lists `android, ios`

**Values needed for new platforms:**

| Variable | macOS (osx) | Mac Catalyst |
|----------|-------------|--------------|
| `PLATFORM_TFM` | `net11.0-macos` | `net11.0-maccatalyst` |
| `PLATFORM_RID` | `osx-arm64` | `maccatalyst-arm64` |
| `PLATFORM_DEVICE_TYPE` | TBD (see Risks) | TBD (see Risks) |
| `PLATFORM_SCENARIO_DIR` | TBD (see dotnet/performance) | TBD |
| `PLATFORM_PACKAGE_GLOB` | `*.app` | `*.app` |
| `PLATFORM_PACKAGE_LABEL` | `APP` | `APP` |
| `PLATFORM_DIR` | `$OSX_DIR` | `$MACCATALYST_DIR` |

---

### `android/build-configs.props` (lines 1–76)

MSBuild property file with 7 `_BuildConfig`-keyed PropertyGroups. This is the core pattern to replicate.

**Config matrix:**

| Config | UseMonoRuntime | RunAOTCompilation | AndroidEnableProfiledAot | PublishReadyToRun | PublishReadyToRunComposite | PGO | Other |
|--------|---------------|-------------------|-------------------------|-------------------|---------------------------|-----|-------|
| MONO_AOT | True | True | False | — | — | — | — |
| MONO_PAOT | True | True | (default=True) | — | — | — | — |
| MONO_JIT | True | False | — | False | False | — | — |
| CORECLR_JIT | False | False | — | False | False | — | — |
| R2R | False | — | — | True | False | — | `_IsPublishing=True`, `_MauiPublishReadyToRunPartial=false`, `AndroidEnableMarshalMethods=False` |
| R2R_COMP | False | — | — | True | True | — | Same as R2R |
| R2R_COMP_PGO | False | — | — | True | True | True | `AndroidEnableMarshalMethods=False` |

**All configs share:** `Configuration=Release`, `AndroidPackageFormat=apk`, `RuntimeIdentifier=android-arm64`, `TargetFramework=net11.0-android`

**Key observations:**
- `AndroidPackageFormat=apk` is Android-specific — Apple platforms don't need this
- `AndroidEnableProfiledAot` is the Android-specific property for profiled AOT
- `AndroidEnableMarshalMethods=False` is set on R2R configs — Android-specific workaround
- `_IsPublishing=True` is set on R2R configs — required to trigger R2R pipeline during `dotnet build` (not just `dotnet publish`)
- `_MauiPublishReadyToRunPartial=false` prevents MAUI from adding `--partial` flag automatically

**Apple platform equivalents:**
- `AndroidEnableProfiledAot` → `MtouchProfiledAOT` for iOS/maccatalyst/macOS
- `RunAOTCompilation` → same property name works across all platforms
- `AndroidPackageFormat` → not needed (Apple platforms always produce `.app` bundles)
- `AndroidEnableMarshalMethods` → no Apple equivalent
- `_IsPublishing=True` → likely still needed for R2R during `dotnet build`

---

### `android/build-workarounds.targets` (lines 1–20)

Two Android-specific build workarounds:

1. **`GenerateInfo` target (line 2–4):** Emits build metadata after Build. Uses `$(_AndroidPackage)`, `$(AndroidPackageFormat)` — Android-specific properties.

2. **`_PreventRunningRemoveRegisterAttribute` workaround (lines 5–19):** Temporarily changes `AndroidStripILAfterAOT` to prevent `_RemoveRegisterAttribute` from running during R2R builds. This is an **Android-only** workaround — Apple platforms don't have `_RemoveRegisterAttribute`.

**For Apple platforms:**
- Need a `GenerateInfo<Platform>` target with platform-conditional output
- The `_RemoveRegisterAttribute` workaround is NOT needed
- Need to determine what `.app` bundle path format to emit

---

### `generate-apps.sh` (lines 1–159)

Generates sample apps and applies post-generation patches.

**App generation (lines 153–158):**
```
generate_app "android" "dotnet-new-android"
generate_app "maui" "dotnet-new-maui"
generate_app "maui" "dotnet-new-maui-samplecontent" "--sample-content"
```

**`generate_app()` function (lines 15–77):**
- Creates app via `dotnet new <template>`
- For MAUI apps, restricts `TargetFrameworks` to Android-only (line 52–71) — **this needs to change** for Apple platforms
- Calls `patch_app()` for profiling/PGO support

**`patch_app()` function (lines 79–149):**
- Copies `profiles/*.mibc` files into app's `profiles/` dir
- Injects `<AndroidEnvironment>` items for profiling and nettrace collection (lines 109–116) — **Android-specific**
- Adds PGO profile support for R2R Composite builds
- Differentiates between MAUI and non-MAUI apps for PGO profile handling

**Changes needed for Apple platforms:**
1. Add platform-specific template generation:
   - `dotnet new ios` → `dotnet-new-ios`
   - `dotnet new macos` → `dotnet-new-macos`
   - No standalone template for Mac Catalyst — MAUI-only
2. MAUI TFM restriction needs to be platform-aware (line 58–70)
3. `<AndroidEnvironment>` profiling patches are Android-only — Apple platforms use different mechanisms for environment variables
4. For iOS: environment variables go via `MtouchExtraArgs` with `--setenv=` or through Info.plist
5. PGO profile patches (lines 123–142) are generic and should work across platforms

---

### `prepare.sh` (lines 1–198)

Environment setup script.

**Platform-specific sections:**
- **Workload installation (lines 129–133):** `android maui-android` for Android, `ios maui-ios` for iOS
- **NuGet.config download (line 111):** Currently from `dotnet/android` repo — may need different source for Apple platforms (or a unified one)

**Changes needed:**
- Add `osx`/`maccatalyst` to platform validation (line 37–43)
- Add workload cases: `macos maui-macos` for osx, `maccatalyst maui-maccatalyst` for maccatalyst
- The rest of the script (SDK install, xharness, dsrouter, dotnet-trace, submodule init) is platform-agnostic

---

### `build.sh` (lines 1–101)

Build/run orchestration script.

**Platform handling:**
- Parses `--platform` flag (lines 8–27)
- Calls `resolve_platform_config()` (line 30)
- Uses `$PLATFORM_TFM` and `$PLATFORM_RID` in build command (line 95)
- Build command: `dotnet build -c Release -f $PLATFORM_TFM -r $PLATFORM_RID -bl:$logfile $csproj -p:_BuildConfig=$BUILD_CONFIG`

**No platform-specific logic needed** — the script is already fully abstracted through `resolve_platform_config()`. The only change needed is updating the usage text (line 40) and valid platform list.

---

### `measure_startup.sh` (lines 1–171)

Startup measurement orchestration.

**Key flow:**
1. Build the app (line 98–101)
2. Find the built package (line 109)
3. Get package size (line 116)
4. Run `test.py devicestartup` with `--device-type`, `--package-path`, `--package-name` (lines 146–150)

**Platform-specific concerns:**

1. **Package discovery (line 109):** Uses `PLATFORM_PACKAGE_GLOB` — for `.app` bundles (directories), `find -name "*.app"` finds the directory. This should work.

2. **Package size (line 116):** Uses `stat -f%z` (macOS) or `stat -c%s` (Linux). For `.app` bundles (directories), `stat` on a directory won't give meaningful size. **Must use `du -sk` for .app bundles.**

3. **Package name (lines 86–89):** Extracts `<ApplicationId>` from csproj. iOS/macOS apps use `<ApplicationId>` too in .NET MAUI. For standalone iOS apps, it's typically set via the template. Fallback pattern `com.companyname.$(echo "$SAMPLE_APP" | tr '-' '_')` should work.

4. **test.py invocation (lines 146–150):** Uses `--device-type` which maps to dotnet/performance's device type enum. Need to verify what values are supported (see dotnet/performance section).

---

### `measure_all.sh` (lines 1–182)

Batch measurement runner.

**Platform-specific sections:**
- `ALL_CONFIGS` (line 5): All 7 configs — Apple platforms should exclude `R2R` (non-composite)
- Default app list per platform (lines 72–79): Only `android` and `ios` (empty) cases exist
- Output format uses `PLATFORM_PACKAGE_LABEL` for column header (line 174)

**Changes needed:**
- Add `osx`/`maccatalyst` cases with default app lists
- Consider platform-specific config lists (6 configs for Apple, 7 for Android)

---

### `Directory.Build.props` (lines 1–9)

Currently imports only `android/build-configs.props` (line 7–8).

**Pattern:** Conditional import using `Condition="Exists(...)"`.

**Need to add:** Imports for `ios/build-configs.props`, `osx/build-configs.props`, `maccatalyst/build-configs.props`.

---

### `Directory.Build.targets` (lines 1–5)

Currently imports only `android/build-workarounds.targets` (line 3–4).

**Need to add:** Imports for Apple platform workaround targets.

---

### `global.json` (line 2)

SDK version: `11.0.100-preview.3.26123.103`. All platforms use the same SDK.

---

### `rollback.json` (lines 1–10)

Already includes rollback entries for `ios`, `maccatalyst`, `macos`, and `tvos` workloads. This confirms the Apple SDK workloads are available for version pinning.

---

### `android/env.txt` and `android/env-nettrace.txt`

Android environment variable files included via `<AndroidEnvironment>` MSBuild items.

- `env.txt`: `DOTNET_DiagnosticPorts=127.0.0.1:9000,suspend,connect` — for diagnostics bridge
- `env-nettrace.txt`: PGO instrumentation env vars

**Apple platform equivalent:**
- iOS: Environment variables via `MtouchExtraArgs` with `--setenv=VAR=VALUE` in the csproj, or via `__XPC_` prefixed vars for macOS
- macOS/maccatalyst: Can set env vars directly when launching the process

---

### `android/collect_nettrace.sh` (lines 1–275)

Android-specific nettrace collection using ADB + dsrouter bridge.

**Flow:** Start dsrouter → Clear logcat → Build/deploy with diagnostics → dotnet-trace collect → Save trace + logcat

**Apple platform differences:**
- **iOS:** Uses `xcrun devicectl` instead of `adb` for device interaction. dsrouter still used but with iOS-specific transport. No logcat (use `log collect` for unified logs).
- **macOS/maccatalyst:** No device bridge needed — direct process launch. Can use `dotnet-trace` directly against the process ID. Much simpler flow.

---

### `android/print_apk_sizes.sh` (lines 1–41)

Scans `$BUILD_DIR` for `*-Signed.apk` files and reports sizes. Optional `-unzipped` flag using `apktool`.

**Apple equivalent:**
- Scan for `*.app` directories
- Use `du -sk` for directory size
- Optional: list contents with `ls -la` or `find` for detailed breakdown
- No `apktool` equivalent needed — `.app` bundles are just directories

---

## dotnet/performance Submodule

The submodule is at `external/performance` (git URL: `https://github.com/dotnet/performance.git`) but is not initialized in the current worktree.

### Scenario Directories Referenced

Based on `init.sh`:
- Android: `src/scenarios/genericandroidstartup/`
- iOS: `src/scenarios/genericiosstartup/`

These directories contain a `test.py` file that implements the `devicestartup` command used by `measure_startup.sh`.

### `test.py devicestartup` Interface

From `measure_startup.sh` lines 146–150:
```bash
python3 test.py devicestartup \
    --device-type "$PLATFORM_DEVICE_TYPE" \
    --package-path "$PACKAGE_PATH" \
    --package-name "$PACKAGE_NAME" \
    "$@"
```

**Known parameters:**
- `--device-type` — Device type enum (e.g., `android`, `ios`)
- `--package-path` — Path to the built package (APK file or .app bundle)
- `--package-name` — Application bundle ID
- Additional passthrough args from `measure_startup.sh`: `--startup-iterations`, `--disable-animations`, `--use-fully-drawn-time`, `--fully-drawn-extra-delay`, `--trace-perfetto`

### UNKNOWN: macOS/maccatalyst Scenario Directories

The dotnet/performance repo likely has:
- `genericiosstartup/` — for iOS device measurement
- Possibly `genericmacosstartup/` or similar for macOS

**This needs verification** once the submodule is initialized. If no macOS/maccatalyst scenario exists in dotnet/performance, we may need to:
1. Create a local scenario wrapper
2. Measure startup differently (e.g., `time` command, or custom timing harness)

### UNKNOWN: Device Types for macOS/maccatalyst

The `--device-type` values accepted by `test.py` need verification. Expected:
- `android` — confirmed
- `ios` — configured in `init.sh`
- `macos` / `osx` / `maccatalyst` — **unknown, needs investigation**

---

## Build Configuration Presets per Platform

### Android (7 configs) — Reference

| Config | Available | Notes |
|--------|-----------|-------|
| MONO_JIT | ✅ | |
| MONO_AOT | ✅ | |
| MONO_PAOT | ✅ | Uses `AndroidEnableProfiledAot` |
| CORECLR_JIT | ✅ | |
| R2R | ✅ | Non-composite, CoreCLR |
| R2R_COMP | ✅ | Composite, CoreCLR |
| R2R_COMP_PGO | ✅ | Composite + PGO profiles |

### iOS (6 configs)

| Config | Available | Notes |
|--------|-----------|-------|
| MONO_JIT | ✅ | |
| MONO_AOT | ✅ | `RunAOTCompilation=True`, `MtouchProfiledAOT=False` |
| MONO_PAOT | ✅ | `RunAOTCompilation=True`, `MtouchProfiledAOT=True` (default) |
| CORECLR_JIT | ✅ | |
| R2R | ❌ | **MachO only supports composite R2R** |
| R2R_COMP | ✅ | Must use composite |
| R2R_COMP_PGO | ✅ | Composite + PGO profiles |

### macOS/osx (6 configs)

| Config | Available | Notes |
|--------|-----------|-------|
| MONO_JIT | ✅ | |
| MONO_AOT | ✅ | |
| MONO_PAOT | ✅ | |
| CORECLR_JIT | ✅ | |
| R2R | ❌ | **MachO only supports composite R2R** |
| R2R_COMP | ✅ | |
| R2R_COMP_PGO | ✅ | |

### Mac Catalyst (6 configs)

Same as iOS — MachO format, composite-only R2R.

---

## Apple Platform MSBuild Properties

### iOS (`net11.0-ios`, `ios-arm64`)

```xml
<PropertyGroup>
  <Configuration>Release</Configuration>
  <RuntimeIdentifier>ios-arm64</RuntimeIdentifier>
  <TargetFramework>net11.0-ios</TargetFramework>
</PropertyGroup>
```

**Runtime-specific properties:**
- `UseMonoRuntime=True/False` — same as Android
- `RunAOTCompilation=True/False` — same as Android
- `MtouchProfiledAOT=True/False` — iOS equivalent of `AndroidEnableProfiledAot`
- `PublishReadyToRun=True/False` — same as Android
- `PublishReadyToRunComposite=True/False` — same as Android, **must be True** (no non-composite)
- `_IsPublishing=True` — likely needed for R2R during `dotnet build`

### macOS (`net11.0-macos`, `osx-arm64`)

```xml
<PropertyGroup>
  <Configuration>Release</Configuration>
  <RuntimeIdentifier>osx-arm64</RuntimeIdentifier>
  <TargetFramework>net11.0-macos</TargetFramework>
</PropertyGroup>
```

Same runtime properties as iOS.

### Mac Catalyst (`net11.0-maccatalyst`, `maccatalyst-arm64`)

```xml
<PropertyGroup>
  <Configuration>Release</Configuration>
  <RuntimeIdentifier>maccatalyst-arm64</RuntimeIdentifier>
  <TargetFramework>net11.0-maccatalyst</TargetFramework>
</PropertyGroup>
```

Same runtime properties as iOS.

---

## Workloads

| Platform | Workloads to Install |
|----------|---------------------|
| Android | `android maui-android` |
| iOS | `ios maui-ios` |
| macOS | `macos maui-macos` |
| Mac Catalyst | `maccatalyst maui-maccatalyst` |

All are present in `rollback.json` (lines 3–6), confirming they're available.

---

## App Generation — Templates

| Template | Command | Produces | Platforms |
|----------|---------|----------|-----------|
| `android` | `dotnet new android` | Android app | Android only |
| `ios` | `dotnet new ios` | iOS app | iOS only |
| `macos` | `dotnet new macos` | macOS app | macOS only |
| `maui` | `dotnet new maui` | Cross-platform MAUI | All (via TFM) |
| — | No standalone template | Mac Catalyst | MAUI only |

**Mac Catalyst constraint:** There is no `dotnet new maccatalyst` template. Mac Catalyst apps are only buildable through MAUI, by including `net11.0-maccatalyst` in the MAUI app's `<TargetFrameworks>`.

---

## Package Size Measurement

| Platform | Package Format | Size Method | Notes |
|----------|---------------|-------------|-------|
| Android | `*-Signed.apk` (file) | `stat -f%z` / `stat -c%s` | Single file |
| iOS | `*.app` (directory) | `du -sk` | Bundle directory |
| macOS | `*.app` (directory) | `du -sk` | Bundle directory |
| Mac Catalyst | `*.app` (directory) | `du -sk` | Bundle directory |

**Current `measure_startup.sh` issue (line 116):** Uses `stat` which doesn't work for directories. For Apple platforms, must detect whether the package path is a directory and use `du -sk` instead.

---

## Startup Measurement — Platform Differences

### Android (current)
- xharness deploys APK via ADB, launches app, measures startup time via logcat parsing
- `--device-type android`

### iOS
- xharness deploys .app to device via `xcrun devicectl`
- `--device-type ios`
- Requires physical device or simulator
- dotnet/performance has `genericiosstartup` scenario directory

### macOS
- App can be launched directly on host (`open MyApp.app` or direct binary execution)
- No device deployment needed
- **Unknown:** Whether dotnet/performance has a macOS startup scenario
- May need custom measurement approach

### Mac Catalyst
- Similar to macOS — runs directly on host machine
- Mac Catalyst apps are macOS apps with iOS APIs
- Same deployment model as macOS (direct launch)
- **Unknown:** Whether dotnet/performance differentiates maccatalyst from macos

---

## Profiling / Diagnostics — Platform Differences

### Android (current, `android/collect_nettrace.sh`)
- `<AndroidEnvironment>` items inject env vars into the app
- `dsrouter server-server` with `--forward-port Android` bridges diagnostics
- `adb` used for device communication

### iOS
- No `<AndroidEnvironment>` — use `MtouchExtraArgs` with `--setenv=VAR=VALUE` or similar
- `dsrouter` with iOS transport (likely `--forward-port iOS` or similar)
- `xcrun devicectl` for device communication
- `log collect` instead of `adb logcat` for system logs

### macOS / Mac Catalyst
- Environment variables set directly before launching the app
- No dsrouter needed — direct diagnostics port
- `dotnet-trace` can attach directly to the process
- Much simpler flow than device-based platforms

---

## Risks and Gotchas

### Critical

1. **MachO R2R Composite-Only:** All Apple platforms (iOS, macOS, maccatalyst) only support Composite ReadyToRun images. Non-composite R2R (`R2R` config) will fail with crossgen2. The `R2R` config must be excluded from Apple platform config lists.

2. **Package size for .app bundles:** `measure_startup.sh` line 116 uses `stat` which gives the directory entry size (~64 bytes), not the total bundle size. Must be fixed to use `du -sk` for directories.

3. **MAUI TFM restriction in `generate-apps.sh`:** Lines 52–71 hardcode `net11.0-android` as the sole TFM. This prevents building MAUI apps for any other platform. Must be made platform-aware.

### High

4. **dotnet/performance scenario directories:** The macOS/maccatalyst scenarios in `dotnet/performance` are unverified. If `genericmacosstartup` doesn't exist, a custom measurement approach is needed.

5. **`--device-type` values:** The accepted device type values for `test.py` are unknown for macOS/maccatalyst. Need to check dotnet/performance source.

6. **Mac Catalyst has no standalone template:** Only MAUI apps can target maccatalyst. The default app list for maccatalyst can only include MAUI apps (no `dotnet-new-maccatalyst`).

### Medium

7. **NuGet.config source:** Currently downloads from `dotnet/android` repo (line 111 of `prepare.sh`). This may not include all Apple platform package sources. Should verify or use a more comprehensive NuGet.config.

8. **Profiling patches are Android-specific:** `generate-apps.sh` injects `<AndroidEnvironment>` items. Apple platforms need different mechanisms for setting runtime environment variables.

9. **`build-workarounds.targets` naming collision:** The Android `GenerateInfo` target (line 2 of `build-workarounds.targets`) has no platform condition. If all platform targets are imported, they'll conflict. Each platform's target needs a unique name and/or platform condition.

10. **MIBC profiles for Apple platforms:** The `dotnet-optimization` pipeline's Apple artifact names are unknown. May need to collect profiles locally initially.

---

## Existing Apple Platform Work

### Already Done
- `ios/` directory exists with placeholder `README.md` (lines 1–9)
- `init.sh` has partial `ios` case in `resolve_platform_config()` (lines 39–47)
- `prepare.sh` has `ios` workload installation case (lines 129–133)
- `rollback.json` includes all Apple workload entries
- `plan.md` has complete 5-step plan for all Apple platforms
- `.github/researches/mibc-profiles.md` documents PGO profile sourcing

### Not Yet Done
- No `ios/build-configs.props` or `ios/build-workarounds.targets`
- No `osx/` or `maccatalyst/` directories
- `generate-apps.sh` only generates Android apps
- `measure_all.sh` has empty iOS app list (line 78: `APPS=()`)
- No macOS or maccatalyst scenarios in any script
- Profiling/diagnostics patches are Android-only
- Package size measurement doesn't handle directories

---

## Recommended Approach

### Phase 1: iOS (highest priority)
1. Create `ios/build-configs.props` with 6 configs (no `R2R`)
2. Create `ios/build-workarounds.targets` with platform-conditioned `GenerateInfoIos` target
3. Update `Directory.Build.props` and `Directory.Build.targets` to import iOS files
4. Rename Android's `GenerateInfo` → `GenerateInfoAndroid` with platform condition
5. Update `generate-apps.sh`:
   - Add `dotnet new ios` template generation
   - Make MAUI TFM restriction platform-aware
   - Make profiling patches platform-aware (skip `<AndroidEnvironment>` for non-Android)
6. Update `prepare.sh` with `ios` workload case (already partially done)
7. Fix `measure_startup.sh` package size for directories
8. Update `measure_all.sh` with iOS app list and config list
9. Create `ios/print_app_sizes.sh`

### Phase 2: macOS (osx)
1. Create `osx/` directory with `build-configs.props` and `build-workarounds.targets`
2. Add `osx` case to `init.sh`, `prepare.sh`
3. Add `dotnet new macos` to `generate-apps.sh`
4. Investigate dotnet/performance for macOS startup scenario

### Phase 3: Mac Catalyst
1. Create `maccatalyst/` directory with configs
2. MAUI-only app support (no standalone template)
3. Similar to macOS for deployment/measurement

### Phase 4: Apple .nettrace Collection
1. iOS: `ios/collect_nettrace.sh` using xcrun devicectl + dsrouter
2. macOS/maccatalyst: Simpler direct-process collection

---

## Unknowns Requiring Further Investigation

1. **dotnet/performance `genericiosstartup/test.py`** — What `--device-type` values does it accept? Does it support macOS/maccatalyst? (Requires submodule initialization)
2. **macOS startup measurement** — Does dotnet/performance have a macOS-specific scenario, or do we need a custom solution?
3. **iOS profiled AOT property name** — Is it `MtouchProfiledAOT` or something else in .NET 11?
4. **NuGet.config compatibility** — Does the `dotnet/android` NuGet.config include Apple package sources?
5. **R2R `_IsPublishing=True`** — Is this still needed on Apple platforms to trigger R2R during `dotnet build`?
6. **MAUI workload names** — Is `maui-macos` the correct workload name for macOS MAUI?
7. **Apple platform `.app` bundle location** — Where exactly does `dotnet build` put the `.app` bundle in the output? (e.g., `bin/Release/net11.0-ios/ios-arm64/MyApp.app`)
