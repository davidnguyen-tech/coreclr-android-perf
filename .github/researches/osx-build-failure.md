# macOS (osx) Build Failure — 5 of 6 Configs Fail During `measure_all.sh`

## Summary

`measure_all.sh --platform osx` succeeds for **CORECLR_JIT** but fails for all
other configs: MONO_JIT, MONO_AOT, MONO_PAOT, R2R_COMP, R2R_COMP_PGO.

There are **two distinct root causes**:

1. **MONO configs** (MONO_JIT, MONO_AOT, MONO_PAOT): The macOS SDK explicitly
   blocks Mono runtime. Hard error at `Xamarin.Shared.Sdk.targets:1143`.
2. **R2R configs** (R2R_COMP, R2R_COMP_PGO): Container format mismatch — the
   Apple SDK's R2R framework creation expects MachO object files, but the default
   `PublishReadyToRunContainerFormat` for macOS on .NET 11+ is `pe`.

> **History**: A previous issue where `osx/measure_osx_startup.sh` deleted both
> `bin/` and `obj/` was already fixed — line 156 now only cleans `bin/`. This
> enabled CORECLR_JIT to succeed, but the two issues below remain.

---

## Root Cause 1 — Mono Is Not Supported on macOS

### The Error

The macOS SDK has an explicit validation target that rejects Mono:

```xml
<!-- Xamarin.Shared.Sdk.targets:1142-1144 (in Microsoft.macOS.Sdk pack) -->
<Target Name="_VerifyValidRuntime">
    <Error Text="Only CoreCLR is supported on macOS. Set 'UseMonoRuntime=false' to use CoreCLR."
           Condition="'$(_PlatformName)' == 'macOS' And '$(UseMonoRuntime)' != 'false'" />
</Target>
```

This target is a dependency of `_ComputeVariables` (line 1159) and runs early in
the build pipeline.

### Which Configs Are Affected

| Config | `UseMonoRuntime` | Passes? |
|--------|-----------------|---------|
| MONO_JIT | `True` | ❌ `True != false` → ERROR |
| MONO_AOT | `True` | ❌ ERROR |
| MONO_PAOT | `True` | ❌ ERROR |
| CORECLR_JIT | `False` | ✅ (case-insensitive match) |
| R2R_COMP | `False` | ✅ Passes this check, fails elsewhere |
| R2R_COMP_PGO | `False` | ✅ Passes this check, fails elsewhere |

### Evidence: No Mono in macOS Runtime Pack

`.dotnet/packs/Microsoft.macOS.Runtime.osx-arm64.net11.0_26.2/.../runtimes/osx-arm64/native/`
contains ONLY CoreCLR and NativeAOT variants. No `libmonosgen-2.0.dylib`.

The SDK default at `Xamarin.Shared.Sdk.props:41` confirms macOS defaults to CoreCLR.

### Fix

Remove MONO configs from macOS in `measure_all.sh` and `osx/build-configs.props`.

---

## Root Cause 2 — R2R Container Format Mismatch

`PublishReadyToRunContainerFormat` evaluates to `pe` (not `macho`) for macOS:

- `Xamarin.Shared.Sdk.props:227` excludes macOS from auto-setting `macho`
- `Microsoft.NET.CrossGen.targets:28` defaults to `pe` for .NET 11+
- Apple SDK's `_CreateR2RFramework` tries to link PE files with clang → FAILS

Fix: Add `<PublishReadyToRunContainerFormat>macho</PublishReadyToRunContainerFormat>` to R2R configs.

---

## Required Changes

1. `measure_all.sh` line 76-78: macOS gets only `CORECLR_JIT R2R_COMP R2R_COMP_PGO`
2. `osx/build-configs.props`: Remove MONO PropertyGroups, add `PublishReadyToRunContainerFormat=macho` to R2R configs

---

## Environment

SDK: 11.0.100-preview.3.26123.103 | macOS workload: 26.2.11310-net11-p1 | Platform: macOS arm64

1. ILLinker runs → generates `linker-items/*.items` files and `linker-cache/*.mm` source files
2. `_LoadLinkerOutput` target (line 1056) reads `.items` → populates `@(_MainFile)`, `@(_RegistrarFile)`
3. `_CompileNativeExecutable` (line 1631) runs `CompileNativeCode` (clang) → **FAILS**
4. Either: MSBuild returns non-zero → script catches at line 167 ("Error: Build failed.")
5. Or: target is skipped (empty inputs) → build returns 0 → script catches at line 228 ("App executable not found")

