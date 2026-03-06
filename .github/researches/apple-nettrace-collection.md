# Apple .nettrace Collection Research

How .nettrace diagnostic traces are collected for startup analysis, and what's needed to extend this to iOS, macOS, and Mac Catalyst.

---

## Architecture

### Separation of Concerns: Startup Measurement vs .nettrace

These are **two independent systems** in this repository:

| Feature | Startup Measurement | .nettrace Collection |
|---------|---------------------|----------------------|
| **Purpose** | Timing (avg/min/max startup ms) | Deep runtime event analysis (JIT, GC, Loader, etc.) |
| **Scripts** | `measure_startup.sh`, `measure_all.sh` | `android/collect_nettrace.sh` |
| **Mechanism** | `dotnet/performance` `test.py devicestartup` | `dotnet-dsrouter` + `dotnet-trace collect` |
| **Platform logs** | logcat (Android), `log collect` (iOS) | Not used directly |
| **Output** | `results/<app>_<config>.trace` (performance trace) | `traces/<app>_<config>/android-startup.nettrace` |
| **Required for perf?** | Yes — primary measurement | No — optional deep-dive diagnostic |

**Key insight:** `.nettrace` collection is **not required** for startup measurement. The startup measurement pipeline already works via `test.py devicestartup`, which uses platform-specific log collection (Android logcat / iOS SpringBoard timestamps) to compute startup times. The `.nettrace` collection is a separate, optional tool for understanding *what* the runtime is doing during startup.

---

## Key Files

### Android .nettrace Collection (Reference Implementation)

| File | Purpose |
|------|---------|
| `android/collect_nettrace.sh` (lines 1–277) | Main collection script — orchestrates dsrouter + dotnet-trace |
| `android/env.txt` (line 1) | `DOTNET_DiagnosticPorts=127.0.0.1:9000,suspend,connect` |
| `android/env-nettrace.txt` (lines 1–10) | PGO instrumentation env vars for higher-quality traces |
| `generate-apps.sh` (lines 132–144) | Injects `<AndroidEnvironment>` items into csproj for env vars |
| `prepare.sh` (lines 170–183) | Installs `dotnet-dsrouter` and `dotnet-trace` tools |

### Tools (Already Installed by prepare.sh)

| Tool | Path | Purpose |
|------|------|---------|
| `dotnet-dsrouter` | `tools/dotnet-dsrouter` | Bridges diagnostic IPC from device → host |
| `dotnet-trace` | `tools/dotnet-trace` | Collects EventPipe traces via diagnostic port |

Both are already installed for all platforms via `prepare.sh` lines 170–183.

---

## Android .nettrace Flow (Current)

Reference: `android/collect_nettrace.sh`

```
Step 1: Start dsrouter (line 182-188)
  └─ dotnet-dsrouter server-server -ipcs /tmp/dsrouter-$$ -tcps 127.0.0.1:9000 --forward-port Android &
  └─ sleep 3 (wait for ADB port forwarding)

Step 2: Clear logcat (line 203)
  └─ adb logcat -c

Step 3: Build + deploy app with diagnostics (lines 209-215)
  └─ dotnet build -t:Run ... -p:AndroidEnableProfiler=true -p:_BuildConfig=$BUILD_CONFIG
  └─ AndroidEnableProfiler=true triggers <AndroidEnvironment> inclusion of env.txt
  └─ env.txt sets DOTNET_DiagnosticPorts=127.0.0.1:9000,suspend,connect
  └─ App starts, connects to dsrouter on port 9000, suspends waiting for trace session

Step 4: Collect trace (lines 230-241)
  └─ dotnet-trace collect --output $TRACE_FILE --diagnostic-port /tmp/dsrouter-$$,connect --duration HH:MM:SS --providers $PROVIDERS
  └─ This resumes the suspended app and records events for the specified duration

Step 5: Validate trace file (lines 245-264)
  └─ Check file exists and is > 1000 bytes

Step 6: Dump logcat (lines 269-271)
  └─ adb logcat -d > logcat.txt

Cleanup (trap EXIT, lines 150-170):
  └─ Kill dsrouter, uninstall app from device, remove IPC socket
```

### Critical Details

