# Custom App Measurement Support — Research

Research for Task 3: Support measuring custom apps by users, either by adding source code to `apps/` or by pointing to a pre-built `.apk`/`.app`.

---

## Architecture — Current App Lifecycle

### Stage 1: Generation (`generate-apps.sh`)

**Entry point:** `generate-apps.sh --platform <platform>`  
**Called from:** `prepare.sh` line 196

The script creates apps via `dotnet new` templates and places them under `apps/<app-name>/`:

```
apps/
├── dotnet-new-android/
│   ├── dotnet-new-android.csproj
│   ├── profiles/           ← copied from repo root profiles/
│   └── ...                 ← template-generated files
├── dotnet-new-ios/
├── dotnet-new-macos/
├── dotnet-new-maui/
└── dotnet-new-maui-samplecontent/
```

**Key behaviors:**
- **App name = directory name = csproj name** — enforced by `dotnet new -n <name> -o <dir>` (`generate-apps.sh` line 65)
- Assembly name guard: rejects names starting with `Microsoft.`, `System.`, `Mono.`, `Xamarin.` (line 46-53)
- MAUI apps: TargetFrameworks restricted to the selected platform's TFM only (line 74-93)
- Patching: `patch_app()` injects profiling/PGO MSBuild snippets into the csproj's `</Project>` tag (line 101-176)
  - Android-only: `<AndroidEnvironment>` includes for profiling/nettrace
  - MAUI: Overrides default PGO profiles with custom ones
  - Non-MAUI: Adds `--partial` crossgen2 flag and MIBC profile include
- `profiles/` directory created under each app, with shared `.mibc` files copied from `$SCRIPT_DIR/profiles/` (line 112-115)
- **Idempotent:** skips generation if `$app_dir` already exists (line 55-58)

**Platform-to-template mapping** (lines 182-201):
| Platform | Template apps | MAUI apps |
|---|---|---|
| `android`, `android-emulator` | `dotnet new android` → `dotnet-new-android` | `dotnet-new-maui`, `dotnet-new-maui-samplecontent` |
| `ios`, `ios-simulator` | `dotnet new ios` → `dotnet-new-ios` | `dotnet-new-maui`, `dotnet-new-maui-samplecontent` |
| `osx` | `dotnet new macos` → `dotnet-new-macos` | _(none — MAUI needs maccatalyst)_ |
| `maccatalyst` | _(none — no standalone template)_ | `dotnet-new-maui`, `dotnet-new-maui-samplecontent` |

### Stage 2: Build (`build.sh` / `measure_startup.sh`)

**Key command** (`build.sh` line 94-95, `measure_startup.sh` line 103-106):
```bash
${LOCAL_DOTNET} build -c Release -f "$PLATFORM_TFM" -r "$PLATFORM_RID" \
    -bl:"$logfile" "$APP_DIR/$SAMPLE_APP.csproj" -p:_BuildConfig=$BUILD_CONFIG
```

**Critical assumptions:**
1. **App directory = `apps/$SAMPLE_APP`** (`build.sh` line 63, `measure_startup.sh` line 81)
2. **Csproj filename = `$SAMPLE_APP.csproj`** (`build.sh` line 95, `measure_startup.sh` line 105)
3. **Build config properties come from `_BuildConfig`** → resolved by `<platform>/build-configs.props` via `Directory.Build.props`
4. **`Directory.Build.props` and `Directory.Build.targets` apply automatically** because apps live under the repo root
5. **Package artifact location**: found by globbing `$APP_DIR` for `$PLATFORM_PACKAGE_GLOB` under `*/Release/*` (`measure_startup.sh` line 114)

**Build output directory structure** (Android example):
```
apps/dotnet-new-android/bin/Release/net11.0-android/android-arm64/
└── com.companyname.dotnet_new_android-Signed.apk
```

