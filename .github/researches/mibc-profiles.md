# MIBC Profiles — NuGet Download Research

## ⚠️ Critical Finding: Wrong Feed in `download-mibc.sh`

**Root cause of failure:** The `download-mibc.sh` script (line 14) tries feeds `dotnet10` and
`dotnet-tools`, but **all optimization packages are published to `dotnet10-transport`**.

This was confirmed by examining every `.nupkg.metadata` file in the local NuGet cache
(`~/.nuget/packages/optimization.*/`). Every single optimization package — MIBC and PGO alike —
was downloaded from:

```
https://pkgs.dev.azure.com/dnceng/public/_packaging/dotnet10-transport/nuget/v3/index.json
```

The `dotnet/performance` submodule's `NuGet.config` (line 21) also includes this feed, confirming
it's the standard source.

### Current Script Feeds (WRONG)
```bash
# download-mibc.sh lines 13-16
DEFAULT_FEEDS=(
    "https://pkgs.dev.azure.com/dnceng/public/_packaging/dotnet10/nuget/v3/flat2"        # ❌ wrong
    "https://pkgs.dev.azure.com/dnceng/public/_packaging/dotnet-tools/nuget/v3/flat2"     # ❌ wrong
)
```

### Correct Feed
```bash
DEFAULT_FEEDS=(
    "https://pkgs.dev.azure.com/dnceng/public/_packaging/dotnet10-transport/nuget/v3/flat2"  # ✅ confirmed
    "https://pkgs.dev.azure.com/dnceng/public/_packaging/dotnet11-transport/nuget/v3/flat2"  # try also
    "https://pkgs.dev.azure.com/dnceng/public/_packaging/dotnet-tools/nuget/v3/flat2"        # fallback
)
```

### Why `dotnet10-transport` and not `dotnet11-transport`?

The repo's `global.json` targets .NET **11** SDK (`11.0.100-preview.3.26123.103`) and the main
`NuGet.config` has `dotnet11` / `dotnet11-transport` feeds. However, the `dotnet/runtime-optimization`
pipeline still publishes to `dotnet10-transport` even for .NET 11-era builds (version prefixes
`26xxx` confirm this — see Version Format Analysis below). The optimization pipeline hasn't migrated
to a `dotnet11-transport` feed yet.

**Corroborating evidence:**
- `external/performance/NuGet.config` (line 21) includes `dotnet10-transport`
- No `darc-pub-dotnet-runtime-optimization-*` feed entries exist anywhere in the repo
- `NuGet.config` (root) does NOT include `dotnet10-transport` — this is why the MAUI MSBuild-based
  `PackageDownload` approach wouldn't work without adding the feed, but `download-mibc.sh` uses
  direct `curl` calls to the flat container API so it doesn't need the feed in `NuGet.config`

---

## Action Required: Probe Apple Platform Package Existence

The following commands must be run to determine which MIBC packages exist for Apple platforms.
Only `optimization.android-x64.mibc.runtime` has been confirmed so far.