- **IPC socket:** `/tmp/dsrouter-$$` — unique per script invocation (line 147)
- **TCP port:** `127.0.0.1:9000` — hardcoded, dsrouter forwards to device via ADB (line 185)
- **Diagnostic port format in env.txt:** `127.0.0.1:9000,suspend,connect` — app connects to this address, suspends until a trace session starts (line 1 of `android/env.txt`)
- **Event providers** (line 234): `Microsoft-Windows-DotNETRuntime:0x1F000080018:5,Microsoft-Windows-DotNETRuntime:0x4c14fccbd:5,Microsoft-Windows-DotNETRuntimePrivate:0x4002000b:5`
- **MSBuild property `AndroidEnableProfiler=true`** (line 132): Triggers inclusion of `env.txt` via the csproj patch injected by `generate-apps.sh` lines 135-138

### Environment Variable Injection (Android)

`generate-apps.sh` lines 132-144 inject this into the csproj:
```xml
<!-- Profiling support -->
<ItemGroup Condition="'$(AndroidEnableProfiler)'=='true'">
  <AndroidEnvironment Include="../../android/env.txt" />
</ItemGroup>

<!-- PGO instrumentation for .nettrace collection -->
<ItemGroup Condition="'$(CollectNetTrace)'=='true'">
  <AndroidEnvironment Include="../../android/env-nettrace.txt" />
</ItemGroup>
```

The `<AndroidEnvironment>` MSBuild item is an Android-specific mechanism that bundles text files containing `KEY=VALUE` lines into the APK, which are then set as process environment variables when the app starts.

---

## iOS .nettrace Collection

### dsrouter for iOS

The `dotnet-dsrouter` tool supports iOS via a different forward-port mode:

```bash
dotnet-dsrouter server-server \
    -ipcs /tmp/dsrouter-$$ \
    -tcps 127.0.0.1:9000 \
    --forward-port iOS
```

The `--forward-port iOS` flag tells dsrouter to use the Apple device transport (usbmuxd) instead of ADB for port forwarding. This requires:
- A physical iOS device connected via USB (or network)
- The device must be unlocked and trusted

### Environment Variable Injection (iOS)

iOS has **no `<AndroidEnvironment>` equivalent**. Environment variables must be injected differently:

**Option A: `MtouchExtraArgs` with `--setenv`** (build-time, in csproj or MSBuild args)
```xml
<PropertyGroup Condition="'$(EnableDiagnostics)' == 'true'">
  <MtouchExtraArgs>$(MtouchExtraArgs) --setenv=DOTNET_DiagnosticPorts=127.0.0.1:9000,suspend,connect</MtouchExtraArgs>
</PropertyGroup>
```

Or passed as a build argument:
```bash
dotnet build ... -p:MtouchExtraArgs="--setenv=DOTNET_DiagnosticPorts=127.0.0.1:9000,suspend,connect"
```

**Option B: `xcrun devicectl` environment** (run-time, at launch)
```bash
xcrun devicectl device process launch --device <UDID> \
    --environment-variables DOTNET_DiagnosticPorts=127.0.0.1:9000,suspend,connect \
    <bundle-id>
```

**Recommended approach:** Option A (MtouchExtraArgs) is more reliable because it's baked into the app at build time, matching how Android does it. Option B requires manually launching the app, which may conflict with xharness-based workflows.

### Proposed iOS .nettrace Flow

```
Step 1: Start dsrouter
  └─ dotnet-dsrouter server-server -ipcs /tmp/dsrouter-$$ -tcps 127.0.0.1:9000 --forward-port iOS &

Step 2: Build + deploy app with diagnostics
  └─ dotnet build -c Release -f net11.0-ios -r ios-arm64 \
       -p:_BuildConfig=$BUILD_CONFIG \
       -p:MtouchExtraArgs="--setenv=DOTNET_DiagnosticPorts=127.0.0.1:9000,suspend,connect"
  └─ Deploy via xharness: xharness apple install --app <path.app> --target ios-device

Step 3: Launch app
  └─ xharness apple run --app <path.app> --target ios-device
  └─ OR: xcrun devicectl device process launch --device <UDID> <bundle-id>

Step 4: Collect trace
  └─ dotnet-trace collect --output $TRACE_FILE --diagnostic-port /tmp/dsrouter-$$,connect --duration HH:MM:SS --providers $PROVIDERS

Step 5: Validate trace file

Step 6: Collect system log (replaces logcat)
  └─ sudo log collect --device --last 5m --output $TRACE_DIR/syslog.logarchive
  └─ OR: log show --device --last 5m > $TRACE_DIR/syslog.txt

Cleanup:
  └─ Kill dsrouter, uninstall app via xharness
```

