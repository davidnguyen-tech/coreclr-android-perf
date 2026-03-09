# MIBC Download Script — Implementation Research

Research for implementing Step 7 from `plan.md`: the `download-mibc.sh` script.

---

## Architecture

MIBC (Managed Image Based Compilation) profiles contain method-level execution data that guide crossgen2's ReadyToRun compilation for PGO-optimized native images. The profiles flow through the system as:

```
download-mibc.sh → profiles/*.mibc
  ↓ (copied by generate-apps.sh lines 112-115)
<app>/profiles/*.mibc
  ↓ (included by csproj patch, generate-apps.sh lines 147-168)
_ReadyToRunPgoFiles MSBuild item
  ↓ (SDK CrossGen.targets line 492)
RunReadyToRunCompiler.Crossgen2PgoFiles
  ↓
crossgen2 --mibc <file1> --mibc <file2> ...
```

The `R2R_COMP_PGO` build config in each platform's `build-configs.props` sets `<PGO>True</PGO>`, which activates the MIBC profile loading in the csproj patches.

---

## What Step 7 Requires (from `plan.md` lines 922–1186)

### Goal
Create `download-mibc.sh` that downloads MIBC profiles from public Azure Artifacts NuGet feeds into `profiles/`. These are consumed by `R2R_COMP_PGO` builds.

### Sub-steps

| Sub-step | Description | Status |
|----------|-------------|--------|
| **7.1.1** | Script skeleton, arg parsing, platform resolution, RID fallback, package ID construction | ✅ Already implemented |
| **7.1.2** | Version query logic (NuGet V3 flat container API, HTTP handling, python3 parsing) | ✅ Already implemented |
| **7.1.3** | Download nupkg, extract `data/*.mibc`, validate extraction, cleanup | ✅ Already implemented |
| **7.1.4** | Logging, `versions.log` integration, list extracted files | ✅ Already implemented |
| **7.1.5** | `--help` flag with usage text | ✅ Already implemented |

### Interface
```
./download-mibc.sh [--platform <platform>] [--version <version>] [--feed <url>] [--help]
```

### Acceptance Criteria (plan.md lines 1114–1121)
- `./download-mibc.sh --platform ios` downloads profiles or warns gracefully
- `./download-mibc.sh --platform android --version X.Y.Z` downloads specific version
- `./download-mibc.sh --platform ios-simulator` falls back to `ios-arm64` with notice
- `./download-mibc.sh --help` prints usage
- Invalid `--version` prints available versions and exits 1
- Script is executable
- No authentication required

---

## What Already Exists

### `download-mibc.sh` (234 lines, fully implemented)

The script already exists at repo root and implements **all** plan requirements. Key sections:

