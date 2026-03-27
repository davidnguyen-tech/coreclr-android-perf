# Rollback JSON Cross-Platform Manifest Resolution Failure

## Problem Statement

`prepare.sh --platform ios-simulator -f` fails because `dotnet workload install ios maui-ios --from-rollback-file rollback.json` tries to resolve **ALL 8 manifest entries** in `rollback.json`, not just the iOS-related ones. The Android manifest version `36.1.99-preview.1.116` isn't available on the configured feeds, causing the entire install to fail even though only iOS workloads were requested.

---

## Architecture: How `--from-rollback-file` Works

### The Rollback File Behavior

When `dotnet workload install` receives `--from-rollback-file`, the SDK:
1. Reads ALL entries from the rollback JSON
2. Attempts to download and install manifest packages for EVERY entry
3. Only then installs the requested workloads using those manifests

This is **by design** — the rollback file is a "whole-machine state" snapshot. The SDK treats it as authoritative for the entire workload state, not just the workloads being installed.

### Current `rollback.json` (all 8 entries)

**File:** `rollback.json`, lines 1–9

```json
{
    "microsoft.net.sdk.android": "36.1.99-preview.1.116/11.0.100-preview.3",
    "microsoft.net.sdk.ios": "26.2.11310-net11-p1/11.0.100-preview.3",
    "microsoft.net.sdk.maccatalyst": "26.2.11310-net11-p1/11.0.100-preview.3",
    "microsoft.net.sdk.macos": "26.2.11310-net11-p1/11.0.100-preview.3",
    "microsoft.net.sdk.maui": "11.0.0-preview.1.26102.3/11.0.100-preview.3",
    "microsoft.net.sdk.tvos": "26.2.11310-net11-p1/11.0.100-preview.3",
    "microsoft.net.workload.mono.toolchain.net9": "11.0.100-preview.1.26079.116/11.0.100-preview.3",
    "microsoft.net.workload.mono.toolchain.current": "11.0.100-preview.1.26079.116/11.0.100-preview.3"
}
```

### The Failing Command

**File:** `prepare.sh`, line 146

```bash
"$LOCAL_DOTNET" workload install $WORKLOADS --from-rollback-file "$SCRIPT_DIR/rollback.json"
```

For `ios-simulator`, `$WORKLOADS` = `"ios maui-ios"`, but ALL 8 manifest entries are resolved.

### Why Android's Entry Fails

The Android manifest `36.1.99-preview.1.116` in band `11.0.100-preview.3` requires the NuGet package `Microsoft.NET.Sdk.Android.Manifest-11.0.100-preview.3` at version `36.1.99-preview.1.116`. This package may only be available on the Android-specific DARC feed (`darc-pub-dotnet-android-350a375f-1` in NuGet.config line 11), but the manifest resolution for `workload install` may use a different lookup path that doesn't check all NuGet sources, or the package simply isn't published to that feed yet.

---

## How dotnet/performance Handles This

**File:** `external/performance/src/scenarios/shared/mauisharedpython.py`

### Approach 1: `install_versioned_maui()` (lines 102–117)
- Downloads MAUI's NuGet.config from GitHub: `--configfile MauiNuGet.config`
- Generates a rollback file dynamically from MAUI's `Version.Details.xml`
- Installs the `maui` workload (which pulls ALL platforms)
- This works because `maui` NEEDS all platform manifests, and MAUI's NuGet.config has all the right feeds

### Approach 2: `install_latest_maui()` (lines 301–431)
- Queries feeds directly to find latest manifest versions
- Builds a rollback dict with entries for android, ios, maccatalyst, macos, maui, tvos
- Also installs the full `maui` workload

**Key insight**: Both approaches install `maui` (all platforms), so having all manifests in the rollback is correct. Our case is different — we install platform-specific workloads (`ios maui-ios`), so we only need platform-specific manifests.

---

## Alternatives Considered

### 1. Skip rollback file entirely (`--skip-manifest-update`)
- **Problem**: Without rollback, the auto-resolved manifest version `26.2.10221` isn't on the feeds either (documented in `ios-workload-package-missing.md`)
- **Verdict**: Won't work — this was the original failure mode before rollback was added

### 2. Install without rollback but add right NuGet feed sources
- **Problem**: We'd need to know which specific DARC feeds carry the auto-resolved versions
- **Problem**: Makes versions non-deterministic across runs
- **Verdict**: Fragile and non-reproducible

### 3. Add `dotnet10-transport` feed to NuGet.config
- **Problem**: The package `microsoft.ios.sdk.net10.0_26.2` at version `26.2.10221` may not be on that feed either
- **Verdict**: Speculative fix — may not resolve the issue

