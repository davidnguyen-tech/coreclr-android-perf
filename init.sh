#!/bin/bash

# Define variables
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
BUILD_DIR="$SCRIPT_DIR/build"
TOOLS_DIR="$SCRIPT_DIR/tools"
DOTNET_INSTALL_SCRIPT="$TOOLS_DIR/dotnet-install.sh"
DOTNET_DIR="$SCRIPT_DIR/.dotnet"
LOCAL_DOTNET="$DOTNET_DIR/dotnet"
LOCAL_PACKAGES="$SCRIPT_DIR/packages"
APPS_DIR="$SCRIPT_DIR/apps"
VERSIONS_LOG="$SCRIPT_DIR/versions.log"
NUGET_CONFIG="$SCRIPT_DIR/NuGet.config"
GLOBAL_JSON="$SCRIPT_DIR/global.json"
PERF_DIR="$SCRIPT_DIR/external/performance"
SCENARIOS_DIR="$PERF_DIR/src/scenarios"
TRACES_DIR="$SCRIPT_DIR/traces"
RESULTS_DIR="$SCRIPT_DIR/results"