| Section | Lines | Description |
|---------|-------|-------------|
| Shebang + header | 1-9 | `set -euo pipefail`, script/profiles dir variables |
| NuGet feed URLs | 11-17 | `DEFAULT_FEEDS` array with `dotnet10-transport` and `dotnet-tools` |
| Arg parsing | 19-72 | `--platform`, `--version`, `--feed`, `--help` with validation |
| Platform→RID mapping | 74-94 | Inline case statement (NOT using `init.sh`'s `resolve_platform_config()`) |
| Package ID | 96-97 | `optimization.${RID}.MIBC.Runtime`, lowercased for URLs |
| Temp cleanup | 103-111 | `trap cleanup EXIT` with `mktemp` |
| Feed discovery | 115-153 | Multi-feed iteration with HTTP status checking |
| Version resolution | 162-186 | Latest (last element) or user-specified with validation |
| Download + extract | 190-228 | `curl -sfL`, `unzip -j -o`, post-extraction validation |
| Logging | 230-234 | `versions.log` append |

### `profiles/` Directory

- Contains one file: `DotNet_Maui_Android.mibc`
- Listed in `.gitignore` (line 68): `profiles/` is gitignored
- This existing file was likely manually placed or downloaded previously

### `generate-apps.sh` (lines 101-177) — Profile Consumer

The `patch_app()` function:
1. Creates `profiles/` directory in each app (line 112)
2. Copies `$SCRIPT_DIR/profiles/*.mibc` to app's `profiles/` dir (lines 113-115)
3. For MAUI apps: sets `_MauiUseDefaultReadyToRunPgoFiles=false`, adds `_ReadyToRunPgoFiles` (lines 147-157)
4. For non-MAUI apps: adds `_ReadyToRunPgoFiles` and sets `--partial` crossgen2 flag (lines 160-169)

**Once `.mibc` files are in `profiles/`, the existing flow picks them up automatically.**

---

## Known Bug: Wrong Feed URL

### Current State (download-mibc.sh lines 13-16)
```bash
DEFAULT_FEEDS=(
    "https://pkgs.dev.azure.com/dnceng/public/_packaging/dotnet10-transport/nuget/v3/flat2"
    "https://pkgs.dev.azure.com/dnceng/public/_packaging/dotnet-tools/nuget/v3/flat2"
)
```

### Research Finding (mibc-profiles.md lines 1-50)
The `dotnet10-transport` feed is **correct** — confirmed via `.nupkg.metadata` files in local NuGet cache. Every optimization package was downloaded from this feed. The current script already has the fix applied (the research doc describes a prior bug that has been corrected).

However, the research also suggests adding `dotnet11-transport` as a fallback:
```bash
DEFAULT_FEEDS=(
    "https://pkgs.dev.azure.com/dnceng/public/_packaging/dotnet10-transport/nuget/v3/flat2"  # ✅ confirmed
    "https://pkgs.dev.azure.com/dnceng/public/_packaging/dotnet11-transport/nuget/v3/flat2"  # worth trying
    "https://pkgs.dev.azure.com/dnceng/public/_packaging/dotnet-tools/nuget/v3/flat2"        # fallback
)
```

---

## How MIBC Profiles Are Consumed

### MSBuild Properties (from mibc-profiles.md lines 388-399)

| Property/Item | Purpose | Where Set |
|--------------|---------|-----------|
| `PGO` | Custom flag, `true` for R2R_COMP_PGO config | `*/build-configs.props` |
| `_ReadyToRunPgoFiles` | `.mibc` files passed to crossgen2 | App csproj patches (generate-apps.sh) |
| `_MauiUseDefaultReadyToRunPgoFiles` | When `false`, MAUI skips built-in profiles | App csproj patches |
| `PublishReadyToRunCrossgen2ExtraArgs` | `--partial` flag | App csproj patches |
| `_MauiPublishReadyToRunPartial` | Controls MAUI's `--partial` behavior | `build-configs.props` |

### Build Configs With PGO

All four platforms define `R2R_COMP_PGO` with `<PGO>True</PGO>`:

| Platform | File | Config Line | RID |
|----------|------|-------------|-----|
| Android | `android/build-configs.props:63-74` | `R2R_COMP_PGO` | `android-arm64` |
| iOS | `ios/build-configs.props:45-54` | `R2R_COMP_PGO` | `ios-arm64` |
| macOS | `osx/build-configs.props:23-33` | `R2R_COMP_PGO` | `osx-arm64` |
| Mac Catalyst | `maccatalyst/build-configs.props:45-55` | `R2R_COMP_PGO` | `maccatalyst-arm64` |

---

## NuGet Package Source & RID Mapping

### Package Naming Convention
```
optimization.<rid>.MIBC.Runtime
```
All lowercase in NuGet flat container URLs.

### Confirmed Package Availability (from mibc-profiles.md lines 177-210)

| Platform | RID | Package ID | Confirmed? |
|----------|-----|-----------|------------|
| Android emulator | `android-x64` | `optimization.android-x64.MIBC.Runtime` | ✅ On `dotnet10-transport` |
| Android device | `android-arm64` | `optimization.android-arm64.MIBC.Runtime` | ⚠️ Not confirmed |
| iOS device | `ios-arm64` | `optimization.ios-arm64.MIBC.Runtime` | ❌ Not confirmed |
| iOS simulator | `iossimulator-arm64` | N/A — falls back to `ios-arm64` | N/A |
| macOS | `osx-arm64` | `optimization.osx-arm64.MIBC.Runtime` | ❌ Not confirmed |
| Mac Catalyst | `maccatalyst-arm64` | `optimization.maccatalyst-arm64.MIBC.Runtime` | ❌ Not confirmed |

### RID Fallback Mapping (download-mibc.sh lines 77-93)

The existing script maps platforms to RIDs inline:

| Platform arg | Download RID | Note |
|-------------|-------------|------|
| `android` | `android-x64` | ⚠️ Uses x64 (emulator-trained), not arm64 |
| `android-emulator` | `android-x64` | With notice |
| `ios` | `ios-arm64` | Primary target |
| `ios-simulator` | `ios-arm64` | With notice |
| `maccatalyst` | `maccatalyst-arm64` | Primary target |
| `osx` | `osx-arm64` | Primary target |

**Discrepancy vs plan.md**: The plan (line 952) says to use `init.sh`'s `resolve_platform_config()` for RID resolution. The actual script uses its own inline `case` statement (lines 77-93). This is a **deliberate design choice** — the script maps `android` to `android-x64` (the known-available emulator package), whereas `init.sh` maps `android` to `android-arm64` (the physical device RID). The script's mapping is optimized for MIBC package availability, not runtime targeting.

---

## Dependencies

### Tool Prerequisites
- `curl` — HTTP requests (standard on macOS/Linux)
- `python3` — JSON parsing (validated in `prepare.sh` line 70-71, used in `generate-apps.sh` lines 74, 123)
- `unzip` — extract `.nupkg` ZIP files (standard on macOS/Linux)
- `mktemp` — temp file creation (standard)

### No `init.sh` Dependency
The existing script does NOT `source init.sh`. It has its own standalone RID mapping. This makes the script self-contained — it can run without any prior setup.

---

## Gaps Between Plan and Implementation

### Already Implemented (No Gaps)

1. ✅ Script skeleton with `set -euo pipefail` (7.1.1)
2. ✅ Arg parsing: `--platform`, `--version`, `--feed`, `--help` (7.1.1, 7.1.5)
3. ✅ Platform→RID mapping with simulator/emulator fallback (7.1.1)
4. ✅ Package ID construction with lowercase normalization (7.1.1)
5. ✅ Multi-feed iteration with HTTP status handling (7.1.2)
6. ✅ Version query — latest or user-specified with validation (7.1.2)
7. ✅ Download with `curl -sfL`, extract with `unzip -j -o` (7.1.3)
8. ✅ Post-extraction validation (count `.mibc` files) (7.1.3)
9. ✅ Temp file cleanup via `trap` with `mktemp` (7.1.3)
10. ✅ Console output at each stage (7.1.4)
11. ✅ `versions.log` append (7.1.4)
12. ✅ List extracted files (7.1.4)
13. ✅ `--help` with usage text (7.1.5)
14. ✅ Graceful 404 handling — warns and exits 0 (7.1.2)

### Minor Deviations from Plan (Not Bugs)

| Plan Says | Implementation Does | Assessment |
|-----------|-------------------|------------|
| Source `init.sh` for `resolve_platform_config()` | Standalone case statement | **Better** — script is self-contained, RIDs optimized for package availability |
| Fixed `/tmp/mibc-*` temp paths | `mktemp` with trap cleanup | **Better** — avoids collision risk (plan's own risk table acknowledges this) |
| Single feed (`dotnet-tools`) | Multi-feed iteration with `--feed` override | **Better** — more resilient |
| `--platform` and `--version` only | Also has `--feed` flag | **Better** — useful for testing/debugging |

---

## Risks

| Risk | Severity | Mitigation |
|------|----------|------------|
| Apple platform MIBC packages don't exist yet | **High** | Script already handles 404 gracefully (exit 0). `--partial` crossgen2 flag ensures R2R_COMP_PGO builds succeed without PGO data. |
| `android` maps to `android-x64` (emulator) not `android-arm64` (device) | **Medium** | This is intentional — `android-x64` is the only confirmed available package. The emulator-trained profiles are a reasonable approximation for device. |
| Feed may need `dotnet11-transport` in the future | **Low** | Multi-feed fallback already in place. Easy to add new feed URL. |
| `data/` directory path inside nupkg may change | **Low** | Post-extraction validation catches zero-file case with clear warning. |

---

## Conclusion

**The `download-mibc.sh` script is fully implemented.** All sub-steps from plan.md (7.1.1 through 7.1.5) are covered. The implementation is actually more robust than the plan specified:
- Multi-feed iteration instead of single feed
- `mktemp` + `trap` instead of fixed temp paths
- `--feed` override flag for flexibility
- Self-contained RID mapping optimized for package availability

**The remaining work for Step 7 is verification/testing**, not implementation:
1. Run `./download-mibc.sh --platform android` to verify download works
2. Run `./download-mibc.sh --platform ios` to test Apple platform handling (likely 404 → graceful exit)
3. Run the end-to-end flow: download → `generate-apps.sh` → `build.sh` with R2R_COMP_PGO
4. Verify the `dotnet10-transport` feed URL is correct and accessible

The only potential improvement is adding `dotnet11-transport` as a second feed in the DEFAULT_FEEDS array, in case the optimization pipeline migrates feeds in the future.