### 4. Download MAUI's NuGet.config (like dotnet/performance does)
- **Problem**: Overwrites our feed configuration; was the original root cause documented in `apple-workload-failures.md` Fix 1
- **Verdict**: Could work if used with `--configfile` flag instead of overwriting, but adds complexity

### 5. **Filter rollback.json to only include platform-relevant manifests** ✅
- Uses python3 (already a prerequisite, line 70–73 of prepare.sh)
- Generates a filtered rollback file in `$BUILD_DIR` at install time
- Each platform only resolves the manifests it actually needs
- Maintains deterministic version pinning
- **Verdict**: Minimal, clean, correct

---

## Root Cause Summary

| Factor | Detail |
|--------|--------|
| **Immediate cause** | Android manifest `36.1.99-preview.1.116` not resolvable on configured feeds |
| **Design flaw** | `--from-rollback-file` resolves ALL entries, not just requested workloads |
| **Why iOS is affected** | The single `rollback.json` has cross-platform entries; Android failure blocks iOS install |

---

## Fix: Platform-Filtered Rollback File

**File:** `prepare.sh`, lines 136–146

### Manifest Requirements Per Platform

| Platform | Required Manifests |
|----------|--------------------|
| `android` / `android-emulator` | `android`, `maui`, `mono.toolchain` |
| `ios` / `ios-simulator` | `ios`, `maui`, `mono.toolchain` |
| `osx` | `macos`, `mono.toolchain` |
| `maccatalyst` | `maccatalyst`, `maui`, `mono.toolchain` |

### Change

Before the `dotnet workload install` call, generate a filtered rollback file:

```bash
# Generate platform-filtered rollback file to avoid resolving unrelated manifests
FILTERED_ROLLBACK="$BUILD_DIR/rollback-filtered.json"
case "$PLATFORM" in
    android|android-emulator)  MANIFEST_FILTER="android|maui|mono\.toolchain" ;;
    ios|ios-simulator)         MANIFEST_FILTER="ios|maui|mono\.toolchain" ;;
    osx)                       MANIFEST_FILTER="macos|mono\.toolchain" ;;
    maccatalyst)               MANIFEST_FILTER="maccatalyst|maui|mono\.toolchain" ;;
esac
python3 -c "
import json, re, sys
with open(sys.argv[1]) as f:
    data = json.load(f)
filtered = {k: v for k, v in data.items() if re.search(sys.argv[2], k)}
with open(sys.argv[3], 'w') as f:
    json.dump(filtered, f, indent=4)
" "$SCRIPT_DIR/rollback.json" "$MANIFEST_FILTER" "$FILTERED_ROLLBACK"
echo "Filtered rollback for $PLATFORM:"
cat "$FILTERED_ROLLBACK"

"$LOCAL_DOTNET" workload install $WORKLOADS --from-rollback-file "$FILTERED_ROLLBACK"
```

### Expected filtered output for `ios-simulator`:

```json
{
    "microsoft.net.sdk.ios": "26.2.11310-net11-p1/11.0.100-preview.3",
    "microsoft.net.sdk.maui": "11.0.0-preview.1.26102.3/11.0.100-preview.3",
    "microsoft.net.workload.mono.toolchain.net9": "11.0.100-preview.1.26079.116/11.0.100-preview.3",
    "microsoft.net.workload.mono.toolchain.current": "11.0.100-preview.1.26079.116/11.0.100-preview.3"
}
```

This excludes `android`, `maccatalyst`, `macos`, and `tvos` — none of which are needed for iOS.

---

## Key Files

| File | Lines | Relevance |
|------|-------|-----------|
| `rollback.json` | 1–9 | All 8 manifest entries (cross-platform) |
| `prepare.sh` | 146 | `dotnet workload install` with unfiltered rollback |
| `prepare.sh` | 70–73 | python3 prerequisite check (reusable for filtering) |
| `NuGet.config` | 11 | Android DARC feed — may not have `36.1.99-preview.1.116` |
| `NuGet.config` | 17–18 | `dotnet11` / `dotnet11-transport` — main preview feeds |
| `external/performance/.../mauisharedpython.py` | 102–117 | Reference: how dotnet/performance does rollback + configfile |

---

## Risks

1. **Manifest interdependencies**: If a workload like `maui-ios` transitively depends on manifests NOT in our filter (unlikely but possible), the filtered rollback would fail. Mitigation: the filter includes `maui` and `mono.toolchain` which are the known transitive dependencies.

2. **Rollback file maintenance**: The master `rollback.json` still needs all entries for all platforms. The filtering is only at install time. When updating rollback.json, all platform versions must be correct even if they're not all installed together.

3. **Future manifest additions**: If new manifest entries are added (e.g., a new toolchain), the filter patterns would need updating. The regex-based approach (`mono\.toolchain`) handles variations like `net9` and `current`.
