# Environment State & Measurement Feasibility

Deep investigation of current environment state, MIBC profile integration, and which
platforms can actually be measured on this machine right now.

---

## 1. Build Configs Using MIBC Profiles

### Which configs reference PGO?

All four platform `build-configs.props` files define an `R2R_COMP_PGO` config that sets `<PGO>True</PGO>`:

| Platform | File | Line | Key Properties |
|----------|------|------|---------------|
| Android | `android/build-configs.props` | 63-74 | `PublishReadyToRun=True`, `PublishReadyToRunComposite=True`, `PGO=True` |
| iOS | `ios/build-configs.props` | 45-54 | Same (RID: `ios-arm64`, TFM: `net11.0-ios`) |
| macOS Catalyst | `maccatalyst/build-configs.props` | 45-54 | Same (RID: `maccatalyst-arm64`, TFM: `net11.0-maccatalyst`) |
| macOS | `osx/build-configs.props` | 45-54 | Same (RID: `osx-arm64`, TFM: `net11.0-macos`) |

**Key**: `<PGO>True</PGO>` is a custom MSBuild property that activates profile loading in the
patched csproj files. It is NOT a standard SDK property — it's only consumed by the patches
applied by `generate-apps.sh`.

### How `generate-apps.sh` integrates MIBC profiles

**Step 1 — Copy profiles** (`generate-apps.sh` lines 111-115):
```bash
mkdir -p "$app_dir/profiles"
if [ -d "$SCRIPT_DIR/profiles" ]; then
    cp "$SCRIPT_DIR/profiles"/*.mibc "$app_dir/profiles/" 2>/dev/null
fi
```

**Step 2 — Patch csproj** (`generate-apps.sh` lines 122-174):

For **MAUI apps** (lines 147-157):
```xml
<PropertyGroup Condition="... and '$(PGO)' == 'true'">
  <_MauiUseDefaultReadyToRunPgoFiles>false</_MauiUseDefaultReadyToRunPgoFiles>
</PropertyGroup>
<ItemGroup Condition="... and '$(PGO)' == 'true'">
  <_ReadyToRunPgoFiles Include="$(MSBuildThisFileDirectory)profiles/*.mibc" />
</ItemGroup>
```

For **non-MAUI apps** (lines 160-169):
```xml
<ItemGroup Condition="... and '$(PGO)' == 'true'">
  <_ReadyToRunPgoFiles Include="$(MSBuildThisFileDirectory)profiles/*.mibc" />
</ItemGroup>
<PropertyGroup Condition="... and '$(PGO)' == 'true'">
  <PublishReadyToRunCrossgen2ExtraArgs>--partial</PublishReadyToRunCrossgen2ExtraArgs>
</PropertyGroup>
```

**Profile flow**: `profiles/*.mibc` → `<app>/profiles/*.mibc` → `_ReadyToRunPgoFiles` MSBuild item → crossgen2 `--mibc` args

### Config summary per platform

| Config | Android | iOS | macOS Catalyst | macOS |
|--------|---------|-----|---------------|-------|
| MONO_AOT | ✅ | ✅ | ✅ | ✅ |
| MONO_PAOT | ✅ | ✅ | ✅ | ✅ |
| MONO_JIT | ✅ | ✅ | ✅ | ✅ |
| CORECLR_JIT | ✅ | ✅ | ✅ | ✅ |
| R2R (non-composite) | ✅ | ❌ | ❌ | ❌ |
| R2R_COMP | ✅ | ✅ | ✅ | ✅ |
| R2R_COMP_PGO | ✅ | ✅ | ✅ | ✅ |

Apple platforms only support **composite** R2R because of MachO binary format constraints.

---

## 2. Current Environment State

### SDK
- **Installed**: ✅ `.dotnet/dotnet` exists
- **Version**: `11.0.100-preview.3.26123.103` (from `versions.log`)
- **Workloads**: Unknown (not in `versions.log`, so likely installed for a different platform run)

### Tools (`tools/`)
- Only `dotnet-install.sh` exists
- **xharness**: ❌ NOT installed
- **dotnet-dsrouter**: ❌ NOT installed
- **dotnet-trace**: ❌ NOT installed

This indicates `prepare.sh` hasn't been fully run, or was run for a different worktree.

### Apps (`apps/`)
- `FakeApp/` — empty csproj, test artifact
- `FakeApp.app/` — empty Info.plist, test artifact
- `hello-custom/` — Android-only custom app (`net11.0-android`)
- **No dotnet-new-* generated apps** exist

### Profiles (`profiles/`)
- **Directory does NOT exist**
- No `.mibc` files have been downloaded
- `download-mibc.sh` has never been run

### Results (`results/`)
- `summary.csv` exists but is **empty** (header only)

### dotnet/performance submodule (`external/performance/`)
- **Populated**: ✅
- Scenario directories present:
  - `genericandroidstartup/` ✅
  - `helloios/` ✅
  - `mauiios/` ✅
  - `mauimaccatalyst/` ✅
  - `netios/` ✅