### Key Differences from Android

| Aspect | Android | iOS |
|--------|---------|-----|
| Device transport | ADB | usbmuxd (via `--forward-port iOS`) |
| Env var injection | `<AndroidEnvironment>` items | `MtouchExtraArgs --setenv=` |
| MSBuild trigger property | `AndroidEnableProfiler=true` | Custom property (e.g., `EnableDiagnostics=true`) |
| App deployment | `dotnet build -t:Run` handles it | Separate install + launch steps via xharness |
| System logs | `adb logcat` | `log collect` / `log show` |
| App uninstall | `adb shell pm uninstall <pkg>` | `xharness apple uninstall` or `xcrun devicectl` |

---

## macOS / Mac Catalyst .nettrace Collection

### Simplified Flow (No Device Bridge)

macOS and Mac Catalyst apps run **locally on the host machine**. This makes .nettrace collection dramatically simpler:

- **No dsrouter needed** — the app and `dotnet-trace` share the same machine
- **No port forwarding** — direct Unix domain socket or TCP connection
- **Environment variables set directly** — just `export VAR=VALUE` before launching

### Option 1: Direct Process Attach (Simplest)

```bash
# Launch the app
open -a /path/to/MyApp.app &
APP_PID=$!

# Attach dotnet-trace to the process
dotnet-trace collect --process-id $APP_PID --output trace.nettrace --duration 00:01:00 --providers $PROVIDERS
```

**Limitation:** This misses the very early startup events because the app is already running before `dotnet-trace` attaches.

### Option 2: Diagnostic Port with Suspend (Captures Full Startup)

```bash
# Set the diagnostic port env var — app will suspend at startup
export DOTNET_DiagnosticPorts=/tmp/diag-$$.sock,suspend

# Launch the app (it will suspend immediately)
open -a /path/to/MyApp.app &

# Connect dotnet-trace — this resumes the app
dotnet-trace collect \
    --diagnostic-port /tmp/diag-$$.sock,connect \
    --output trace.nettrace \
    --duration 00:01:00 \
    --providers $PROVIDERS
```

**Recommended:** Option 2 for startup analysis because it captures events from the very beginning of runtime initialization.

### macOS Environment Variable Approaches

For macOS `.app` bundles, environment variables can be set via:

1. **Direct shell export** (simplest — works for Mac Catalyst and macOS):
   ```bash
   export DOTNET_DiagnosticPorts=/tmp/diag-$$.sock,suspend
   open -a /path/to/MyApp.app
   ```

2. **`launchctl setenv`** (system-wide, persists):
   ```bash
   launchctl setenv DOTNET_DiagnosticPorts "/tmp/diag.sock,suspend"
   ```

3. **Info.plist `LSEnvironment`** (baked into app bundle):
   ```xml
   <key>LSEnvironment</key>
   <dict>
     <key>DOTNET_DiagnosticPorts</key>
     <string>/tmp/diag.sock,suspend</string>
   </dict>
   ```

4. **Direct executable launch** (bypass Launch Services):
   ```bash
   DOTNET_DiagnosticPorts=/tmp/diag.sock,suspend /path/to/MyApp.app/Contents/MacOS/MyApp
   ```

**Recommended for this repo:** Option 4 (direct executable launch) — most predictable, doesn't require modifying the app bundle, captures env vars reliably.

### Proposed macOS/maccatalyst .nettrace Flow

```
Step 1: Set up diagnostic port
  └─ IPC_PATH=/tmp/diag-$$.sock

Step 2: Build the app
  └─ dotnet build -c Release -f net11.0-macos -r osx-arm64 -p:_BuildConfig=$BUILD_CONFIG

Step 3: Launch app with diagnostic env var
  └─ DOTNET_DiagnosticPorts=$IPC_PATH,suspend /path/to/MyApp.app/Contents/MacOS/MyApp &
  └─ APP_PID=$!

Step 4: Collect trace (this resumes the suspended app)
  └─ dotnet-trace collect --diagnostic-port $IPC_PATH,connect --output $TRACE_FILE --duration HH:MM:SS --providers $PROVIDERS

Step 5: Validate trace file

Step 6: (Optional) Collect system log
  └─ log show --last 5m --predicate 'process == "MyApp"' > syslog.txt

Cleanup:
  └─ kill $APP_PID (if still running)
  └─ rm -f $IPC_PATH
```