**Build output directory structure** (iOS example):
```
apps/dotnet-new-ios/bin/Release/net11.0-ios/ios-arm64/
└── dotnet-new-ios.app/        ← directory bundle
```

**`build.sh` additionally:** copies `bin/` and `obj/` to `$BUILD_DIR/<app>_<timestamp>/` for archival (line 97-100).

### Stage 3: Package Discovery

**`measure_startup.sh` line 114:**
```bash
PACKAGE_PATH=$(find "$APP_DIR" -name "$PLATFORM_PACKAGE_GLOB" -path "*/Release/*" | head -1)
```

**`PLATFORM_PACKAGE_GLOB` values** (from `init.sh`):
| Platform | Glob | Type |
|---|---|---|
| Android | `*-Signed.apk` | Single file |
| iOS, osx, maccatalyst | `*.app` | Directory bundle |

**Package size measurement** (`measure_startup.sh` lines 120-134):
- `.app` bundles (directories): `du -sk` for total size
- `.apk` files: `stat -f%z`

### Stage 4: Package Name / Bundle ID Resolution

**`measure_startup.sh` lines 91-95:**
```bash
PACKAGE_NAME=$(grep -o '<ApplicationId>[^<]*' "$APP_DIR/$SAMPLE_APP.csproj" | sed 's/<ApplicationId>//')
if [ -z "$PACKAGE_NAME" ]; then
    PACKAGE_NAME="com.companyname.$(echo "$SAMPLE_APP" | tr '-' '_')"
fi
```

**`ios/measure_simulator_startup.sh` lines 308-321:** Reads `CFBundleIdentifier` from the built `.app/Info.plist`, falling back to `<ApplicationId>` from csproj, then to `com.companyname.<name>`.

**Key takeaway:** Bundle ID is derived from the csproj or the built artifact. Pre-built apps won't have a csproj to query.

### Stage 5: Measurement (`measure_startup.sh`)

**Test.py invocation** (`measure_startup.sh` lines 158-162):
```bash
python3 test.py devicestartup \
    --device-type "$PLATFORM_DEVICE_TYPE" \
    --package-path "$PACKAGE_PATH" \
    --package-name "$PACKAGE_NAME" \
    "$@"
```

Requires: `--package-path` (path to `.apk`/`.app`), `--package-name` (Android package name or iOS bundle ID), `--device-type` (`android` or `ios`).

**iOS simulator** (`ios/measure_simulator_startup.sh`): Bypasses `test.py`, uses `xcrun simctl install/launch/terminate/uninstall` directly. Requires `.app` bundle path and bundle ID.

### Stage 6: App Discovery by `measure_all.sh`

**Hardcoded app lists** (`measure_all.sh` lines 82-95):
```bash
case "$PLATFORM" in
    android|android-emulator)
        APPS=("dotnet-new-android" "dotnet-new-maui" "dotnet-new-maui-samplecontent")
        ;;
    ios|ios-simulator)
        APPS=("dotnet-new-ios" "dotnet-new-maui" "dotnet-new-maui-samplecontent")
        ;;
    osx)
        APPS=("dotnet-new-macos")
        ;;
    maccatalyst)
        APPS=("dotnet-new-maui" "dotnet-new-maui-samplecontent")
        ;;
esac
```

**Override mechanism:** `--app <name>` flag (can be repeated) overrides the default list (line 98-100). This already supports custom app names — the user just needs to know the app directory name.

### MSBuild Configuration Inheritance

**`Directory.Build.props`** (repo root, lines 1-15):
- Sets `RestorePackagesPath` to local `packages/` directory
- Imports all `<platform>/build-configs.props` files (conditionally, if they exist)

**`Directory.Build.targets`** (repo root, lines 1-10):
- Imports all `<platform>/build-workarounds.targets` files (conditionally, if they exist)

**How it affects apps:** Any project under the repo root automatically inherits these files via MSBuild's `Directory.Build.props/targets` walk-up behavior. Apps in `apps/` are children of the repo root, so they get all platform build configs and workarounds automatically.

