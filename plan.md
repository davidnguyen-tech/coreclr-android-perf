# Implementation Plan — Apple Platform Measurement Support

## Overview

Add complete CoreCLR performance measurement support for three Apple platforms: **iOS**, **macOS (osx)**, and **Mac Catalyst (maccatalyst)**. Each platform follows the established Android pattern: a dedicated platform directory with build configs, workarounds, and tooling; updates to shared scripts for platform resolution; app generation; workload installation; and measurement orchestration.

### Key Constraints

- **MachO format**: All Apple platforms only support **Composite ReadyToRun** images. Non-composite R2R (`R2R` config) is not available — only `R2R_COMP` and `R2R_COMP_PGO`.
- **Package format**: All Apple platforms produce `.app` bundles (directories), not single files. Size calculation uses `du -sk`, not `stat`.
- **iOS device deployment**: Requires xharness for install, `xcrun devicectl` for launch. The dotnet/performance `runner.py` calls `sudo log collect --device` which needs passwordless sudoers.
- **macOS / Mac Catalyst**: Apps run directly on the host — no device deployment needed. Startup can be measured by timing direct execution.
- **Mono AOT on Apple**: iOS requires AOT for App Store distribution (JIT is restricted); Mac Catalyst and macOS allow JIT.

### Existing Work

The `feature/ios-measurements` branch has partial iOS support that should be incorporated and extended:
- `ios/build-configs.props` — 6 configs (MONO_JIT, MONO_AOT, MONO_PAOT, CORECLR_JIT, R2R_COMP, R2R_COMP_PGO)
- `ios/build-workarounds.targets` — GenerateInfoIos target
- `ios/print_app_sizes.sh` — .app bundle size scanning
- `ios/README.md` — Prerequisites and usage docs
- Updates to `generate-apps.sh`, `measure_startup.sh`, `measure_all.sh`, `prepare.sh`, `Directory.Build.props/targets`

### Platform Matrix

| Platform | TFM | RID | Device Type | Package Glob | Template | Workloads |
|----------|-----|-----|-------------|-------------|----------|-----------|
| android | net11.0-android | android-arm64 | android | *-Signed.apk | `dotnet new android` | android, maui-android |
| ios | net11.0-ios | ios-arm64 | ios | *.app | `dotnet new ios` | ios, maui-ios |
| maccatalyst | net11.0-maccatalyst | maccatalyst-arm64 | maccatalyst | *.app | `dotnet new maui` (maccatalyst-only) | maccatalyst, maui-maccatalyst |
| osx | net11.0-macos | osx-arm64 | macos | *.app | `dotnet new macos` | macos, maui |

### Worktree & Branch Convention

| Step | Branch Name | Worktree Path |
|------|------------|---------------|
| 1 | `feature/ios-platform-support` | `.worktrees/ios-platform-support` |
| 2 | `feature/osx-platform-support` | `.worktrees/osx-platform-support` |
| 3 | `feature/maccatalyst-platform-support` | `.worktrees/maccatalyst-platform-support` |
| 4 | `feature/apple-nettrace-collection` | `.worktrees/apple-nettrace-collection` |
| 5 | `feature/apple-docs` | `.worktrees/apple-docs` |

---

## Step 1 — iOS Platform Support

**Branch:** `feature/ios-platform-support`
**Goal:** Complete iOS measurement support — build, deploy, measure startup, report sizes.
**Base:** Incorporate and refine the existing `feature/ios-measurements` branch work.

### Task 1.1 — iOS platform directory

**What:** Create `ios/` with build configs, workarounds, and size reporting.

**Files:**
- `ios/build-configs.props` — 6 PropertyGroups for: MONO_JIT, MONO_AOT, MONO_PAOT, CORECLR_JIT, R2R_COMP, R2R_COMP_PGO
  - No `R2R` (non-composite) — MachO doesn't support it
  - Use `MtouchProfiledAOT` for MONO_PAOT (not `AndroidEnableProfiledAot`)
  - All use `RuntimeIdentifier=ios-arm64`, `TargetFramework=net11.0-ios`
