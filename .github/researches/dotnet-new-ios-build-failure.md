# dotnet-new-ios Build Failure Investigation

## Summary

The `dotnet-new-ios` app fails to build for all 6 iOS simulator configs during `measure_all.sh --platform ios-simulator`. Both MAUI apps (`dotnet-new-maui`, `dotnet-new-maui-samplecontent`) succeed with all 6 configs.

## Root Cause: TFM Mismatch

**The `dotnet-new-ios` csproj targets `net10.0-ios`, but the build system passes `-f net11.0-ios`.**

### Evidence

1. **`apps/dotnet-new-ios/dotnet-new-ios.csproj` line 3:**
   ```xml
   <TargetFramework>net10.0-ios</TargetFramework>
   ```

2. **`init.sh` line 54:**
   ```bash
   PLATFORM_TFM="net11.0-ios"
   ```

3. **`ios/measure_simulator_startup.sh` lines 293-298:**
   ```bash
   ${LOCAL_DOTNET} build -c Release \
       -f "$PLATFORM_TFM" -r "$PLATFORM_RID" \
       ...
   ```

4. **`global.json` line 3:** SDK is `11.0.100-preview.3.26123.103` — a .NET 11 preview SDK.

### Why the `dotnet new ios` template generates `net10.0-ios`

The `dotnet new ios` template from the .NET 11 preview SDK appears to default to `net10.0-ios` as the TFM (possibly because the iOS template hasn't been updated for .NET 11 preview yet, or the template defaults to the latest stable TFM). The build command then passes `-f net11.0-ios` which doesn't match the project's `<TargetFramework>`.

MSBuild error would be:
```
error : The project does not support the target framework 'net11.0-ios'.
```

### Why MAUI apps work

In `generate-apps.sh` lines 71-94, there's explicit TFM patching **only for MAUI apps**:

```python
# generate-apps.sh lines 73-94
if [ "$template" = "maui" ] && [ -f "$csproj" ]; then
    python3 - "$csproj" "$PLATFORM_TFM" << 'TFMEOF'
    ...
    # Replaces <TargetFrameworks>...</TargetFrameworks> with the platform TFM
    content = content.replace(
        '<PropertyGroup>\n',
        '<PropertyGroup>\n\t\t<TargetFrameworks>' + platform_tfm + '</TargetFrameworks>\n',
        1
    )
    ...
```

This Python code:
- Strips out the multi-TFM `<TargetFrameworks>` element (the MAUI template includes android, ios, maccatalyst, windows, etc.)
- Inserts `<TargetFrameworks>net11.0-ios</TargetFrameworks>` — matching `PLATFORM_TFM`

The non-MAUI `ios` template is **not** patched, so it keeps whatever TFM `dotnet new ios` generates (`net10.0-ios`).

## Fix

The fix needs to be in `generate-apps.sh`: after generating a non-MAUI app from a platform template (`ios`, `macos`, `android`), the TFM in the csproj should be patched to match `$PLATFORM_TFM`.

Specifically, after line 65 (`${LOCAL_DOTNET} new "$template" ...`) and before line 98 (`patch_app ...`), add TFM patching for non-MAUI templates. The csproj uses singular `<TargetFramework>` (not plural), so the regex/replacement needs to handle that form:

```python
# Replace <TargetFramework>net10.0-ios</TargetFramework>
# with    <TargetFramework>net11.0-ios</TargetFramework>
content = re.sub(
    r'<TargetFramework>[^<]*</TargetFramework>',
    '<TargetFramework>' + platform_tfm + '</TargetFramework>',
    content,
    count=1
)
```

After patching, the app should be regenerated (`rm -rf apps/dotnet-new-ios && ./generate-apps.sh --platform ios-simulator`).

> _Internal data redacted._