**Implication for custom apps:** A custom app placed in `apps/<name>/` would automatically inherit these configs. This is **desired** — the build configs are what make `_BuildConfig` work.

---

## Design Options

### Option A: Source-Based Custom Apps

Users place their app source code in `apps/<app-name>/`, structured the same way as generated apps. The existing `build.sh` and `measure_startup.sh` scripts work unchanged.

#### Requirements

1. **Directory structure:** `apps/<app-name>/<app-name>.csproj` (matches the `$APP_DIR/$SAMPLE_APP.csproj` pattern)
2. **MSBuild compatibility:** The csproj must be compatible with `_BuildConfig`-driven builds (it inherits `Directory.Build.props/targets` automatically)
3. **Bundle ID resolvable:** Either from `<ApplicationId>` in csproj, or from built `Info.plist`
4. **Platform TFM compatibility:** The csproj must target the appropriate TFM (`net11.0-android`, `net11.0-ios`, etc.)
5. **No name collisions:** App name must not conflict with framework assembly names (same guard as `generate-apps.sh` line 46-53)

#### Workflow

```bash
# 1. User places their app
cp -r ~/my-app apps/my-custom-app
# Ensure: apps/my-custom-app/my-custom-app.csproj exists

# 2. Build and measure (existing scripts, no changes)
./build.sh --platform ios my-custom-app CORECLR_JIT build 1
./measure_startup.sh my-custom-app CORECLR_JIT --platform ios

# 3. Or measure all configs
./measure_all.sh --platform ios --app my-custom-app
```

#### What Already Works

- `build.sh` already accepts any app name from `apps/` (line 63-67)
- `measure_startup.sh` already accepts any app name from `apps/` (line 81-85)
- `measure_all.sh` already has `--app <name>` for custom app selection (lines 40-44)
- `clean.sh` already works on any app in `apps/` (line 24)
- `Directory.Build.props/targets` automatically apply to any project under repo root
- Package discovery (`find ... -name "$PLATFORM_PACKAGE_GLOB"`) works on any app

#### What Needs Adding

1. **Validation script or docs** — Ensure the csproj filename matches the directory name
2. **PGO/profiling patch opt-in** — Custom apps won't have the profiling patches from `patch_app()` unless they add them manually or we provide a patch script
3. **`generate-apps.sh` awareness** — Currently skips existing directories (line 55-58), so custom apps won't be overwritten. But `prepare.sh` wipes `$APPS_DIR` entirely on reset (line 85) — **this would delete custom apps**
4. **`measure_all.sh` discovery** — Custom apps aren't in the hardcoded default lists. Users must use `--app <name>`. Alternatively, add an auto-discovery mode.

#### Critical Risk: `prepare.sh` wipes `apps/`

**`prepare.sh` line 85:**
```bash
rm -rf "$APPS_DIR"
```

This deletes the entire `apps/` directory on environment reset (`-f` flag). Custom app source code placed there would be lost. This is the **biggest architectural problem** for source-based custom apps.

**Mitigations:**
- **Option A1: Separate directory** — Custom apps live in a tracked `custom-apps/` directory (not gitignored). Symlink or copy them into `apps/` at build time. `prepare.sh` only wipes generated apps.
- **Option A2: Preserve custom apps** — Modify `prepare.sh` to only delete generated apps (ones matching known template names), not the entire `apps/` directory.
- **Option A3: Manifest file** — Custom apps are registered in a `custom-apps.json` manifest and copied/symlinked into `apps/` by a script.

**Recommended: Option A1 (separate directory)** — Cleanest separation, no risk of `prepare.sh` destroying user data, and the tracked directory can hold documentation/examples.

### Option B: Pre-Built Binary Measurement

Users provide an already-built `.apk` or `.app` bundle and measure it directly without building from source.

#### What the Measurement Pipeline Needs