- `ios/build-workarounds.targets` — `GenerateInfoIos` target conditioned on `TargetPlatformIdentifier == 'ios'`
- `ios/print_app_sizes.sh` — Find `*.app` directories under `Release/`, report sizes via `du -sk`

**Acceptance criteria:**
- Files follow the same structure as `android/build-configs.props` and `android/build-workarounds.targets`
- `print_app_sizes.sh` is executable and handles empty results gracefully

### Task 1.2 — Update shared infrastructure for iOS

**What:** Wire iOS into the shared build/measurement scripts.

**Files to modify:**
- `init.sh` — Add `ios` case to `resolve_platform_config()`:
  ```
  PLATFORM_TFM="net11.0-ios"
  PLATFORM_RID="ios-arm64"
  PLATFORM_DEVICE_TYPE="ios"
  PLATFORM_SCENARIO_DIR="$SCENARIOS_DIR/genericiosstartup"
  PLATFORM_PACKAGE_GLOB="*.app"
  PLATFORM_PACKAGE_LABEL="APP"
  PLATFORM_DIR="$IOS_DIR"
  ```
- `Directory.Build.props` — Import `ios/build-configs.props`
- `Directory.Build.targets` — Import `ios/build-workarounds.targets`
- `android/build-workarounds.targets` — Rename `GenerateInfo` to `GenerateInfoAndroid` with platform condition
- `build.sh` — Update usage text and platform validation to include `ios`
- `measure_startup.sh`:
  - Handle `.app` directory bundles for package discovery (search `$APP_DIR/bin` first)
  - Use `du -sk` for directory bundles, `stat` for files
- `measure_all.sh`:
  - Add `ALL_CONFIGS_IOS` (6 configs, no non-composite R2R)
  - Add iOS default app list: `dotnet-new-ios`, `dotnet-new-maui`, `dotnet-new-maui-samplecontent`

**Acceptance criteria:**
- `./build.sh --platform ios dotnet-new-ios CORECLR_JIT build 1` resolves the correct TFM/RID
- `resolve_platform_config ios` sets all PLATFORM_* variables correctly
- `measure_all.sh --platform ios` uses the correct config and app lists

### Task 1.3 — iOS app generation

**What:** Update `generate-apps.sh` to generate iOS template apps and include iOS TFM in MAUI apps.

**Changes:**
- Add `--platform` flag handling: `ios` sets `GEN_IOS=true`
- Generate `dotnet-new-ios` via `generate_app "ios" "dotnet-new-ios"`
- Fix iOS template TFM (templates may default to an older TFM — sed-replace to `net11.0-ios`)
- Include `net11.0-ios` in MAUI app `TargetFrameworks` when iOS is selected
- Make profiling patches platform-aware (Android `env.txt`/`env-nettrace.txt` only for `TargetPlatformIdentifier == 'android'`)

**Acceptance criteria:**
- `./generate-apps.sh --platform ios` creates `apps/dotnet-new-ios/` and MAUI apps with iOS TFM
- MAUI csproj contains `net11.0-ios` in TargetFrameworks
- Android-specific profiling patches are conditioned on platform

### Task 1.4 — iOS workload installation

**What:** Update `prepare.sh` to install iOS workloads.

**Changes:**
- Add `ios` case to workload selection: `WORKLOADS="ios maui-ios"`
- Update platform validation to accept `ios`
- Log iOS workload manifest version

**Acceptance criteria:**
- `./prepare.sh --platform ios` installs the iOS and MAUI-iOS workloads

### Task 1.5 — iOS README

**What:** Create `ios/README.md` with prerequisites, sudoers setup, build configs table, and usage examples.

**Content:**
- Prerequisites: iPhone with developer mode, Xcode CLI tools, passwordless `log collect`
- Sudoers setup instructions for `log collect`
- Build configurations table (6 configs)
- Usage examples for build, measure, and size reporting
- List of generated iOS apps

