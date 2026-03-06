# Apple Workload Installation Failures — Root Cause Analysis

## Problem Statement

`prepare.sh` fails for all 3 Apple platforms:
- `--platform ios` → Missing NuGet package `microsoft.ios.sdk.net10.0_26.2` version `26.2.10221`
- `--platform osx` → Workload ID `maui-macos` not recognized
- `--platform maccatalyst` → Missing NuGet package `microsoft.maccatalyst.sdk.net10.0_26.2` version `26.2.10221`
- `--platform android` → ✅ Works fine

---

## Architecture: How Workloads Get Installed

### prepare.sh Flow (lines 59–142)

1. Read SDK version from `global.json` → `11.0.100-preview.3.26123.103` (line 65)
2. Install SDK via `dotnet-install.sh` (line 96)
3. **OVERWRITE** `NuGet.config` by downloading from `dotnet/android` repo (line 111)
4. Set workload mode: `dotnet workload config --update-mode manifests` (line 118)
5. Optionally apply rollback: `dotnet workload update --from-rollback-file rollback.json` (line 121, only if `-userollback`)
6. Install platform workloads: `dotnet workload install $WORKLOADS` (line 138)

### Workload Resolution Chain

When `dotnet workload install ios` runs:
1. SDK looks for workload manifest packages on configured NuGet feeds for SDK band `11.0.100-preview.3`
2. Downloads manifest package (e.g., `microsoft.net.sdk.ios.manifest-11.0.100-preview.3`)
3. Manifest declares required NuGet packages (e.g., `microsoft.ios.sdk.net10.0_26.2` version `26.2.10221`)
4. SDK downloads those packages from configured feeds
5. **Failure occurs at step 4** — the referenced package version doesn't exist on any configured feed

---

## Root Causes (Ranked by Impact)

### Root Cause 1 — NuGet.config Overwrite Removes Required Feeds

**File:** `prepare.sh`, line 111
```bash
curl -L -o "$NUGET_CONFIG" https://raw.githubusercontent.com/dotnet/android/main/NuGet.config
```

**Impact:** HIGH — Affects iOS and maccatalyst directly

**Analysis:**
- This downloads the NuGet.config from `dotnet/android` main branch and **overwrites** the repo's committed `NuGet.config`
- The committed `NuGet.config` has these feeds (lines 15–20):
  - `dotnet-public` — stable .NET packages
  - `dotnet-eng` — engineering packages
  - `dotnet11` — .NET 11 preview packages
  - `dotnet11-transport` — .NET 11 transport/preview packages (workload packs published here)
  - `dotnet-tools` — tool packages
  - `darc-pub-dotnet-android-*` — Android-specific darc feed
- The `dotnet/android` NuGet.config has its own feed set, which includes Android-specific darc feeds but may not include `dotnet11-transport` or Apple-specific darc feeds
- Android works because `dotnet/android`'s NuGet.config naturally contains feeds for Android workload packages
- Apple platforms fail because their packages may only be on `dotnet11-transport` or Apple-specific darc feeds that aren't in dotnet/android's config

**Why this was added:** Originally designed for an Android-only repo. The dotnet/android NuGet.config ensures Android workload packages are always resolvable. But it's wrong for multi-platform use.

### Root Cause 2 — Invalid Workload ID `maui-macos`

**File:** `prepare.sh`, line 135
```bash
osx)          WORKLOADS="macos maui-macos" ;;
```

**Impact:** HIGH — Blocks macOS (osx) platform entirely

**Analysis:**
- `maui-macos` is **not a valid workload ID** in any .NET version
- MAUI supports macOS through **Mac Catalyst** (`maccatalyst`), not native macOS (AppKit)
- Valid MAUI workload IDs: `maui-android`, `maui-ios`, `maui-maccatalyst`, `maui-tizen`, `maui-windows`
- The `macos` workload ID is valid — it installs the native macOS (AppKit) workload
- For the `osx` platform, only `macos` should be installed (no MAUI workload for native macOS)
- This means: **MAUI apps cannot target `net11.0-macos` directly** — MAUI on Mac uses `net11.0-maccatalyst`

**Implication for generate-apps.sh:** Lines 189–191 generate a `dotnet-new-macos` app for the `osx` platform, which is correct (native macOS template). But lines 198–199 also generate MAUI apps for all platforms, and MAUI apps won't build for `net11.0-macos`. The `osx` platform's MAUI apps would need to target `net11.0-maccatalyst` instead, or be skipped.

**Cross-reference:** `measure_all.sh` line 89–90 lists `dotnet-new-macos`, `dotnet-new-maui`, `dotnet-new-maui-samplecontent` for osx. The MAUI apps won't build correctly for `net11.0-macos` TFM.

### Root Cause 3 — SDK Band vs Rollback Version Mismatch

**Files:** `global.json` line 3, `rollback.json` lines 1–9

| Component | Band |
|-----------|------|
| SDK (`global.json`) | `11.0.100-preview.3` |
| Rollback workloads (`rollback.json`) | `11.0.100-preview.1` |

**Impact:** MEDIUM — Only triggered when `-userollback` is passed

**Analysis:**
- Rollback pins all workloads to `11.0.100-preview.1` band
- SDK is in `11.0.100-preview.3` band
- Cross-band rollback can fail because the manifest packages for preview.1 band may reference packages not compatible with preview.3 SDK internals
- Currently, rollback is opt-in via `-userollback` flag, so this isn't the default failure path
- But if someone tries to use rollback to fix the workload issues, they'll hit this mismatch

### Root Cause 4 — Preview Package Availability Gap

**Impact:** MEDIUM — May persist even after fixing NuGet feeds