---

## Dependencies

### Already Provisioned

- `dotnet-dsrouter` — installed by `prepare.sh` line 172 for all platforms
- `dotnet-trace` — installed by `prepare.sh` line 177 for all platforms
- `xharness` — installed by `prepare.sh` line 163 for all platforms

### Additional Requirements by Platform

| Platform | Extra Requirements |
|----------|-------------------|
| iOS | Physical device connected via USB, `xcrun devicectl` (from Xcode) |
| macOS | None — everything runs locally |
| Mac Catalyst | None — everything runs locally |

---

## Risks and Unknowns

### 1. `--forward-port iOS` Exact Syntax
The dsrouter `--forward-port` flag value for iOS needs verification. The Android version uses `--forward-port Android` (confirmed in `android/collect_nettrace.sh` line 186). The iOS equivalent is likely `--forward-port iOS` based on the dsrouter documentation, but this has not been tested in this repository.

**Mitigation:** Run `dotnet-dsrouter server-server --help` to check accepted values.

### 2. `MtouchExtraArgs --setenv` for Diagnostic Ports
The `--setenv` flag for `MtouchExtraArgs` is documented for Xamarin.iOS but needs verification for .NET 11 iOS. The property name and syntax may differ.

**Mitigation:** Test with a simple app first. Alternative: inject env vars via `xcrun devicectl` at launch time.

### 3. macOS App Launch and PID Capture
Using `open -a` to launch macOS apps doesn't return the PID of the actual app process (it returns the PID of the `open` command). For direct executable launch, the actual executable path inside the `.app` bundle needs to be determined.

**Workaround:** Launch the executable directly: `/path/to/MyApp.app/Contents/MacOS/MyApp &` — this gives the correct PID via `$!`.

### 4. Mac Catalyst App Bundle Structure
Mac Catalyst `.app` bundles may have a different internal structure than native macOS apps. The executable path (`Contents/MacOS/<name>`) needs verification.

### 5. iOS Code Signing for Diagnostics
Enabling diagnostic ports on iOS may require specific entitlements in the code signing profile. If the app is signed with a distribution profile, diagnostic ports might be disabled.

**Mitigation:** Use development provisioning profiles for nettrace collection.

### 6. Diagnostic Port Suspend and App Timeout
When the app starts with `suspend` mode, it will halt until a trace session connects. On iOS, the system may kill the app if it takes too long to finish launching (watchdog timer). The trace session must connect promptly.

**Mitigation:** In the Android script, there's a 5-second sleep (line 224) between app deploy and trace start. For iOS, this may need tuning.

---

## Implementation Recommendations

### Priority Order

1. **macOS/Mac Catalyst first** — simplest to implement (no device bridge), easy to test locally
2. **iOS second** — more complex due to device bridge, requires physical device

### Script Structure

Following the Android pattern (`android/collect_nettrace.sh`):

- `ios/collect_nettrace.sh` — iOS device trace collection
- `osx/collect_nettrace.sh` — macOS local trace collection  
- `maccatalyst/collect_nettrace.sh` — Mac Catalyst local trace collection (could share with macOS)

Alternatively, `osx/collect_nettrace.sh` and `maccatalyst/collect_nettrace.sh` could be unified into a shared desktop-style collection script since the flow is identical (only the TFM/RID differ).

### Environment Variable Files (Apple Equivalents)

For consistency with the Android pattern, create:
- `ios/env-diag.txt` — not a file to include in the build, but a reference for what env vars to set
- For macOS/maccatalyst, no env file needed — set directly in the script

### csproj Patches for iOS

Extend `generate-apps.sh` `patch_app()` to add iOS diagnostic support:
```python
if platform == "ios":
    patch += """
  <!-- Diagnostics support for .nettrace collection -->
  <PropertyGroup Condition="'$(EnableDiagnostics)' == 'true'">
    <MtouchExtraArgs>$(MtouchExtraArgs) --setenv=DOTNET_DiagnosticPorts=127.0.0.1:9000,suspend,connect</MtouchExtraArgs>
  </PropertyGroup>
"""
```