**Acceptance criteria:**
- README is clear, complete, and consistent with the main README format

---

## Step 2 — macOS (osx) Platform Support

**Branch:** `feature/osx-platform-support`
**Goal:** Complete macOS measurement support. Desktop app runs directly on host.

### Task 2.1 — macOS platform directory

**What:** Create `osx/` with build configs, workarounds, and size reporting.

**Files:**
- `osx/build-configs.props` — Configs for macOS:
  - MONO_JIT, CORECLR_JIT, R2R_COMP, R2R_COMP_PGO
  - Mono AOT configs may not be applicable for macOS — research needed
  - `RuntimeIdentifier=osx-arm64`, `TargetFramework=net11.0-macos`
- `osx/build-workarounds.targets` — `GenerateInfoMacos` target
- `osx/print_app_sizes.sh` — .app bundle size scanning

### Task 2.2 — Update shared infrastructure for macOS

**What:** Wire macOS into shared scripts.

**Changes to `init.sh`:**
```
osx)
    PLATFORM_TFM="net11.0-macos"
    PLATFORM_RID="osx-arm64"
    PLATFORM_DEVICE_TYPE="macos"
    PLATFORM_SCENARIO_DIR="$SCENARIOS_DIR/genericmacosstartup"
    PLATFORM_PACKAGE_GLOB="*.app"
    PLATFORM_PACKAGE_LABEL="APP"
    PLATFORM_DIR="$OSX_DIR"
    ;;
```

### Task 2.3 — macOS app generation & workloads

**What:** Update `generate-apps.sh` and `prepare.sh`.

- Template: `dotnet new macos` → `dotnet-new-macos`
- Workloads: `macos`
- MAUI apps: include `net11.0-macos` in TargetFrameworks (if MAUI supports macOS target)

### Task 2.4 — macOS README

**Files:** `osx/README.md`

---

## Step 3 — Mac Catalyst Platform Support

**Branch:** `feature/maccatalyst-platform-support`
**Goal:** Complete Mac Catalyst measurement support. Runs on the host Mac — no device deployment.

### Task 3.1 — Mac Catalyst platform directory

**What:** Create `maccatalyst/` with build configs, workarounds, and size reporting.

**Files:**
- `maccatalyst/build-configs.props` — 6 configs (same set as iOS, no non-composite R2R)
  - `RuntimeIdentifier=maccatalyst-arm64`, `TargetFramework=net11.0-maccatalyst`
- `maccatalyst/build-workarounds.targets` — `GenerateInfoMacCatalyst` target
- `maccatalyst/print_app_sizes.sh` — .app bundle size scanning

**Acceptance criteria:**
- Files match the established pattern from Android and iOS

### Task 3.2 — Update shared infrastructure for Mac Catalyst

**What:** Wire Mac Catalyst into shared scripts.

**Changes to `init.sh`:**
```
maccatalyst)
    PLATFORM_TFM="net11.0-maccatalyst"
    PLATFORM_RID="maccatalyst-arm64"
    PLATFORM_DEVICE_TYPE="maccatalyst"
    PLATFORM_SCENARIO_DIR="$SCENARIOS_DIR/genericmacosstartup"
    PLATFORM_PACKAGE_GLOB="*.app"
    PLATFORM_PACKAGE_LABEL="APP"
    PLATFORM_DIR="$MACCATALYST_DIR"
    ;;
```

**Other files:** Same pattern as iOS — update `Directory.Build.props/targets`, `build.sh`, `measure_all.sh`, etc.