```bash
# Step 1: Verify the known-good package (should return JSON with versions array)
curl -sL "https://pkgs.dev.azure.com/dnceng/public/_packaging/dotnet10-transport/nuget/v3/flat2/optimization.android-x64.mibc.runtime/index.json" | python3 -m json.tool

# Step 2: Probe Android arm64 (physical device) — may not exist
curl -sI "https://pkgs.dev.azure.com/dnceng/public/_packaging/dotnet10-transport/nuget/v3/flat2/optimization.android-arm64.mibc.runtime/index.json"

# Step 3: Probe all Apple platforms on dotnet10-transport
curl -sI "https://pkgs.dev.azure.com/dnceng/public/_packaging/dotnet10-transport/nuget/v3/flat2/optimization.ios-arm64.mibc.runtime/index.json"
curl -sI "https://pkgs.dev.azure.com/dnceng/public/_packaging/dotnet10-transport/nuget/v3/flat2/optimization.iossimulator-arm64.mibc.runtime/index.json"
curl -sI "https://pkgs.dev.azure.com/dnceng/public/_packaging/dotnet10-transport/nuget/v3/flat2/optimization.maccatalyst-arm64.mibc.runtime/index.json"
curl -sI "https://pkgs.dev.azure.com/dnceng/public/_packaging/dotnet10-transport/nuget/v3/flat2/optimization.osx-arm64.mibc.runtime/index.json"
curl -sI "https://pkgs.dev.azure.com/dnceng/public/_packaging/dotnet10-transport/nuget/v3/flat2/optimization.osx-x64.mibc.runtime/index.json"

# Step 4: Also try dotnet11-transport (in case optimization migrated)
curl -sI "https://pkgs.dev.azure.com/dnceng/public/_packaging/dotnet11-transport/nuget/v3/flat2/optimization.android-x64.mibc.runtime/index.json"
curl -sI "https://pkgs.dev.azure.com/dnceng/public/_packaging/dotnet11-transport/nuget/v3/flat2/optimization.ios-arm64.mibc.runtime/index.json"

# Step 5: Search for ALL optimization packages on the feed
curl -sL "https://pkgs.dev.azure.com/dnceng/public/_packaging/dotnet10-transport/nuget/v3/search?q=optimization&prerelease=true&take=100" \
  | python3 -c "import sys,json; data=json.load(sys.stdin); [print(p['id']) for p in data.get('data',[])]"

# Step 6: Check if darc CLI is available for channel inspection
which darc 2>/dev/null || dotnet tool list -g 2>/dev/null | grep -i darc
# If available:
#   darc get-channels | grep -i optim
#   darc get-default-channels --source-repo dotnet/runtime-optimization
```

**Expected outcomes:**
- HTTP 200 = package exists (follow up with full GET to see versions)
- HTTP 404 = package does not exist on that feed
- HTTP 401/403 = feed requires authentication (unlikely for `public` feeds)

---

## Architecture

MIBC (Managed Image Based Compilation) profiles contain method-level execution data collected from representative workloads. They guide crossgen2's ReadyToRun compilation to prioritize hot methods, producing PGO-optimized native images.

The profiles are published as NuGet packages on public Azure Artifacts feeds. The MAUI repo has a reference implementation for downloading and using these profiles at `dotnet/maui/eng/optimizationData.targets` (net11.0 branch).

### Two Sourcing Approaches

| Approach | Mechanism | Auth Required | Used By |
|----------|-----------|--------------|---------|
| **NuGet packages** (recommended) | Public Azure Artifacts feeds, NuGet V3 API | No | MAUI `optimizationData.targets` |
| **Azure DevOps pipeline artifacts** | `dotnet-optimization` pipeline, Maestro channel 5172 | Yes (Azure AD) | Internal tooling |

This research focuses on the **NuGet package** approach since it requires no authentication.

---

## Key Files

### This Repository

| File | Lines | Purpose |
|------|-------|---------|
| `download-mibc.sh` | 13-16 | **BUG:** Default feeds list uses wrong feeds (`dotnet10`, `dotnet-tools`) |
| `download-mibc.sh` | 96 | Package ID construction: `optimization.${RID}.MIBC.Runtime` |
| `generate-apps.sh` | 111-114 | Creates `profiles/` dir per app, copies `.mibc` files from `$SCRIPT_DIR/profiles/` |
| `generate-apps.sh` | 147-168 | Patches csproj with `_ReadyToRunPgoFiles` and `_MauiUseDefaultReadyToRunPgoFiles` |
| `NuGet.config` | 17-18 | `dotnet11` and `dotnet11-transport` feeds (**not** `dotnet10-transport`!) |
| `NuGet.config` | 20 | `dotnet-tools` feed |
| `external/performance/NuGet.config` | 21 | **Has** `dotnet10-transport` — the correct feed |
| `.gitignore` | 68-70 | `profiles/`, `profiles-old/`, `profiles-new/` are gitignored |
| `init.sh` | 10 | `LOCAL_PACKAGES="$SCRIPT_DIR/packages"` — NuGet restore cache |
| `Directory.Build.props` | 3 | `RestorePackagesPath` set to `./packages` |

### .NET SDK (installed at `.dotnet/sdk/...`)

