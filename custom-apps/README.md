# Custom Apps

Place custom .NET app source code here for performance measurement.

## Directory Convention

Each app must be in its own subdirectory with a `.csproj` file whose name matches the subdirectory. For example:

```
custom-apps/
  my-app/
    my-app.csproj
    Program.cs
    ...
```

The app will automatically inherit build configurations from the repo's `Directory.Build.props` and `Directory.Build.targets` files.

## Usage

### Build

```bash
./build.sh --platform <platform> my-app CORECLR_JIT build 1
```

### Measure

```bash
./measure_startup.sh my-app CORECLR_JIT --platform <platform>
```

## How It Works

During `./prepare.sh`, custom apps in this directory are automatically copied into the `apps/` directory, making them available to `build.sh` and the measurement scripts. This registration step runs before SDK installation and app generation, and is re-run on every `prepare.sh` invocation.

## Tracking

- `custom-apps/` is **git-tracked** — commit your custom app source code here.
- `apps/` is **gitignored** — it is populated at prepare time with both generated and custom apps.

## Limitations

- Apps must target the expected Target Framework Monikers (TFMs) for the selected platform (e.g., `net11.0-android`, `net11.0-ios`, `net11.0-maccatalyst`, `net11.0-macos`).
- If your app has external NuGet dependencies, you may need to add the required package feeds to the repo's `NuGet.config`.

## Measuring External MAUI Apps (--csproj)

Instead of placing apps in `custom-apps/`, you can point directly at any MAUI Android app's `.csproj` file using the `--csproj` flag:

```bash
# Measure a single config
./measure_startup.sh --csproj /path/to/MyMauiApp/MyMauiApp.csproj CORECLR_JIT

# Measure with nettrace collection
./measure_startup.sh --csproj /path/to/MyMauiApp/MyMauiApp.csproj R2R_COMP --collect-trace

# Measure all configs for an external app
./measure_all.sh --csproj /path/to/MyMauiApp/MyMauiApp.csproj
```

### Requirements for external apps

- The `.csproj` must target the correct TFM for the platform (e.g., `net11.0-android`).
- The `.csproj` should have an `<ApplicationId>` property (e.g., `com.example.myapp`). If missing, a fallback name is generated.
- The repository's `Directory.Build.props` and `Directory.Build.targets` do **not** automatically apply to external projects. Build configurations (R2R, PGO, etc.) are passed via MSBuild properties at build time.