**Note:** Mac Catalyst apps are MAUI-only (there's no `dotnet new maccatalyst` template). The template app is generated as a MAUI app with `net11.0-maccatalyst` in TargetFrameworks.

**Acceptance criteria:**
- Platform resolution works for maccatalyst
- measure_all.sh has correct default apps: `dotnet-new-maui`, `dotnet-new-maui-samplecontent` (no standalone template)

### Task 3.3 — Mac Catalyst app generation & workloads

**What:** Update `generate-apps.sh` and `prepare.sh` for Mac Catalyst.

**Changes:**
- `generate-apps.sh`: Add `maccatalyst` platform flag; include `net11.0-maccatalyst` in MAUI TargetFrameworks
- `prepare.sh`: Install `maccatalyst maui-maccatalyst` workloads
- No standalone template app — maccatalyst uses MAUI apps only

**Acceptance criteria:**
- MAUI apps build for `net11.0-maccatalyst`
- Workloads install correctly

### Task 3.4 — Mac Catalyst README

**Files:** `maccatalyst/README.md`

---

## Step 4 — Apple .nettrace Collection

**Branch:** `feature/apple-nettrace-collection`
**Goal:** Port `android/collect_nettrace.sh` logic for Apple platforms.

### Task 4.1 — iOS .nettrace collection

**What:** Create `ios/collect_nettrace.sh` for collecting diagnostic traces from iOS devices.

**Differences from Android:**
- No `adb` — use `xcrun devicectl` for device interaction
- Diagnostics bridge may differ (no `--forward-port Android` in dsrouter)
- App deployment via xharness or `xcrun devicectl`
- Device log collection via `log collect --device` instead of `adb logcat`

### Task 4.2 — macOS/Mac Catalyst .nettrace collection

**What:** Desktop-style trace collection (similar to standard dotnet-trace workflow).
- No device bridge needed — dsrouter in local mode
- Direct process launch with `DOTNET_DiagnosticPorts` environment variable

---

## Step 5 — Documentation & Main README Update

**Branch:** `feature/apple-docs`
**Goal:** Update main README and ensure all platform docs are complete.

### Task 5.1 — Update main README.md

**Changes:**
- Prerequisites section: add iOS, Mac Catalyst, macOS requirements
- Platform support matrix table
- Usage examples for each platform
- Update project structure tree to include new platform directories

### Task 5.2 — Validate config table in README

**What:** Update the Runtime Configurations table to note platform availability:
- `R2R` — Android only
- `R2R_COMP`, `R2R_COMP_PGO` — All platforms
- `MONO_JIT`, `MONO_AOT`, `MONO_PAOT` — Android and iOS; research needed for macOS

---

## Dependencies

```
Step 1 (iOS)          → independent (can start immediately)
Step 2 (osx)          → depends on Step 1 (reuses patterns established for iOS)
Step 3 (maccatalyst)  → depends on Step 1 (reuses patterns)
Step 4 (nettrace)     → depends on Steps 1-3 (platforms must build first)
Step 5 (docs)         → depends on Steps 1-3 (content depends on what was implemented)
```

## Testing Strategy

For each platform, verify:
1. **Build**: `./build.sh --platform <platform> <app> <config> build 1` succeeds
2. **Package discovery**: The built `.app` bundle is found by `measure_startup.sh`
3. **Size reporting**: `./platform/print_app_sizes.sh` correctly reports sizes
4. **Config validation**: All valid configs build; invalid configs are rejected
5. **App generation**: `./generate-apps.sh --platform <platform>` creates the expected app directories
6. **Workload installation**: `./prepare.sh --platform <platform>` installs the correct workloads

Device-specific testing (startup measurement) requires physical hardware and is done manually.

## Risks

1. **dotnet/performance scenario availability**: `genericiosstartup` and `genericmacosstartup` scenarios may not exist in the submodule — may need to create or stub them
2. **Mac Catalyst startup measurement**: No established measurement pattern in dotnet/performance — may need a custom approach
3. **Mono AOT on macOS**: May not be supported or may require different properties than iOS
4. **MAUI macOS support**: MAUI may not fully support `net11.0-macos` TFM — needs verification
5. **Workload names**: Workload identifiers may differ from assumed names — verify with `dotnet workload search`
