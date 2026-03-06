# macOS Performance Measurement Support

macOS-specific build configurations, workarounds, and tooling for CoreCLR startup performance measurement on Apple Silicon Macs.

## Prerequisites

- **macOS** with Xcode installed (latest stable recommended)
- **Apple Silicon Mac** (arm64) — the target machine is also the build machine
- **Python 3** for dotnet/performance test harness
- **Passwordless `sudo` for `log collect`** — startup measurement relies on `sudo log collect` to gather unified logs. Configure a sudoers entry so that `log collect` can run without a password prompt:
  ```
  # /etc/sudoers.d/log-collect
  %admin ALL=(ALL) NOPASSWD: /usr/bin/log
  ```

## Build Configurations

macOS uses 6 build configurations. Non-composite ReadyToRun (`R2R`) is **not available** on Apple platforms because the MachO binary format only supports Composite R2R images.

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

## macOS-Specific MSBuild Properties

| Property | Description |
|----------|-------------|
| `MtouchProfiledAOT` | Controls whether profiled AOT compilation is used. |
| `UseMonoRuntime` | Selects Mono (`True`) or CoreCLR (`False`) runtime. Same as Android. |
| `RunAOTCompilation` | Enables AOT compilation. Same as Android. |
| `PublishReadyToRun` | Enables ReadyToRun compilation. Same as Android. |
| `PublishReadyToRunComposite` | Enables composite R2R. Must be `True` for macOS (non-composite not supported). |

## Usage

### Setup

```bash
# Install SDK, workloads, and tools for macOS
./prepare.sh --platform osx

# Generate sample macOS apps
./generate-apps.sh --platform osx
```

### Building

```bash
# Build a standalone macOS app with a specific config
./build.sh --platform osx dotnet-new-macos CORECLR_JIT build 1

# Build MAUI app with R2R Composite
./build.sh --platform osx dotnet-new-maui R2R_COMP build 1
```

### Measuring Startup

```bash
# Measure a single app/config combination
./measure_startup.sh dotnet-new-macos CORECLR_JIT --platform osx

# Measure all macOS apps across all configs
./measure_all.sh --platform osx

# Measure with fewer iterations for quick testing
./measure_all.sh --platform osx --startup-iterations 3
```

### App Size Reporting

```bash
# Print sizes of built macOS .app bundles
./osx/print_app_sizes.sh

# Detailed view showing largest files in each bundle
./osx/print_app_sizes.sh -detailed
```

## Package Discovery

macOS apps are built as `.app` directory bundles (not single files like Android APKs). The measurement scripts use:

- `find` with `*.app` glob to locate built bundles
- `du -sk` to measure total bundle size (since `stat` on a directory doesn't give content size)
- Bundles are found under `apps/<app-name>/bin/Release/net11.0-macos/osx-arm64/`

## App Templates

macOS supports both standalone and MAUI app templates:

- **`dotnet new macos`** — standalone macOS (Cocoa) app. Generates the `dotnet-new-macos` sample app.
- **`dotnet new maui`** — .NET MAUI cross-platform app. Generates `dotnet-new-maui` and `dotnet-new-maui-samplecontent` sample apps. MAUI apps have their `TargetFrameworks` rewritten to include only `net11.0-macos`.

## File Structure

```
osx/
├── README.md                  # This file
├── build-configs.props        # 6 build configuration presets
├── build-workarounds.targets  # macOS-specific build targets
└── print_app_sizes.sh         # .app bundle size reporting
```