| Data | Source for generated apps | Needed for pre-built |
|---|---|---|
| Package path (`.apk`/`.app`) | `find` in `$APP_DIR` | User provides directly |
| Package name / Bundle ID | Parsed from csproj or Info.plist | User provides, or extracted from Info.plist/AndroidManifest.xml |
| Device type | From `--platform` flag | Same |
| Package glob | From platform config | Not needed (path is explicit) |

#### Workflow Options

**B1: Direct `measure_startup.sh` with `--package-path` and `--package-name` flags:**

```bash
# Skip build, just measure
./measure_startup.sh --prebuilt \
    --package-path ~/builds/MyApp-Signed.apk \
    --package-name com.example.myapp \
    --platform android
```

This would bypass the build stage entirely and jump straight to measurement. The script already passes `--package-path` and `--package-name` to `test.py` (line 158-162).

**B2: Dedicated `measure_prebuilt.sh` script:**

A standalone script that only handles measurement of pre-built binaries, without any build logic. Simpler and avoids cluttering `measure_startup.sh`.

**B3: Drop pre-built binaries into a known location:**

```bash
# Place the pre-built app
mkdir -p prebuilt/my-app
cp ~/builds/MyApp-Signed.apk prebuilt/my-app/

# Register metadata
echo '{"package_name": "com.example.myapp", "platform": "android"}' > prebuilt/my-app/manifest.json

# Measure
./measure_startup.sh my-app PREBUILT --platform android
```

**Recommended: Option B1** — Minimal change to `measure_startup.sh` (add `--prebuilt --package-path --package-name` flags that skip the build stage). For `measure_all.sh`, pre-built apps don't fit the "build all configs" pattern since they're already built with a specific config.

#### Bundle ID Extraction

For pre-built apps where the user doesn't provide `--package-name`:

- **Android:** `aapt2 dump badging <file.apk> | grep package:\ name=` — extracts from AndroidManifest.xml inside APK
- **iOS/macOS:** `/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" <app>/Info.plist` — reads from Info.plist inside .app bundle (already used in `ios/measure_simulator_startup.sh` line 311)

Auto-extraction is feasible for both platforms, reducing the need for the user to manually provide `--package-name`.

### Option C: Hybrid — Support Both Source and Pre-Built

This is the most flexible approach and aligns with the task description ("either by adding source code ... or pointing to an already-built .apk or .app").

**Design:**

1. **Source-based:** `custom-apps/` directory (tracked, not gitignored) holds custom app source code. A `register-custom-apps.sh` script symlinks or copies them into `apps/` and applies profiling patches.

2. **Pre-built:** `measure_startup.sh` gains `--prebuilt --package-path <path> [--package-name <name>]` flags. When `--prebuilt` is used, the build stage is skipped, and the package path/name are taken directly from flags. Bundle ID auto-extraction as a fallback.

---

## Recommended Approach

### For Source-Based Custom Apps

1. **Create a `custom-apps/` directory** (tracked in git, not gitignored) for user app source code
2. **Add a `register-custom-apps.sh` script** that:
   - Scans `custom-apps/` for subdirectories containing a `.csproj`
   - Validates: directory name matches csproj name, name doesn't collide with framework assemblies
   - Symlinks (or copies) each into `apps/` if not already present
   - Optionally applies profiling/PGO patches via `patch_app()` from `generate-apps.sh`
3. **Modify `prepare.sh`** to call `register-custom-apps.sh` after `generate-apps.sh` (so custom apps are re-linked after environment reset)
4. **Add auto-discovery to `measure_all.sh`** — an `--all-apps` flag or `--app custom` that discovers all apps in `apps/` instead of using the hardcoded list
5. **Document** the expected structure, naming convention, and platform compatibility requirements

