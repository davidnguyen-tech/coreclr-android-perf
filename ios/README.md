# iOS Support

iOS-specific performance measurement scripts and configurations.

## Contents

- `build-configs.props` — iOS build configuration presets (MONO_JIT, MONO_AOT, MONO_PAOT, CORECLR_JIT, R2R, R2R_COMP, R2R_COMP_PGO)
- `build-workarounds.targets` — iOS build workarounds and info target
- `print_app_sizes.sh` — iOS app bundle size reporting

## Build Configurations

| Config | Runtime | AOT | R2R |
|---|---|---|---|
| MONO_JIT | Mono | No | No |
| MONO_AOT | Mono | Full AOT | No |
| MONO_PAOT | Mono | Profiled AOT | No |
| CORECLR_JIT | CoreCLR | No | No |
| R2R | CoreCLR | No | Single-assembly |
| R2R_COMP | CoreCLR | No | Composite |
| R2R_COMP_PGO | CoreCLR | No | Composite + PGO |

## Usage

```bash
# Prepare the environment for iOS
./prepare.sh --platform ios

# Measure startup for all iOS apps and configs
./measure_all.sh --platform ios

# Measure a single app/config
./measure_startup.sh dotnet-new-ios MONO_AOT --platform ios

# Build only (no measurement)
./build.sh --platform ios dotnet-new-ios R2R build 1
```

## iOS Apps

- `dotnet-new-ios` — Basic iOS template app
- `dotnet-new-maui` — MAUI app (multi-platform, shared with Android)
- `dotnet-new-maui-samplecontent` — MAUI sample content app (multi-platform)