| File | Lines | Purpose |
|------|-------|---------|
| `Microsoft.NET.CrossGen.targets` | 425 | Populates `_ReadyToRunPgoFiles` from `@(PublishReadyToRunPgoFiles)` |
| `Microsoft.NET.CrossGen.targets` | 426-427 | Also includes runtime pack `.mibc` assets when `PublishReadyToRunUseRuntimePackOptimizationData=true` |
| `Microsoft.NET.CrossGen.targets` | 492 | Passes `_ReadyToRunPgoFiles` as `Crossgen2PgoFiles` to `RunReadyToRunCompiler` |

### MAUI Reference (`dotnet/maui/eng/optimizationData.targets`)

The MAUI repo's optimization data targets (net11.0 branch) follow this pattern:

```xml
<Project>
  <!-- Version is typically managed by Maestro/Dependency Flow -->
  <PropertyGroup>
    <OptimizationDataVersion>1.0.0-prerelease.YY.NNNNN.N</OptimizationDataVersion>
  </PropertyGroup>

  <!-- Download packages during NuGet restore (not PackageReference — PackageDownload) -->
  <ItemGroup>
    <PackageDownload Include="optimization.android-arm64.MIBC.Runtime"
                     Version="[$(OptimizationDataVersion)]" />
    <PackageDownload Include="optimization.ios-arm64.MIBC.Runtime"
                     Version="[$(OptimizationDataVersion)]" />
    <PackageDownload Include="optimization.maccatalyst-arm64.MIBC.Runtime"
                     Version="[$(OptimizationDataVersion)]" />
    <!-- Desktop platforms also included -->
  </ItemGroup>

  <!-- Reference MIBC files from NuGet package cache -->
  <ItemGroup Condition="'$(RuntimeIdentifier)' == 'ios-arm64'">
    <_ReadyToRunPgoFiles Include="$(NuGetPackageRoot)optimization.ios-arm64.mibc.runtime/$(OptimizationDataVersion)/data/**/*.mibc" />
  </ItemGroup>
  <!-- Similar for other RIDs -->
</Project>
```

**Key observations:**
- Uses `<PackageDownload>` (not `<PackageReference>`) — downloads the nupkg but doesn't add assembly references
- The `Version` uses bracket syntax `[x.y.z]` to pin to exact version
- MIBC files are in the `data/` directory inside the nupkg
- The NuGet package cache path uses the **lowercased** package ID (NuGet convention)
- **IMPORTANT**: The MAUI targets reference these packages but MAUI's NuGet.config includes
  `dotnet10-transport` where they're actually published

---

## Confirmed Package Availability (from local NuGet cache)

### Packages confirmed to exist on `dotnet10-transport`

Verified by examining `~/.nuget/packages/optimization.*/` directories and their `.nupkg.metadata`
files. Every package source field shows `dotnet10-transport`.

| Package ID | Versions in Cache | Source Feed | MIBC Files |
|-----------|-------------------|-------------|------------|
| `optimization.android-x64.MIBC.Runtime` | `1.0.0-prerelease.26080.1`, `1.0.0-prerelease.26113.1` | `dotnet10-transport` ✅ | `DotNet_Maui_Android.mibc`, `DotNet_Maui_Blazor_Android.mibc`, `DotNet_Maui_Android_SampleContent.mibc` |
| `optimization.linux-x64.MIBC.Runtime` | `1.0.0-prerelease.25502.1`, `1.0.0-prerelease.26080.1` | `dotnet10-transport` ✅ | `DotNet_FSharp.mibc`, `DotNet_TechEmpower.mibc`, `DotNet_HelloWorld.mibc`, `DotNet_OrchardCore.mibc`, `DotNet_FirstTimeXP.mibc`, `DotNet_Adhoc.mibc` |
| `optimization.linux-arm64.MIBC.Runtime` | `1.0.0-prerelease.25502.1` | `dotnet10-transport` ✅ | Same server scenarios as linux-x64 |
| `optimization.linux-x64.PGO.CoreCLR` | `1.0.0-prerelease.25502.1`, `1.0.0-prerelease.26080.1` | `dotnet10-transport` ✅ | `coreclr.profdata` |
| `optimization.linux-arm64.PGO.CoreCLR` | `1.0.0-prerelease.25502.1`, `1.0.0-prerelease.26080.1` | `dotnet10-transport` ✅ | `coreclr.profdata` |
| `optimization.windows_nt-x64.PGO.CoreCLR` | `1.0.0-prerelease.25502.1`, `1.0.0-prerelease.26080.1` | `dotnet10-transport` ✅ | `coreclr.pgd`, `clrjit.pgd` |
| `optimization.windows_nt-x86.PGO.CoreCLR` | `1.0.0-prerelease.25502.1`, `1.0.0-prerelease.26080.1` | `dotnet10-transport` ✅ | `coreclr.pgd`, `clrjit.pgd` |
| `optimization.windows_nt-arm64.PGO.CoreCLR` | `1.0.0-prerelease.25502.1`, `1.0.0-prerelease.26080.1` | `dotnet10-transport` ✅ | `coreclr.pgd`, `clrjit.pgd` |

