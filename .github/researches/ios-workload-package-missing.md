# iOS Workload Package Missing — Manifest Feature Band Mismatch

## Problem Statement (Current — June 2025)

`prepare.sh --platform ios-simulator -f` fails because the rollback file
(`rollback.json`) specifies the wrong **feature band** for every manifest entry,
causing the SDK to search for NuGet packages that don't exist:

```
microsoft.net.sdk.ios.manifest-11.0.100-preview.3  version 26.2.11310-net11-p1
→ NOT FOUND on any configured NuGet feed
```

### Previous Issue (Resolved)

The earlier version of `prepare.sh` ran `workload install` without `--from-rollback-file`,
causing it to auto-resolve uncontrolled manifest versions whose packages weren't available.
This was fixed by always using the rollback file with platform-filtered entries
(`prepare.sh` lines 148–172).

---

## Architecture: How Feature Bands Work

In the .NET workload system, manifest packages are named:
```
{manifest-id}.manifest-{feature-band}
```

When `--from-rollback-file` is used, the SDK reads `"manifest-id": "version/feature-band"`
and constructs the package name from the feature band, then downloads that version from NuGet.

**The feature band is NOT the SDK's version band.** Different workload teams publish their
manifests under different feature bands. The SDK uses a fallback mechanism to find manifests
from earlier bands.

---

## Root Cause

**Every feature band in `rollback.json` was `11.0.100-preview.3`, but the actual NuGet
packages are published under different feature bands.**

### Evidence: SDK-Shipped Manifest Directories

From `.dotnet/sdk-manifests/` (installed by `dotnet-install.sh` for SDK `11.0.100-preview.3.26123.103`):

| Manifest | Feature Band Directory | Version |
|----------|----------------------|---------|
| `microsoft.net.sdk.android` | **`11.0.100-preview.1`** | `36.1.99-preview.1.119` |
| `microsoft.net.sdk.ios` | **`11.0.100-preview.1`** | `26.2.11310-net11-p1` |
| `microsoft.net.sdk.maccatalyst` | **`11.0.100-preview.1`** | `26.2.11310-net11-p1` |
| `microsoft.net.sdk.macos` | **`11.0.100-preview.1`** | `26.2.11310-net11-p1` |
| `microsoft.net.sdk.maui` | **`11.0.100-preview.1`** | `11.0.0-preview.1.26102.3` |
| `microsoft.net.sdk.tvos` | **`11.0.100-preview.1`** | `26.2.11310-net11-p1` |
| `mono.toolchain.current` | **`11.0.100`** | `11.0.100-preview.3.26123.103` |
| `mono.toolchain.net9` | **`11.0.100`** | `11.0.100-preview.3.26123.103` |

### What the Broken rollback.json Was Requesting

```
microsoft.net.sdk.ios.manifest-11.0.100-preview.3     → DOES NOT EXIST (band wrong)
microsoft.net.sdk.ios.manifest-11.0.100-preview.1     → EXISTS (correct band)
```

---

## Key Files

| File | Lines | Relevance |
|------|-------|-----------|
| `rollback.json` | 1–10 | **Fixed**: all entries now use correct feature bands |
| `prepare.sh` | 148–172 | Rollback filtering + `--from-rollback-file` install |
| `global.json` | 3 | SDK: `11.0.100-preview.3.26123.103` |
| `NuGet.config` | 15–20 | Configured feeds (dotnet-public, dotnet11, dotnet11-transport, etc.) |
| `.dotnet/sdk-manifests/` | — | Shipped manifests proving correct feature bands |

---

## Fix Applied

**File:** `rollback.json`

Changed all feature bands from `11.0.100-preview.3` to their correct values:

```json
{
    "microsoft.net.sdk.android": "36.1.99-preview.1.116/11.0.100-preview.1",
    "microsoft.net.sdk.ios": "26.2.11310-net11-p1/11.0.100-preview.1",
    "microsoft.net.sdk.maccatalyst": "26.2.11310-net11-p1/11.0.100-preview.1",
    "microsoft.net.sdk.macos": "26.2.11310-net11-p1/11.0.100-preview.1",
    "microsoft.net.sdk.maui": "11.0.0-preview.1.26102.3/11.0.100-preview.1",
    "microsoft.net.sdk.tvos": "26.2.11310-net11-p1/11.0.100-preview.1",
    "microsoft.net.workload.mono.toolchain.net9": "11.0.100-preview.1.26079.116/11.0.100",
    "microsoft.net.workload.mono.toolchain.current": "11.0.100-preview.1.26079.116/11.0.100"
}
```

Platform SDK manifests: `11.0.100-preview.3` → **`11.0.100-preview.1`**
Mono toolchain manifests: `11.0.100-preview.3` → **`11.0.100`**

---

## Risks & Notes

1. **Android version mismatch**: The rollback pins android to `36.1.99-preview.1.116` but the SDK
   ships `36.1.99-preview.1.119`. The rollback version is intentionally older (for reproducibility).
   This works IF version `.116` exists on the configured feeds (the `darc-pub-dotnet-android`
   feed at `NuGet.config` line 11 likely carries it).

2. **Mono toolchain versions**: The rollback pins to `11.0.100-preview.1.26079.116` but the SDK
   ships `11.0.100-preview.3.26123.103`. Again, intentional pinning — the older version must
   exist on `dotnet-public` or `dotnet11` feeds.

3. **Future SDK bumps**: When `global.json` is updated to a new SDK version, the rollback file
   must also be regenerated. The feature bands may change again if workload teams move to new bands.
   **Always check `.dotnet/sdk-manifests/` after installing a new SDK to find correct bands.**

4. **How to regenerate rollback.json**: Run `dotnet workload update` without a rollback file to
   get latest manifests, then `dotnet workload --info` to see installed versions, and map them
   to the correct feature bands from `sdk-manifests/` directory names.