**Alternatively (simpler):** Don't create a separate directory. Just document that users can place source apps directly in `apps/` with the correct naming convention, and rely on the idempotent guard in `generate-apps.sh` (which skips existing directories). The risk is `prepare.sh -f` wiping them — mitigate by changing `prepare.sh` to only delete known generated app directories instead of `rm -rf $APPS_DIR`.

### For Pre-Built Binary Measurement

1. **Add flags to `measure_startup.sh`:**
   - `--prebuilt` — Skip build, use existing binary
   - `--package-path <path>` — Path to `.apk`/`.app` (required with `--prebuilt`)
   - `--package-name <name>` — Bundle ID / package name (optional, auto-extracted if omitted)
2. **Auto-extract bundle ID** when `--package-name` is not provided:
   - Android: `aapt2 dump badging` (requires Android SDK tools)
   - iOS/macOS: `/usr/libexec/PlistBuddy` on `Info.plist` (already available on macOS)
3. **Skip csproj-based package name lookup** when `--prebuilt` is set
4. **Report package size** the same way (directory vs file detection already works, lines 120-134)
5. **Works with `measure_all.sh`** only in single-config mode (`--app` with a single config specified) since pre-built apps don't have the concept of multiple build configs

### For iOS Simulator Pre-Built Measurement

The `ios/measure_simulator_startup.sh` script already has `--no-build` flag support (line 109-112). Pre-built apps only need the bundle ID extraction to be wired up. Extending this is straightforward.

---

## Tradeoffs

| Approach | Pros | Cons |
|---|---|---|
| **Source in `custom-apps/`** | Clean separation from generated apps; survives `prepare.sh -f`; tracked in git | Extra script to register/symlink; users need to learn a convention |
| **Source directly in `apps/`** | Zero new scripts; existing tooling works immediately | `prepare.sh -f` destroys custom apps; needs `prepare.sh` modification |
| **`--prebuilt` flags** | Most flexible; works with any binary from any source; no directory convention needed | Can't iterate on build configs; user must provide correct package-name; doesn't work with `measure_all.sh` matrix sweep |
| **Dedicated `measure_prebuilt.sh`** | Clean separation; no changes to existing scripts | Code duplication (measurement logic); yet another top-level script |

---

## Risks and Edge Cases

### Source-Based

1. **Csproj name mismatch:** If `apps/my-app/other-name.csproj` exists, `build.sh` will fail because it looks for `my-app.csproj`. Need clear validation/error messaging.

2. **Multi-platform apps:** A single source app may target multiple platforms. The csproj would need all relevant TFMs in `<TargetFrameworks>`. This works with the existing `-f $PLATFORM_TFM` flag, but `<TargetFrameworks>` must include the target TFM.

3. **MAUI apps need workload:** If a custom app uses MAUI, the correct MAUI workload must be installed. `prepare.sh` installs platform-specific MAUI workloads, but a custom MAUI app for a platform that wasn't prepared would fail.

4. **PGO profile paths:** The profiling patch in `patch_app()` uses `$(MSBuildThisFileDirectory)profiles/*.mibc` (relative to the csproj). Custom apps would need either (a) a `profiles/` directory with MIBC files, or (b) to skip PGO configurations.

5. **Assembly name collision guard:** The existing guard blocks names starting with `Microsoft.`, `System.`, `Mono.`, `Xamarin.`. Custom apps might have such names legitimately (e.g., `Microsoft.MyTeam.App`). The guard would need to be relaxed or made opt-out for custom apps.

6. **NuGet restore:** Custom apps with additional NuGet dependencies would need the packages available via the configured NuGet sources in `NuGet.config`. The repo's config has limited sources (dotnet-public, dotnet-eng, dotnet11, dotnet11-transport). nuget.org is not included.

7. **`Directory.Build.props` side effects:** Custom apps inherit the repo's `Directory.Build.props`, which sets `RestorePackagesPath` to the repo's local `packages/` directory and imports all platform build configs. This could conflict with an app that has its own `Directory.Build.props` or expects different MSBuild behavior.