**Analysis:**
- The error references `microsoft.ios.sdk.net10.0_26.2` version `26.2.10221`
- The `net10.0` in the package name is not a mistake — it's the workload pack naming convention where the TFM bound version is encoded in the package name
- Version `26.2.10221` — the `10221` portion doesn't match the rollback's `11310` (different build numbers)
- Preview SDKs frequently have gaps where the workload manifest is published but the referenced packages aren't yet available on public feeds
- This is a timing/publishing pipeline issue that resolves when all packages are published

---

## Key Files Summary

| File | Key Lines | Role |
|------|-----------|------|
| `global.json` | 3 | SDK version: `11.0.100-preview.3.26123.103` |
| `rollback.json` | 1–9 | Workload pins at `11.0.100-preview.1` band |
| `NuGet.config` | 11–20 | Package feeds (dotnet11, dotnet11-transport, etc.) |
| `prepare.sh` | 111 | **Overwrites NuGet.config** from dotnet/android |
| `prepare.sh` | 118 | Sets manifest-based workload mode |
| `prepare.sh` | 129–136 | Platform-specific workload IDs |
| `prepare.sh` | 135 | **Invalid `maui-macos` workload ID** |
| `init.sh` | 28–98 | `resolve_platform_config()` — platform variables |

---

## Recommended Fixes

### Fix 1: Stop Overwriting NuGet.config (Critical)

**File:** `prepare.sh`, line 110–115

**Change:** Remove or conditionalize the NuGet.config download. The repo should maintain its own NuGet.config with all required feeds for all platforms.

```bash
# BEFORE (line 110-115):
# Download NuGet.config file from dotnet/android repo
curl -L -o "$NUGET_CONFIG" https://raw.githubusercontent.com/dotnet/android/main/NuGet.config

# AFTER: Remove these lines entirely. Use the committed NuGet.config as-is.
# The repo's NuGet.config already has the required feeds for all platforms.
```

**Rationale:** The committed `NuGet.config` already has `dotnet11` and `dotnet11-transport` feeds which should have workload packages for all platforms. Overwriting it with an Android-only config breaks Apple platforms.

### Fix 2: Fix macOS Workload ID (Critical)

**File:** `prepare.sh`, line 135

```bash
# BEFORE:
osx)          WORKLOADS="macos maui-macos" ;;

# AFTER:
osx)          WORKLOADS="macos" ;;
```

**Rationale:** `maui-macos` is not a valid workload ID. MAUI on Mac uses Mac Catalyst. The `osx` platform only needs the `macos` workload for native AppKit apps.

### Fix 3: Handle MAUI Apps for macOS Platform (Important)

**Files:** `generate-apps.sh` lines 197–199, `measure_all.sh` lines 89–90

MAUI apps can't target `net11.0-macos` — they target `net11.0-maccatalyst`. For the `osx` platform, either:
- **Option A:** Skip MAUI app generation for `osx` platform in `generate-apps.sh`
- **Option B:** Don't include MAUI apps in the `osx` app list in `measure_all.sh`

Currently `generate-apps.sh` generates MAUI apps for all platforms (line 198), and `measure_all.sh` includes them for `osx` (line 90). These will fail at build time with `net11.0-macos` TFM because MAUI templates don't support that TFM.

### Fix 4: Update rollback.json to Preview 3 Band (If Rollback Is Needed)

**File:** `rollback.json`

If deterministic builds via rollback are desired, update all band specifiers from `11.0.100-preview.1` to `11.0.100-preview.3` and use workload versions that are published for that band.

### Fix 5: Add Apple-Specific NuGet Feeds (If Needed)

**File:** `NuGet.config`

If the `dotnet11` and `dotnet11-transport` feeds don't have the Apple workload packages, add Apple-specific darc feeds:
- A `darc-pub-dotnet-ios-*` feed for iOS packages
- A `darc-pub-dotnet-macios-*` feed for all Apple platform packages
- These would be sourced from `dotnet/macios` repo (the unified iOS/macOS/maccatalyst SDK repo)

Note: The unified Apple SDK repo is `dotnet/macios` (not separate ios/macos repos).

---

## Risks and Caveats

1. **Preview SDK instability:** Even with all fixes, .NET 11 preview 3 packages may not be fully published. Consider pinning to a stable SDK or a known-good preview version.

2. **MAUI on macOS limitation:** MAUI does not support native macOS (AppKit). The `osx` platform is inherently limited to native `dotnet new macos` apps. MAUI apps for Mac must go through `maccatalyst`.

3. **NuGet.config drift:** Without the automatic download, the repo's `NuGet.config` must be manually maintained. When updating the SDK version, the feeds may need updating too.

4. **Workload ID changes between previews:** .NET preview versions occasionally rename or restructure workload IDs. The workload IDs should be verified against the actual SDK version.

5. **Apple package naming:** The `net10.0` in package names like `microsoft.ios.sdk.net10.0_26.2` is not a bug — it's the workload pack versioning convention. The TFM version in the package name may differ from the SDK major version.

---

## Verification Steps

After applying fixes, verify with:
```bash
# Each should complete workload installation without errors
./prepare.sh -f --platform ios
./prepare.sh -f --platform osx
./prepare.sh -f --platform maccatalyst

# Check installed workloads
.dotnet/dotnet workload list

# Check available workload IDs (to verify valid IDs)
.dotnet/dotnet workload search
```

## Related Research

- [Apple Platform Support](.github/researches/apple-platform-support.md) — Comprehensive platform analysis
- [Emulator/Simulator Support](.github/researches/emulator-simulator-support.md) — Device variant research
- [Performance Submodule Device Types](.github/researches/performance-submodule-device-types.md) — test.py capabilities