### Packages NOT found in local NuGet cache

These have never been successfully downloaded to this machine:

| Expected Package ID | Status | Notes |
|---------------------|--------|-------|
| `optimization.android-arm64.MIBC.Runtime` | ❌ Not in cache | Only `android-x64` exists (emulator training only) |
| `optimization.ios-arm64.MIBC.Runtime` | ❌ Not in cache | May not exist yet or may be on a different feed |
| `optimization.maccatalyst-arm64.MIBC.Runtime` | ❌ Not in cache | May not exist yet |
| `optimization.osx-arm64.MIBC.Runtime` | ❌ Not in cache | May not exist yet |
| `optimization.iossimulator-arm64.MIBC.Runtime` | ❌ Not in cache | Likely does not exist |

> **Important nuance**: The `android-x64` package description says "IBC counts for x64 Runtime
> on **Android emulator**." This means MIBC training is done on the x64 emulator, not on physical
> arm64 devices. The same pattern may apply to iOS — training might happen on the arm64 simulator
> under a different package name, or may not exist yet.

### Version Format Analysis

```
1.0.0-prerelease.YYWWW.N
                  │││  │
                  ││└──┘ build number within week
                  │└──── week number (3 digits)
                  └───── 2-digit year
```

- `25502.1` → 2025, week 50, build 2, revision 1 (dotnet 10 era)
- `26080.1` → 2026, week 08, build 0, revision 1 (dotnet 11 era)
- `26113.1` → 2026, week 11, build 3, revision 1 (dotnet 11 era, latest)

