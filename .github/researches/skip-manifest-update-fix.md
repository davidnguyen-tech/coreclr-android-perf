# Skip Manifest Update Fix — Replacing rollback.json

## Problem

`prepare.sh --platform ios-simulator -f` failed because the `rollback.json` file pinned
workload manifests to versions that don't exist on the configured NuGet feeds:

| Manifest | rollback.json version | SDK-bundled version | Match? |
|---|---|---|---|
| `mono.toolchain.net9` | `11.0.100-preview.1.26079.116` | `11.0.100-preview.3.26123.103` | ❌ |
| `mono.toolchain.current` | `11.0.100-preview.1.26079.116` | `11.0.100-preview.3.26123.103` | ❌ |
| `sdk.android` | `36.1.99-preview.1.116` | `36.1.99-preview.1.119` | ❌ |
| `sdk.ios` | `26.2.11310-net11-p1` | `26.2.11310-net11-p1` | ✅ |
| `sdk.maccatalyst` | `26.2.11310-net11-p1` | `26.2.11310-net11-p1` | ✅ |
| `sdk.macos` | `26.2.11310-net11-p1` | `26.2.11310-net11-p1` | ✅ |

### History of rollback.json Issues

1. **First failure** (researched in `apple-workload-failures.md`): Feature bands in rollback.json
   were `11.0.100-preview.1` but SDK is `11.0.100-preview.3`.
2. **Second failure** (researched in `ios-workload-package-missing.md`): Feature bands were fixed
   but versions pointed to wrong preview era packages that don't exist on feeds.
3. **Third failure** (researched in `rollback-json-cross-platform-failure.md`): Cross-platform
   entries caused failures when installing single-platform workloads. Fixed with filtering.
4. **Current failure**: Even after filtering, the mono toolchain version
   `11.0.100-preview.1.26079.116` doesn't exist on any feed. The version was from a previous
   SDK era and was never updated when `global.json` moved to preview.3.

## Root Cause

The `rollback.json` approach is fundamentally fragile:
- Requires manually keeping versions in sync with the SDK
- Different manifests use different feature bands (`11.0.100` for mono toolchain,
  `11.0.100-preview.1` for platform SDKs)
- Versions must exist on the configured NuGet feeds
- Cross-platform entries cause collateral failures

## Solution: `--skip-manifest-update`

**File:** `prepare.sh`, line 151

Replace `--from-rollback-file` with `--skip-manifest-update`:

```bash
"$LOCAL_DOTNET" workload install $WORKLOADS --skip-manifest-update
```

### How It Works

The .NET SDK ships with pre-bundled workload manifests in `sdk-manifests/`:

```
.dotnet/sdk-manifests/
├── 11.0.100/                          # Feature band for runtime manifests
│   ├── microsoft.net.workload.mono.toolchain.current/11.0.100-preview.3.26123.103/
│   ├── microsoft.net.workload.mono.toolchain.net9/11.0.100-preview.3.26123.103/
│   └── ...
└── 11.0.100-preview.1/               # Feature band for platform SDK manifests
    ├── microsoft.net.sdk.ios/26.2.11310-net11-p1/
    ├── microsoft.net.sdk.android/36.1.99-preview.1.119/
    ├── microsoft.net.sdk.maccatalyst/26.2.11310-net11-p1/
    ├── microsoft.net.sdk.macos/26.2.11310-net11-p1/
    └── microsoft.net.sdk.maui/11.0.0-preview.1.26102.3/
```

`--skip-manifest-update` tells `dotnet workload install` to:
1. **NOT** download manifest packages from NuGet
2. Use the manifests already on disk (bundled with the SDK)
3. Only download the actual workload **packs** referenced by those manifests

### Advantages Over rollback.json

| Aspect | rollback.json | --skip-manifest-update |
|---|---|---|
| Version maintenance | Manual — must update on every SDK bump | Automatic — SDK ships matching versions |
| Feature band tracking | Must know which bands each manifest uses | Not needed |
| Cross-platform issues | Filtered workaround needed | Not applicable |
| Feed availability | Versions must exist on NuGet feeds | Not needed for manifests |
| Code complexity | 20+ lines of Python filtering | Single flag |

## Key Files Changed

| File | Lines | Change |
|---|---|---|
| `prepare.sh` | 147–151 | Replaced rollback filtering + `--from-rollback-file` with `--skip-manifest-update` |
| `README.md` | 131–137 | Updated "Workload Version Pinning" section |
| `README.md` | 475 | Removed `rollback.json` from project structure listing |

## Risks

1. **Version drift**: If the SDK-bundled manifests reference packs not yet published to NuGet,
   the install could fail. This is unlikely for released SDKs but possible for daily builds.
   Mitigation: the SDK team tests this as part of their CI.

2. **rollback.json still exists**: The file remains in the repo but is no longer used by
   `prepare.sh`. It could be deleted or kept for reference. No functional impact either way.

3. **`workload config --update-mode manifests`** (line 134): This line remains and is compatible.
   It sets the update _mode_ (loose manifests vs workload sets), which is orthogonal to
   whether manifests are _downloaded_. No conflict.