The native executable is **configuration-independent** — the same `dotnet-new-macos`
binary works for MONO_JIT, CORECLR_JIT, R2R_COMP, etc. It's a host that loads the
runtime and managed assemblies. Only the assemblies in `Contents/MonoBundle/` differ
between configs.

### SDK Target Chain (Reference)

```
CreateAppBundleDependsOn (Xamarin.Shared.Sdk.targets line 238):
  _CopyResourcesToBundle        ← Creates Contents/Resources/
  _CreatePkgInfo                ← Creates Contents/PkgInfo
  _LoadLinkerOutput             ← Reads .items → @(_MainFile), @(_RegistrarFile)
  _CompileNativeExecutable      ← Clang: main.mm + registrar.mm → .o files    ← FAILS HERE
  _LinkNativeExecutable         ← Links .o → Contents/MacOS/<executable>
  CopyFilesToPublishDirectory   ← Copies DLLs/dylibs into .app
```

`_CompileNativeExecutable` uses incremental Inputs/Outputs:
```xml
<Target Name="_CompileNativeExecutable"
    Inputs="@(_CompileNativeExecutableFile)"
    Outputs="@(_CompileNativeExecutableFile -> '%(OutputFile)')">
```

If `@(_CompileNativeExecutableFile)` is empty (populated from `@(_MainFile)` + `@(_RegistrarFile)` + `@(_ReferencesFile)`), MSBuild silently skips the target. Build returns 0 but no native executable is produced.

---

## The Fix

**Change line 156 of `osx/measure_osx_startup.sh`** — only clean `bin/`, preserve `obj/`:

```bash
# BEFORE (line 156):
rm -rf "${APP_DIR:?}/bin" "${APP_DIR:?}/obj"

# AFTER:
rm -rf "${APP_DIR:?}/bin"
```

**Same change needed in:**
- `maccatalyst/measure_maccatalyst_startup.sh` line 157
- `ios/measure_simulator_startup.sh` line 289

**Why this is safe:** The `obj/` directory contains MSBuild intermediate state
(assembly caches, linker output, native compilation objects) that is keyed by
`(TFM, RID, Configuration)`. All 6 build configs share the same
`(net11.0-macos, osx-arm64, Release)` tuple. MSBuild's incremental build correctly
handles property changes (UseMonoRuntime, PublishReadyToRun, etc.) within the same
TFM/RID/Configuration by regenerating only the affected outputs. The native
executable itself is configuration-independent.

**Cleaning `bin/` is sufficient** because `bin/` contains the final build outputs
(the `.app` bundle, DLLs, etc.) which MUST be rebuilt fresh for each config to ensure
the correct runtime (Mono vs CoreCLR) and assemblies (JIT vs R2R) are packaged.

---

## Evidence

### Current State (After Manual Build)

The `obj/` directory shows a **complete** set of native compilation artifacts
from the user's manual CORECLR_JIT build:

```
obj/Release/net11.0-macos/osx-arm64/
  nativelibraries/main.arm64.o        ← Compiled native entry point
  nativelibraries/registrar.o         ← Compiled registrar
  nativelibraries/dotnet-new-macos    ← Linked native executable
  linker-items/_MainFile.items        ← MSBuild item cache
  linker-items/_RegistrarFile.items   ← MSBuild item cache
  linker-cache/main.arm64.mm          ← Generated source
  linker-cache/registrar.mm           ← Generated registrar source
  codesign/dotnet-new-macos.app/.stampfile  ← Codesign stamp
```

### bin/ Has Complete .app (After Manual Build)

```
bin/Release/net11.0-macos/osx-arm64/dotnet-new-macos.app/
  Contents/
    Info.plist                         ← ✓ App manifest
    PkgInfo                            ← ✓ Package type
    Resources/                         ← ✓ Assets, storyboards
    MacOS/dotnet-new-macos             ← ✓ Native executable (from incremental build)
    MonoBundle/                        ← ✓ Runtime + managed assemblies
    _CodeSignature/                    ← ✓ Code signature
```

### Binlogs Exist For All 6 Configs

```
build/dotnet-new-macos_MONO_JIT_osx.binlog
build/dotnet-new-macos_MONO_AOT_osx.binlog
build/dotnet-new-macos_MONO_PAOT_osx.binlog
build/dotnet-new-macos_CORECLR_JIT_osx.binlog
build/dotnet-new-macos_R2R_COMP_osx.binlog
build/dotnet-new-macos_R2R_COMP_PGO_osx.binlog
```

