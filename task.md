# Task

1. [COMPLETE] Add complete CoreCLR performance measurement support for Apple platforms: **iOS**, **Mac Catalyst**, and **macOS (osx)**.
   Priority order: iOS > osx > maccatalyst.
   Each platform needs: build configuration presets, app generation, workload installation, startup measurement, package size reporting, and documentation. Follow the existing Android platform support as the reference pattern.

2. [COMPLETE] Add support for **Android emulators** and **iOS simulators**.

3. [COMPLETE] Support measuring **custom apps** by users. Either by adding an app to build by adding its source code to the apps/ directory, or just pointing to an already built .apk or .app. Needs further research/planning.
