# iOS Performance Measurement Support

iOS-specific build configurations, workarounds, and tooling for CoreCLR startup performance measurement on physical iOS devices.

## Prerequisites

- **macOS** with Xcode installed (latest stable recommended)
- **Physical iPhone** (arm64) — iOS Simulator is not supported for accurate startup measurements
- **Apple Developer account** with a valid provisioning profile for device deployment
- **xharness** CLI tool (installed automatically by `prepare.sh`)
- **Python 3** for dotnet/performance test harness
- **sudo access** may be required for `log collect` (unified log collection)

## Build Configurations

iOS uses 6 build configurations. Non-composite ReadyToRun (`R2R`) is **not available** on Apple platforms because the MachO binary format only supports Composite R2R images.

| Config | Runtime | UseMonoRuntime | AOT | Profiled AOT | R2R | R2R Composite | PGO |
|--------|---------|---------------|-----|-------------|-----|---------------|-----|
| `MONO_JIT` | Mono | True | No | — | No | No | — |
| `MONO_AOT` | Mono | True | Yes | No | — | — | — |
| `MONO_PAOT` | Mono | True | Yes | Yes (default) | — | — | — |
| `CORECLR_JIT` | CoreCLR | False | No | — | No | No | — |
| `R2R_COMP` | CoreCLR | False | — | — | Yes | Yes | — |
| `R2R_COMP_PGO` | CoreCLR | False | — | — | Yes | Yes | Yes |

### Configuration Details

- **MONO_JIT** — Mono runtime with JIT compilation only. Baseline for Mono performance.
- **MONO_AOT** — Mono runtime with full Ahead-of-Time compilation (`RunAOTCompilation=True`, `MtouchProfiledAOT=False`).
- **MONO_PAOT** — Mono runtime with profiled AOT (`RunAOTCompilation=True`, `MtouchProfiledAOT=True`). This is the default AOT mode that uses profiling data to prioritize which methods to AOT compile.
- **CORECLR_JIT** — CoreCLR runtime with JIT compilation only. Baseline for CoreCLR performance.
- **R2R_COMP** — CoreCLR with Composite ReadyToRun images (`PublishReadyToRun=True`, `PublishReadyToRunComposite=True`). Pre-compiled native code for faster startup.
- **R2R_COMP_PGO** — Composite ReadyToRun with PGO (Profile-Guided Optimization) profiles from `dotnet-optimization` CI for optimized native code layout.

### Why No Non-Composite R2R?

Apple platforms use the **MachO** binary format, which only supports Composite ReadyToRun images. The crossgen2 compiler cannot produce non-composite R2R images for MachO targets. This is a platform limitation — Android (ELF format) supports both composite and non-composite R2R.

## iOS-Specific MSBuild Properties

| Property | Description |
|----------|-------------|
| `MtouchProfiledAOT` | iOS equivalent of Android's `AndroidEnableProfiledAot`. Controls whether profiled AOT compilation is used. |
| `UseMonoRuntime` | Selects Mono (`True`) or CoreCLR (`False`) runtime. Same as Android. |
| `RunAOTCompilation` | Enables AOT compilation. Same as Android. |
| `PublishReadyToRun` | Enables ReadyToRun compilation. Same as Android. |
| `PublishReadyToRunComposite` | Enables composite R2R. Must be `True` for iOS (non-composite not supported). |

## Usage

### Setup

```bash
# Install SDK, workloads, and tools for iOS
./prepare.sh --platform ios

# Generate sample iOS apps
./generate-apps.sh --platform ios
```

### Building

```bash
# Build a specific app with a specific config
./build.sh --platform ios dotnet-new-ios CORECLR_JIT build 1

# Build MAUI app with R2R Composite
./build.sh --platform ios dotnet-new-maui R2R_COMP build 1
```

### Measuring Startup

```bash
# Measure a single app/config combination
./measure_startup.sh dotnet-new-ios CORECLR_JIT --platform ios

# Measure all iOS apps across all configs
./measure_all.sh --platform ios

# Measure with fewer iterations for quick testing
./measure_all.sh --platform ios --startup-iterations 3
```

### App Size Reporting

```bash
# Print sizes of built iOS .app bundles
./ios/print_app_sizes.sh

# Detailed view showing largest files in each bundle
./ios/print_app_sizes.sh -detailed
```

## Package Discovery

iOS apps are built as `.app` directory bundles (not single files like Android APKs). The measurement scripts use:

- `find` with `*.app` glob to locate built bundles
- `du -sk` to measure total bundle size (since `stat` on a directory doesn't give content size)
- Bundles are found under `apps/<app-name>/bin/Release/net11.0-ios/ios-arm64/`

## Device Deployment

iOS app deployment and startup measurement uses:

- **xharness** for app installation and management
- **xcrun devicectl** for device interaction and app launching
- The `dotnet/performance` submodule's `genericiosstartup` scenario handles the measurement harness

## File Structure

```
ios/
├── README.md                  # This file
├── build-configs.props        # 6 build configuration presets
├── build-workarounds.targets  # iOS-specific build targets
└── print_app_sizes.sh         # .app bundle size reporting
```