All 6 builds were attempted by the measurement script.

### No macOS Results in results/

The `results/` directory contains iOS simulator CSVs but **zero** macOS results,
confirming that `measure_all.sh --platform osx` has never completed successfully.

---

## How `measure_all.sh` Routes to the osx Script

```
measure_all.sh
  line 67:   resolve_platform_config "$PLATFORM"   → PLATFORM_DEVICE_TYPE="osx"
  line 141:  elif [ "$PLATFORM_DEVICE_TYPE" = "osx" ]; then
  line 142:    OUTPUT=$("$SCRIPT_DIR/osx/measure_osx_startup.sh" "$app" "$config" \
                  --startup-iterations "$ITERATIONS" "${EXTRA_ARGS[@]}" 2>&1)
  line 151:  EXIT_CODE=$?
  line 176:  echo "❌ FAILED"     ← when EXIT_CODE != 0
  line 177:  echo "$OUTPUT" | tail -5
```

The routing is correct — `PLATFORM_DEVICE_TYPE="osx"` matches the `elif` at line 141.
The error is propagated from the child script's exit code.

---

## What's NOT the Issue

| Hypothesis | Status | Evidence |
|-----------|--------|----------|
| Script routing bug | ❌ Ruled out | `PLATFORM_DEVICE_TYPE="osx"` correctly routes to `osx/measure_osx_startup.sh` |
| TFM mismatch | ❌ Ruled out | csproj, init.sh, build-configs.props all use `net11.0-macos` |
| build-configs.props conflicts | ❌ Ruled out | All 4 platform configs imported unconditionally, but CLI `-f`/`-r` override TFM/RID; other properties are identical across platforms for same config |
| Workload not installed | ❌ Ruled out | `versions.log` shows `macos` workload `26.2.11310-net11-p1` |
| RID mismatch | ❌ Ruled out | `osx-arm64` consistent in init.sh, build-configs.props, CLI args |
| Argument parsing | ❌ Ruled out | `measure_all.sh` passes `"dotnet-new-macos" "CORECLR_JIT" --startup-iterations 10` correctly |
| .app search path | ❌ Ruled out | `find "$APP_DIR/bin" -type d -name "*.app"` correctly finds the bundle |
| `open` command failure | ❌ Ruled out | Script fails BEFORE reaching `open` — at the executable check (line 228) |

---

## Key Files

| File | Key Lines | Role |
|------|-----------|------|
| `osx/measure_osx_startup.sh` | **156** | **`rm -rf bin obj`** — the root cause |
| `osx/measure_osx_startup.sh` | 160-165 | Build command (`dotnet build`) |
| `osx/measure_osx_startup.sh` | 167-169 | Build exit code check |
| `osx/measure_osx_startup.sh` | **228-232** | **Executable existence check** — where failure is detected |
| `measure_all.sh` | 141-143 | osx routing to child script |
| `measure_all.sh` | 151-179 | Exit code check and failure reporting |
| `osx/build-configs.props` | 1-55 | 6 build configurations (all correct) |
| `apps/dotnet-new-macos/dotnet-new-macos.csproj` | 3 | TFM: `net11.0-macos` |
| `init.sh` | 75-83 | Platform config: TFM=`net11.0-macos`, RID=`osx-arm64` |
| `.dotnet/packs/.../Xamarin.Shared.Sdk.targets` | 238-266 | `CreateAppBundleDependsOn` chain |
| `.dotnet/packs/.../Xamarin.Shared.Sdk.targets` | 1056-1092 | `_LoadLinkerOutput` — reads linker items |
| `.dotnet/packs/.../Xamarin.Shared.Sdk.targets` | 1596-1609 | `_ComputeNativeExecutableInputs` |
| `.dotnet/packs/.../Xamarin.Shared.Sdk.targets` | 1631-1655 | `_CompileNativeExecutable` (clang) |
| `.dotnet/packs/.../Xamarin.Shared.Sdk.targets` | 1888-1920 | `_LinkNativeExecutable` (linker) |

---

## Environment

```
SDK: 11.0.100-preview.3.26123.103
macOS workload: 26.2.11310-net11-p1/11.0.100-preview.1
Xcode: /Applications/Xcode.app/Contents/Developer
Platform: macOS arm64
```