- **Missing** (referenced by `init.sh` but don't exist):
  - `genericiosstartup/` ❌ (referenced at `init.sh` line 56)
  - `genericmacosstartup/` ❌ (referenced at `init.sh` line 79)
  - `genericmaccatalyststartup/` ❌ (referenced at `init.sh` line 89)

---

## 3. Device/Simulator Availability

### Machine Architecture
This machine is Darwin/macOS. Based on the repo's RID defaults (`osx-arm64`, `maccatalyst-arm64`), this is an **ARM Mac (Apple Silicon)**.

### iOS Simulators
Need `xcrun simctl list devices available` — likely available if Xcode is installed.

### Physical Devices
- **iPhone/iPad**: Unknown — requires USB connection and `xcrun devicectl`
- **Android**: Unknown — requires `adb devices`

---

## 4. Platform Measurement Feasibility

### Feasibility Matrix

| Platform | Scenario Dir | test.py device-type | Measurement Script | Status |
|----------|-------------|--------------------|--------------------|--------|
| `android` | `genericandroidstartup/` ✅ | `android` ✅ | `measure_startup.sh` | ⚠️ Requires physical device + `adb` |
| `android-emulator` | `genericandroidstartup/` ✅ | `android` ✅ | `measure_startup.sh` | ⚠️ Requires running emulator |
| `ios` | ❌ `genericiosstartup/` missing | `ios` ✅ | `measure_startup.sh` | ❌ **BROKEN** — scenario dir missing; also needs physical device + `sudo` |
| `ios-simulator` | N/A (bypasses test.py) | N/A | `ios/measure_simulator_startup.sh` | ✅ **FEASIBLE** — self-contained, uses `xcrun simctl` |
| `osx` | ❌ `genericmacosstartup/` missing | `osx` ❌ (invalid choice) | `measure_startup.sh` | ❌ **BROKEN** — scenario dir missing + invalid device type |
| `maccatalyst` | ❌ `genericmaccatalyststartup/` missing | `maccatalyst` ❌ (invalid choice) | `measure_startup.sh` | ❌ **BROKEN** — scenario dir missing + invalid device type |

### Detailed Blockers

#### `ios` (physical device via test.py)
1. `genericiosstartup/` scenario dir doesn't exist in `external/performance/src/scenarios/`
2. `measure_startup.sh` line 234 does `cd "$PLATFORM_SCENARIO_DIR"` → fails
3. Even if created, requires: physical iPhone, USB, xharness, `sudo log collect --device`

#### `ios-simulator` ✅ — **The only Apple platform that works NOW**
- `measure_startup.sh` line 95-101: detects `ios-simulator` and redirects to `ios/measure_simulator_startup.sh`
- `ios/measure_simulator_startup.sh` is a **fully self-contained** 496-line script
- Uses `xcrun simctl` for: simulator detection → boot → install → launch → terminate → uninstall
- Wall-clock timing via `python3 time.time_ns()`
- Outputs "Generic Startup | avg | min | max" format compatible with `measure_all.sh` parsing
- Auto-detects booted simulator or finds available iPhone simulator
- **Requirements**: .NET SDK + ios workload + Xcode + iOS simulator runtime

#### `osx` and `maccatalyst`
1. Scenario directories don't exist
2. `runner.py` line 71 only accepts `choices=['android','ios']` — `osx` and `maccatalyst` are invalid
3. These platforms **need custom measurement scripts** similar to `ios/measure_simulator_startup.sh`
4. macOS/maccatalyst apps run locally — wall-clock `open -a` timing is viable

### What's Needed to Run `ios-simulator` Measurement Right Now

```bash
# Step 1: Install SDK + tools + workloads + generate apps
./prepare.sh --platform ios-simulator

# Step 2: (Optional) Download MIBC profiles for PGO builds
./download-mibc.sh --platform ios-simulator

# Step 3: Regenerate apps to include profiles (if profiles downloaded after Step 1)
# prepare.sh already calls generate-apps.sh, so this is only needed if
# you downloaded MIBC profiles after initial setup
rm -rf apps/dotnet-new-ios apps/dotnet-new-maui apps/dotnet-new-maui-samplecontent
./generate-apps.sh --platform ios-simulator

# Step 4: Run measurement for a single (app, config)
./measure_startup.sh dotnet-new-ios CORECLR_JIT --platform ios-simulator

# Step 5: Run ALL measurements
./measure_all.sh --platform ios-simulator --startup-iterations 3

# Step 6: Results are in results/summary.csv
```

---

## 5. The `download-mibc.sh` Script

### Supported Platforms

From `download-mibc.sh` lines 62-79:

| Platform arg | RID used | Notes |
|-------------|----------|-------|
| `android` | `android-arm64` | |
| `android-emulator` | `android-arm64` | Fallback to device RID with warning |
| `ios` | `ios-arm64` | |
| `ios-simulator` | `ios-arm64` | Fallback to device RID with warning |
| `maccatalyst` | `maccatalyst-arm64` | |
| `osx` | `osx-arm64` | |

### Package naming
```
optimization.<rid>.MIBC.Runtime
```
Example: `optimization.ios-arm64.MIBC.Runtime`

### Feed URL
`https://pkgs.dev.azure.com/dnceng/public/_packaging/dotnet-tools/nuget/v3/flat2`

### Version resolution
- Default: queries latest version from NuGet V3 flat container API
- Optional: `--version <version>` for specific version
- Uses `python3` for JSON parsing

### Output location
- `.mibc` files extracted to `profiles/` directory in repo root
- Extracted from `data/*.mibc` inside the nupkg (ZIP format)
- Appends version info to `versions.log`

### Error handling
- HTTP 404 → **graceful exit** (not error) with message "MIBC profiles are optional"
- No `.mibc` files in package → **graceful exit** with warning
- This is important because not all platform packages may exist on the public feed

---

## 6. Measurement Scripts Architecture

### `measure_startup.sh` — Main orchestrator

**Flow for most platforms** (lines 233-244):
```
cd $PLATFORM_SCENARIO_DIR  (e.g., genericandroidstartup/)
python3 test.py devicestartup \
    --device-type $PLATFORM_DEVICE_TYPE \
    --package-path $PACKAGE_PATH \
    --package-name $PACKAGE_NAME
```

**Special case: `ios-simulator`** (lines 95-102):
```
exec "$SCRIPT_DIR/ios/measure_simulator_startup.sh" "$SAMPLE_APP" "$BUILD_CONFIG" "$@"
```
This completely bypasses `test.py` and uses its own wall-clock measurement.

### `measure_all.sh` — Batch runner

- Iterates over all (app, config) pairs
- Special-cases `ios-simulator` at line 138-140: calls `ios/measure_simulator_startup.sh` directly
- Parses "Generic Startup | avg | min | max" output from both test.py and simulator script
- Writes `results/summary.csv`

### `ios/measure_simulator_startup.sh` — Self-contained simulator measurement

Key features:
- 496 lines, fully independent of dotnet/performance
- Builds app, locates `.app` bundle, installs on simulator, measures wall-clock launch time
- Supports `--no-build`, `--package-path`, `--simulator-name`, `--simulator-udid`
- Each iteration: uninstall → install → launch → terminate (cold start)
- Statistics: mean, median, min, max, stdev via python3
- Saves per-iteration CSV to `results/<app>_<config>_simulator.csv`

---

## 7. Key Risks & Unknowns

| Risk | Severity | Impact |
|------|----------|--------|
| MIBC packages for Apple platforms may not exist on public feed | High | R2R_COMP_PGO builds will compile without PGO optimization (still succeeds due to `--partial`) |
| `osx`/`maccatalyst` measurement broken — no scenario dirs or device type support in test.py | High | Need custom measurement scripts like `measure_simulator_startup.sh` |
| `ios` (physical device) requires missing `genericiosstartup/` scenario dir | High | Cannot measure on physical iOS device |
| Tools (xharness, dotnet-trace, dsrouter) not installed | Medium | `prepare.sh` reinstalls everything; resolved by running it |
| No generated apps exist | Medium | `prepare.sh` calls `generate-apps.sh`; resolved by running it |
| iOS simulator measurement is wall-clock only (not app-internal timing) | Low | Acceptable for relative comparisons between build configs |
| SDK version (preview.3) may have workload compatibility issues | Low | Previous research documented workarounds |

---

## 8. Actionable Sequence for Running Measurements NOW

### Fastest path: iOS Simulator (only working Apple platform)

```bash
# 1. Full environment setup (SDK + workloads + tools + apps)
./prepare.sh --platform ios-simulator -f

# 2. Download MIBC profiles (optional, for R2R_COMP_PGO config)
./download-mibc.sh --platform ios-simulator

# 3. If profiles were downloaded, regenerate apps to include them
rm -rf apps/dotnet-new-ios apps/dotnet-new-maui apps/dotnet-new-maui-samplecontent
./generate-apps.sh --platform ios-simulator

# 4. Quick smoke test (single app, single config, 3 iterations)
./measure_startup.sh dotnet-new-ios CORECLR_JIT --platform ios-simulator --startup-iterations 3

# 5. Full measurement sweep
./measure_all.sh --platform ios-simulator --startup-iterations 10

# 6. View results
cat results/summary.csv
```

### What's needed to enable other Apple platforms

| Platform | What's Missing | Effort |
|----------|---------------|--------|
| `ios` (device) | Create `genericiosstartup/` scenario dir, physical device | Medium — scenario dir is trivial, device access is hard |
| `osx` | Custom measurement script (like `measure_simulator_startup.sh`), create `genericmacosstartup/` | Medium |
| `maccatalyst` | Custom measurement script, create `genericmaccatalyststartup/` | Medium |

For `osx` and `maccatalyst`, the measurement approach should be:
- Build the `.app` bundle
- Launch with `open -a <bundle>` or direct executable invocation
- Time with wall-clock (same approach as simulator script)
- No need for test.py or dotnet/performance at all