Packages with `26xxx` prefixes are from the .NET 11 development cycle but still published
to `dotnet10-transport` (the optimization pipeline hasn't moved to `dotnet11-transport` yet).

---

## Patterns

### NuGet Package Naming Convention

```
optimization.<rid>.MIBC.Runtime
```

Where `<rid>` is the .NET Runtime Identifier in lowercase. Known packages:

| Platform | RID | Package ID | Exists? |
|----------|-----|-----------|---------|
| Android x64 emulator | `android-x64` | `optimization.android-x64.MIBC.Runtime` | ✅ Confirmed |
| Android arm64 device | `android-arm64` | `optimization.android-arm64.MIBC.Runtime` | ⚠️ Not in cache — probe feed |
| iOS device | `ios-arm64` | `optimization.ios-arm64.MIBC.Runtime` | ⚠️ Not in cache — probe feed |
| iOS simulator | `iossimulator-arm64` | `optimization.iossimulator-arm64.MIBC.Runtime` | ⚠️ Not in cache — probe feed |
| macOS | `osx-arm64` | `optimization.osx-arm64.MIBC.Runtime` | ⚠️ Not in cache — probe feed |
| Mac Catalyst | `maccatalyst-arm64` | `optimization.maccatalyst-arm64.MIBC.Runtime` | ⚠️ Not in cache — probe feed |

### NuGet V3 API for Azure Artifacts

Azure Artifacts NuGet feeds support the V3 flat container protocol:

**1. Service Index** (entry point):
```
GET https://pkgs.dev.azure.com/dnceng/public/_packaging/{feed}/nuget/v3/index.json
```
Returns JSON with `resources` array. Look for `@type: "PackageBaseAddress/3.0.0"` to get the flat container base URL.

**2. List All Versions** (flat container):
```
GET {baseUrl}/{lowercased-id}/index.json
```
For the **correct** `dotnet10-transport` feed:
```
GET https://pkgs.dev.azure.com/dnceng/public/_packaging/dotnet10-transport/nuget/v3/flat2/optimization.android-x64.mibc.runtime/index.json
```
Returns:
```json
{
  "versions": ["1.0.0-prerelease.26080.1", "1.0.0-prerelease.26113.1", ...]
}
```

**3. Download Package**:
```
GET {baseUrl}/{lowercased-id}/{version}/{lowercased-id}.{version}.nupkg
```

**Important:** The flat container path uses **lowercased** package IDs in the URL.

### Package Internal Structure

A `.nupkg` is a ZIP file. The MIBC profiles are in the `data/` directory:

```
optimization.android-x64.mibc.runtime.1.0.0-prerelease.26113.1.nupkg
├── .nupkg.metadata
├── optimization.android-x64.mibc.runtime.nuspec
└── data/
    ├── DotNet_Maui_Android.mibc
    ├── DotNet_Maui_Blazor_Android.mibc
    └── DotNet_Maui_Android_SampleContent.mibc
```

Extract with: `unzip -j -o package.nupkg 'data/*.mibc' -d profiles/`

### NuGet Feeds — Correct Feed Identification

| Feed Key | Flat Container Base URL | Has MIBC Packages? | Evidence |
|----------|------------------------|-------------------|----------|
| **`dotnet10-transport`** | `https://pkgs.dev.azure.com/dnceng/public/_packaging/dotnet10-transport/nuget/v3/flat2` | **YES ✅** | Every `.nupkg.metadata` in `~/.nuget/packages/optimization.*/` shows this source |
| `dotnet10` | `.../dotnet10/.../flat2` | **No** ❌ | `download-mibc.sh` tried this, got 404 |
| `dotnet-tools` | `.../dotnet-tools/.../flat2` | **No** ❌ | `download-mibc.sh` tried this, got 404 |
| `dotnet11-transport` | `.../dotnet11-transport/.../flat2` | **Unknown** | Not tried yet — worth probing |
| `dotnet-public` | `.../dotnet-public/.../flat2` | **Unknown** | May have promoted packages |

> **The `dotnet10-transport` feed is NOT in the repo's `NuGet.config`** but IS in
> `external/performance/NuGet.config` (line 21). This is a secondary issue — the `download-mibc.sh`
> script uses direct `curl` calls to the flat container API, so it doesn't use `NuGet.config` feeds.
> But the feed URL in the script itself must be corrected.

---

## Required Fix for `download-mibc.sh`

### Change 1: Update DEFAULT_FEEDS (line 13-16)

```bash
# BEFORE (wrong):
DEFAULT_FEEDS=(
    "https://pkgs.dev.azure.com/dnceng/public/_packaging/dotnet10/nuget/v3/flat2"
    "https://pkgs.dev.azure.com/dnceng/public/_packaging/dotnet-tools/nuget/v3/flat2"
)

# AFTER (correct):
DEFAULT_FEEDS=(
    "https://pkgs.dev.azure.com/dnceng/public/_packaging/dotnet10-transport/nuget/v3/flat2"
    "https://pkgs.dev.azure.com/dnceng/public/_packaging/dotnet11-transport/nuget/v3/flat2"
    "https://pkgs.dev.azure.com/dnceng/public/_packaging/dotnet-tools/nuget/v3/flat2"
)
```

### Change 2: Update help text (line 32)

Update the `--feed` description to mention `dotnet10-transport` as the default.

---

## Verification Commands

Run these to probe whether iOS/macOS/maccatalyst packages exist:

```bash
# CONFIRMED WORKING (android-x64 on dotnet10-transport):
curl -sL "https://pkgs.dev.azure.com/dnceng/public/_packaging/dotnet10-transport/nuget/v3/flat2/optimization.android-x64.mibc.runtime/index.json" | python3 -m json.tool

# PROBE THESE (iOS/macOS — may or may not exist):
curl -sL "https://pkgs.dev.azure.com/dnceng/public/_packaging/dotnet10-transport/nuget/v3/flat2/optimization.ios-arm64.mibc.runtime/index.json"
curl -sL "https://pkgs.dev.azure.com/dnceng/public/_packaging/dotnet10-transport/nuget/v3/flat2/optimization.android-arm64.mibc.runtime/index.json"
curl -sL "https://pkgs.dev.azure.com/dnceng/public/_packaging/dotnet10-transport/nuget/v3/flat2/optimization.maccatalyst-arm64.mibc.runtime/index.json"
curl -sL "https://pkgs.dev.azure.com/dnceng/public/_packaging/dotnet10-transport/nuget/v3/flat2/optimization.osx-arm64.mibc.runtime/index.json"

# ALSO TRY dotnet11-transport:
curl -sL "https://pkgs.dev.azure.com/dnceng/public/_packaging/dotnet11-transport/nuget/v3/flat2/optimization.ios-arm64.mibc.runtime/index.json"
curl -sL "https://pkgs.dev.azure.com/dnceng/public/_packaging/dotnet11-transport/nuget/v3/flat2/optimization.android-arm64.mibc.runtime/index.json"

# BROADER SEARCH (find all optimization packages on the feed):
curl -sL "https://pkgs.dev.azure.com/dnceng/public/_packaging/dotnet10-transport/nuget/v3/search?q=optimization.MIBC&prerelease=true" | python3 -m json.tool
curl -sL "https://pkgs.dev.azure.com/dnceng/public/_packaging/dotnet10-transport/nuget/v3/search?q=optimization&prerelease=true" | python3 -m json.tool
```

---

## Dependencies

### Shell Script Approach (Recommended for This Repo)

The repo's existing tooling is shell-based (`prepare.sh`, `build.sh`, `generate-apps.sh`). A download script should follow the same pattern:

**Required tools:**
- `curl` — HTTP requests to NuGet API
- `python3` — JSON parsing (already a prerequisite, used in `prepare.sh` line 86)
- `unzip` — extract `.nupkg` (available on macOS/Linux by default)

### How `generate-apps.sh` Already Consumes Profiles

From `generate-apps.sh` lines 111-168:
1. `patch_app()` creates `profiles/` directory in each app (line 112)
2. Copies `$SCRIPT_DIR/profiles/*.mibc` to app's `profiles/` dir (lines 113-115)
3. For MAUI apps: sets `_MauiUseDefaultReadyToRunPgoFiles=false` and adds `_ReadyToRunPgoFiles` item (lines 147-157)
4. For non-MAUI apps: adds `_ReadyToRunPgoFiles` item and sets `--partial` crossgen2 flag (lines 160-169)

**This means once `.mibc` files are in `profiles/`, the existing flow picks them up automatically.** The download script just needs to populate `profiles/`.

---

## MSBuild Properties for MIBC Usage

| Property/Item | Purpose | Where Set |
|--------------|---------|-----------|
| `_ReadyToRunPgoFiles` | Item group of `.mibc` files passed to crossgen2 | SDK `CrossGen.targets:425`, app csproj patches |
| `PublishReadyToRunPgoFiles` | User-facing item group (feeds `_ReadyToRunPgoFiles`) | User csproj or build props |
| `PublishReadyToRunUseRuntimePackOptimizationData` | Include `.mibc` from runtime packs | SDK `CrossGen.targets:427` |
| `PublishReadyToRunCrossgen2ExtraArgs` | Extra args like `--partial` | `generate-apps.sh` line 167 |
| `_MauiUseDefaultReadyToRunPgoFiles` | When `false`, MAUI skips its built-in profiles | `generate-apps.sh` line 153 |
| `_MauiPublishReadyToRunPartial` | Controls MAUI's `--partial` behavior | `build-configs.props` (R2R_COMP configs) |
| `PGO` | Custom property; when `true`, activates PGO profile loading | `build-configs.props` (R2R_COMP_PGO config) |

### How Profiles Flow to crossgen2

```
profiles/*.mibc
  ↓ (copied by generate-apps.sh)
<app>/profiles/*.mibc
  ↓ (included by csproj patch)
_ReadyToRunPgoFiles MSBuild item
  ↓ (SDK CrossGen.targets line 492)
RunReadyToRunCompiler.Crossgen2PgoFiles
  ↓
crossgen2 --mibc <file1> --mibc <file2> ...
```

---

## Risks

| Risk | Severity | Mitigation |
|------|----------|------------|
| iOS/macOS MIBC packages may not exist yet on any public feed | **High** | The NuGet cache shows zero iOS/macOS/maccatalyst MIBC packages have ever been downloaded. Must probe `dotnet10-transport` and `dotnet11-transport` to confirm. Script already handles 404 gracefully (exit 0 with warning). |
| `android-arm64` MIBC package may not exist (only `android-x64` confirmed) | **Medium** | The android-x64 nuspec says "Android emulator" — training may only run on emulators. For arm64 device benchmarks, x64 emulator profiles may be a reasonable approximation. |
| Package version churn — latest version may not match SDK version | Medium | Accept optional `--version` parameter. Default to latest. Log the version used. |
| `iossimulator-arm64` profiles likely don't exist | Medium | Map simulator RIDs to device RIDs for profile download. |
| Feed URL changes across .NET versions | Low | Multi-feed fallback with `dotnet10-transport` → `dotnet11-transport` → `dotnet-tools`. |
| `data/` directory path may vary across package versions | Low | Use `unzip -l` to list contents before extracting; glob `*.mibc` across all directories. |

---

## Platform ↔ RID ↔ Package Mapping

Derived from `init.sh` `resolve_platform_config()` (lines 28-98) and build-configs:

| Platform Value | PLATFORM_RID | MIBC Package ID | Confirmed? |
|----------------|-------------|-----------------|------------|
| `android` | `android-arm64` | `optimization.android-arm64.MIBC.Runtime` | ⚠️ Not confirmed — only `android-x64` in cache |
| `android-emulator` (x64 host) | `android-x64` | `optimization.android-x64.MIBC.Runtime` | ✅ Confirmed on `dotnet10-transport` |
| `android-emulator` (arm64 host) | `android-arm64` | `optimization.android-arm64.MIBC.Runtime` | ⚠️ Not confirmed |
| `ios` | `ios-arm64` | `optimization.ios-arm64.MIBC.Runtime` | ❌ Not in cache — probe feed |
| `ios-simulator` | `iossimulator-arm64` | Use `ios-arm64` profiles | ❌ Not in cache |
| `osx` | `osx-arm64` | `optimization.osx-arm64.MIBC.Runtime` | ❌ Not in cache — probe feed |
| `maccatalyst` | `maccatalyst-arm64` | `optimization.maccatalyst-arm64.MIBC.Runtime` | ❌ Not in cache — probe feed |

---

## Previous Research (Preserved)

### Azure DevOps Pipeline Approach (Alternative)

MIBC profiles are also produced by the `dotnet-optimization` pipeline in Azure DevOps (`dnceng/internal`).

- **Maestro channel**: [Channel 5172](https://maestro.dot.net/channel/5172/azdo:dnceng:internal:dotnet-optimization/build/latest)
- **Pipeline**: `dotnet-optimization` in `dnceng/internal/_git/dotnet-optimization`
- **Artifact naming**: `CLRx64LIN-x64ANDmasIBC_CLRx64LIN-x64AND` (Android example)
- **Requires**: Azure AD token (`az account get-access-token`)

This approach requires internal Azure DevOps access and is not suitable for public/unauthenticated use.

### Android Profile Details

- Training flow: EventPipe trace → `dotnet-pgo create-mibc` (per trace) → `dotnet-pgo merge` (per scenario)
- `--include-reference` whitelist filter during merge controls which assemblies survive
- Known issue: MAUI/AndroidX/Google assemblies were filtered out (fixed in dotnet-optimization PR #58455)

### Existing Profile Usage Infrastructure

- Profiles stored in `profiles/` (gitignored — `.gitignore` line 68)
- `generate-apps.sh` copies `profiles/*.mibc` into each app's `profiles/` directory during generation
- App csproj patches include `<_ReadyToRunPgoFiles Include="profiles/*.mibc" />` for R2R_COMP_PGO builds
- MAUI apps override `_MauiUseDefaultReadyToRunPgoFiles=false` to use custom profiles instead of MAUI defaults
- The `--partial` crossgen2 flag is critical when profiles don't cover all methods
