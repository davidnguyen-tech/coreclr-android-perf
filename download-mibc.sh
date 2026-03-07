#!/bin/bash
set -euo pipefail

# Downloads MIBC (Managed Image Based Compilation) profile packages from the
# dotnet-tools NuGet feed and extracts .mibc files to the profiles/ directory.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROFILES_DIR="$SCRIPT_DIR/profiles"
VERSIONS_LOG="$SCRIPT_DIR/versions.log"

FEED_BASE_URL="https://pkgs.dev.azure.com/dnceng/public/_packaging/dotnet-tools/nuget/v3/flat2"

# --- Argument Parsing ---

PLATFORM="android"
VERSION=""

usage() {
    echo "Usage: $0 [--platform <platform>] [--version <version>] [--help]"
    echo ""
    echo "Downloads MIBC profile packages for the specified platform."
    echo ""
    echo "Options:"
    echo "  --platform <platform>  Target platform: android, ios, maccatalyst, osx (default: android)"
    echo "  --version <version>    Specific NuGet package version (default: latest available)"
    echo "  --help                 Print this help message and exit"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --platform)
            if [[ -z "${2:-}" || "$2" == --* ]]; then
                echo "Error: --platform requires a value (android, ios, maccatalyst, osx)"
                exit 1
            fi
            PLATFORM="$2"
            shift 2
            ;;
        --version)
            if [[ -z "${2:-}" || "$2" == --* ]]; then
                echo "Error: --version requires a value"
                exit 1
            fi
            VERSION="$2"
            shift 2
            ;;
        --help)
            usage
            exit 0
            ;;
        *)
            echo "Error: Invalid parameter '$1'."
            usage
            exit 1
            ;;
    esac
done

# Validate platform
case "$PLATFORM" in
    android|ios|maccatalyst|osx) ;;
    *)
        echo "Error: Unsupported platform '$PLATFORM'. Supported: android, ios, maccatalyst, osx"
        exit 1
        ;;
esac

# --- Platform-to-RID Mapping ---

case "$PLATFORM" in
    android)      RID="android-arm64" ;;
    ios)          RID="ios-arm64" ;;
    maccatalyst)  RID="maccatalyst-arm64" ;;
    osx)          RID="osx-arm64" ;;
esac

PACKAGE_ID="optimization.${RID}.MIBC.Runtime"
PACKAGE_ID_LOWER=$(echo "$PACKAGE_ID" | tr '[:upper:]' '[:lower:]')

echo "MIBC Profile Download"
echo "Platform: $PLATFORM → RID: $RID"
echo "Package: $PACKAGE_ID"

# --- Temp file cleanup ---

TEMP_NUPKG=""
cleanup() {
    if [ -n "$TEMP_NUPKG" ] && [ -f "$TEMP_NUPKG" ]; then
        rm -f "$TEMP_NUPKG"
    fi
}
trap cleanup EXIT

# --- Version Resolution ---

INDEX_URL="${FEED_BASE_URL}/${PACKAGE_ID_LOWER}/index.json"

if [ -z "$VERSION" ]; then
    echo "Querying latest version..."
else
    echo "Verifying version $VERSION..."
fi

HTTP_RESPONSE=$(curl -sL -w "\n%{http_code}" "$INDEX_URL") || {
    echo "Error: Failed to connect to NuGet feed."
    exit 1
}

HTTP_STATUS=$(echo "$HTTP_RESPONSE" | tail -n1)
HTTP_BODY=$(echo "$HTTP_RESPONSE" | sed '$d')

if [ "$HTTP_STATUS" = "404" ]; then
    echo "Warning: Package $PACKAGE_ID not found on the NuGet feed (HTTP 404)."
    echo "MIBC profiles are optional — crossgen2 --partial will proceed without them."
    exit 0
fi

if [ "$HTTP_STATUS" != "200" ]; then
    echo "Error: Unexpected HTTP status $HTTP_STATUS when querying package index."
    exit 1
fi

if [ -z "$VERSION" ]; then
    VERSION=$(echo "$HTTP_BODY" | python3 -c "import sys,json; versions=json.load(sys.stdin)['versions']; print(versions[-1])")
    if [ -z "$VERSION" ]; then
        echo "Error: Failed to resolve latest version from package index."
        exit 1
    fi
else
    # Verify the specified version exists
    VERSION_EXISTS=$(echo "$HTTP_BODY" | python3 -c "
import sys, json
versions = json.load(sys.stdin)['versions']
target = sys.argv[1]
if target in versions:
    print('yes')
else:
    print('no')
    print('Available versions:', file=sys.stderr)
    for v in versions:
        print(f'  - {v}', file=sys.stderr)
" "$VERSION")
    if [ "$VERSION_EXISTS" != "yes" ]; then
        echo "Error: Version $VERSION not found for package $PACKAGE_ID."
        # Re-run to print available versions to stdout
        echo "$HTTP_BODY" | python3 -c "
import sys, json
versions = json.load(sys.stdin)['versions']
print('Available versions:')
for v in versions:
    print(f'  - {v}')
"
        exit 1
    fi
fi

echo "Version: $VERSION"

# --- Download and Extract ---

NUPKG_URL="${FEED_BASE_URL}/${PACKAGE_ID_LOWER}/${VERSION}/${PACKAGE_ID_LOWER}.${VERSION}.nupkg"

echo "Downloading $PACKAGE_ID v${VERSION}..."

TEMP_NUPKG=$(mktemp "${TMPDIR:-/tmp}/mibc-nupkg-XXXXXX.zip")

if ! curl -sfL -o "$TEMP_NUPKG" "$NUPKG_URL"; then
    echo "Error: Failed to download $NUPKG_URL"
    exit 1
fi

echo "Extracting MIBC profiles to profiles/..."

mkdir -p "$PROFILES_DIR"

# Extract .mibc files from data/ directory within the nupkg (ZIP format)
# -j: junk paths (don't recreate directory structure)
# -o: overwrite existing files
unzip -j -o "$TEMP_NUPKG" 'data/*.mibc' -d "$PROFILES_DIR" 2>/dev/null || true

# Check if any .mibc files were extracted
MIBC_FILES=()
while IFS= read -r -d '' f; do
    MIBC_FILES+=("$f")
done < <(find "$PROFILES_DIR" -maxdepth 1 -name "*.mibc" -print0 2>/dev/null)

if [ ${#MIBC_FILES[@]} -eq 0 ]; then
    echo "Warning: No .mibc files found in the nupkg. The package may not contain MIBC profiles."
    echo "MIBC profiles are optional — crossgen2 --partial will proceed without them."
    exit 0
fi

echo "✅ Downloaded ${#MIBC_FILES[@]} MIBC profile(s):"
for f in "${MIBC_FILES[@]}"; do
    echo "  - ${f#"$SCRIPT_DIR/"}"
done

# --- Update versions.log ---

echo "MIBC Profile: $PACKAGE_ID v$VERSION" >> "$VERSIONS_LOG"