### Pre-Built Binary

1. **Platform verification:** No way to validate that a pre-built `.apk` is actually Android or that a `.app` bundle is iOS vs macOS vs maccatalyst without inspecting the binary. Mismatched platform would cause runtime deployment failures.

2. **Signing (Android):** Android APKs must be signed to install. The pipeline expects `*-Signed.apk`. User-provided APKs must be pre-signed.

3. **Signing (iOS):** Physical iOS device deployment requires code signing with a valid provisioning profile. Pre-built `.app` bundles for device must be signed. Simulator `.app` bundles can be unsigned.

4. **Architecture mismatch:** A pre-built `ios-arm64` `.app` won't run on `iossimulator-arm64`. No validation exists to check the binary's target architecture.

5. **Build config tracking:** Pre-built apps don't have a `_BuildConfig`. Results can't be meaningfully compared across configs since there's only one binary. The `RESULT_NAME` in `measure_startup.sh` uses `${SAMPLE_APP}_${BUILD_CONFIG}` — for pre-built apps, the config would need to be user-provided or a placeholder like `PREBUILT`.

6. **`measure_all.sh` integration:** The sweep model (all apps × all configs) doesn't map to pre-built binaries. A pre-built app is one specific binary — measuring it with "all configs" makes no sense. Pre-built should only work with `measure_startup.sh`, not `measure_all.sh`.

### Cross-Cutting

1. **`.gitignore` for `apps/`:** The `apps/` directory is gitignored (`.gitignore` line 62). Custom app source code placed there won't be tracked. This reinforces the need for a separate `custom-apps/` directory if source should be version-controlled.

2. **`clean.sh` safety:** `clean.sh all` iterates all directories in `apps/` (line 16-17) and cleans `bin/obj/`. This is safe for custom apps — it only removes build artifacts, not source.

3. **`build.sh` archival:** `build.sh` copies `bin/` and `obj/` to `$BUILD_DIR/<app>_<timestamp>/` (line 97-100). This works with custom apps — no naming assumption beyond the app name.

---

## Implementation Priority

1. **Phase 1 (Low effort, high value):** Document the existing capability — users can already place apps in `apps/` and use `--app` with `measure_all.sh`. Just needs documentation and a `prepare.sh` fix to not wipe custom apps.

2. **Phase 2 (Medium effort):** Add `--prebuilt --package-path --package-name` to `measure_startup.sh` for pre-built binary measurement. Auto-extract bundle ID.

3. **Phase 3 (Medium effort):** Create `custom-apps/` directory with registration script and profiling patch support.

---

## Key Files Referenced

| File | Lines | Purpose |
|---|---|---|
| `generate-apps.sh` | 36-99, 101-176, 180-201 | App generation, patching, platform mapping |
| `build.sh` | 63-67, 94-95 | App dir resolution, build command |
| `measure_startup.sh` | 81-85, 91-95, 103-106, 114, 120-134, 158-162 | App resolution, bundle ID, build, package discovery, measurement |
| `measure_all.sh` | 40-44, 82-95, 98-100 | Default app lists, `--app` override |
| `init.sh` | 11, 28-98 | `APPS_DIR`, `resolve_platform_config()` |
| `prepare.sh` | 85, 196 | `rm -rf "$APPS_DIR"`, calls `generate-apps.sh` |
| `clean.sh` | 14-31 | App cleaning logic |
| `Directory.Build.props` | 1-15 | Shared MSBuild config imports |
| `Directory.Build.targets` | 1-10 | Shared MSBuild target imports |
| `.gitignore` | 62 | `apps/` is gitignored |
| `ios/measure_simulator_startup.sh` | 109-112, 308-321 | `--no-build` flag, bundle ID extraction |
| `android/build-configs.props` | 1-75 | 7 build config PropertyGroups |
| `ios/build-configs.props` | 1-55 | 6 build config PropertyGroups |
