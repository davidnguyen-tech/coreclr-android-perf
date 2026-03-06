# Implementation Plan — Apple Platform Measurement Support

Add CoreCLR performance measurement support for **iOS**, **macOS (osx)**, and **Mac Catalyst**. See research docs in `.github/researches/` for detailed context on each topic.

## Constraints

- All Apple platforms use MachO → only Composite R2R (no non-composite `R2R` config)
- All produce `.app` bundles (directories) → size via `du -sk`, not `stat`
- All PRs branch from and merge into `feature/apple-agents` (never `main`)

## Step 1 — iOS Platform Support

See [.github/researches/ios-platform.md](.github/researches/ios-platform.md) for iOS-specific constraints, build properties, and device deployment details.

- [ ] Create `ios/build-configs.props` — 6 configs: MONO_JIT, MONO_AOT, MONO_PAOT, CORECLR_JIT, R2R_COMP, R2R_COMP_PGO
- [ ] Create `ios/build-workarounds.targets` — `GenerateInfoIos` target (conditioned on `TargetPlatformIdentifier == 'ios'`)
- [ ] Create `ios/print_app_sizes.sh` — scan `*.app` directories under `Release/`, report sizes
- [ ] Add `ios` case to `resolve_platform_config()` in `init.sh`
- [ ] Import `ios/build-configs.props` in `Directory.Build.props`
- [ ] Import `ios/build-workarounds.targets` in `Directory.Build.targets`
- [ ] Rename `GenerateInfo` → `GenerateInfoAndroid` in `android/build-workarounds.targets` (add platform condition)
- [ ] Update `build.sh` usage text and platform validation to include `ios`
- [ ] Update `measure_startup.sh` — handle `.app` directory bundles for package discovery and size
- [ ] Add `ALL_CONFIGS_IOS` and default iOS app list to `measure_all.sh`
- [ ] Update `generate-apps.sh` — generate `dotnet-new-ios` via `dotnet new ios`, include `net11.0-ios` in MAUI TFMs, make profiling patches platform-aware
- [ ] Update `prepare.sh` — install `ios maui-ios` workloads when `--platform ios`
- [ ] Create `ios/README.md` — prerequisites (iPhone, Xcode, sudoers for `log collect`), configs table, usage examples

## Step 2 — macOS (osx) Platform Support

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

## Step 3 — Mac Catalyst Platform Support

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

## Step 4 — Apple .nettrace Collection

See [.github/researches/apple-nettrace.md](.github/researches/apple-nettrace.md) for diagnostics bridge differences between Android and Apple platforms.

- [ ] Create `ios/collect_nettrace.sh` — device trace collection via xcrun devicectl + dsrouter
- [ ] Create desktop-style .nettrace collection for macOS/maccatalyst (direct process, no device bridge)

## Step 5 — Documentation

- [ ] Update main `README.md` — add all Apple platforms to prerequisites, usage examples, project structure tree, config availability table

