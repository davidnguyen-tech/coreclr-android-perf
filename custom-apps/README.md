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

During `./prepare.sh`, custom apps in this directory are automatically copied into the `apps/` directory, making them available to `build.sh` and the measurement scripts. This registration step runs after the generated sample apps are created.

## Tracking

- `custom-apps/` is **git-tracked** — commit your custom app source code here.
- `apps/` is **gitignored** — it is populated at prepare time with both generated and custom apps.

## Limitations

- Apps must target the expected Target Framework Monikers (TFMs) for the selected platform (e.g., `net9.0-android`, `net9.0-ios`, `net9.0-maccatalyst`, `net9.0-macos`).
- If your app has external NuGet dependencies, you may need to add the required package feeds to the repo's `NuGet.config`.
