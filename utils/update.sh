#!/usr/bin/env nix-shell
#!nix-shell -i bash -p curl nix-prefetch-scripts nix-prefetch-git gnugrep cargo
set -euo pipefail

# OpenDeck update script
# Must be run from the root directory of the project.
# Usage: ./utils/update.sh <version>
# Example: ./utils/update.sh 2.12.0

# Ensure the script is run from the project root
if [ ! -f "flake.nix" ]; then
    echo "Error: This script must be run from the root directory of the project."
    echo "Usage: ./utils/update.sh <version>"
    exit 1
fi

if [ $# -ne 1 ]; then
    echo "Usage: $0 <version>"
    echo "Example: $0 2.12.0"
    exit 1
fi

VERSION="$1"
REPO="https://github.com/nekename/opendeck"

echo "Updating OpenDeck to $VERSION..."

TEMP_DIR=$(mktemp -d)
trap "rm -rf $TEMP_DIR" EXIT

# Fetch source hash
echo "Fetching source hash..."
SRC_HASH_B32=$(nix-prefetch-url --unpack "$REPO/archive/refs/tags/v${VERSION}.tar.gz")
SRC_HASH=$(nix hash convert --hash-algo sha256 --to sri "$SRC_HASH_B32")

# Download and extract source
echo "Downloading source..."
curl -sL "$REPO/archive/refs/tags/v${VERSION}.tar.gz" | tar xz -C "$TEMP_DIR"
SRC_DIR="$TEMP_DIR/OpenDeck-${VERSION}"

# Update deno.lock
echo "Updating deno.lock..."
curl -sL "https://raw.githubusercontent.com/nekename/opendeck/v${VERSION}/deno.lock" -o pkg/deno.lock

# Regenerate Cargo.lock from the new source
echo "Regenerating Cargo.lock..."
(cd "$SRC_DIR/src-tauri" && cargo generate-lockfile)
cp "$SRC_DIR/src-tauri/Cargo.lock" pkg/Cargo.lock

# Check if fix-path-env is a pinned git dependency and fetch its hash
FIX_PATH_ENV_REV=$(grep -oP 'git\+https://github\.com/tauri-apps/fix-path-env-rs\?rev=\K[^#]+' pkg/Cargo.lock | head -1 || true)
FIX_PATH_ENV_HASH=""
FIX_PATH_ENV_VERSION=""
if [ -n "$FIX_PATH_ENV_REV" ]; then
    echo "Fetching fix-path-env hash (rev: $FIX_PATH_ENV_REV)..."
    FIX_PATH_ENV_HASH=$(nix-prefetch-git --url https://github.com/tauri-apps/fix-path-env-rs.git --rev "$FIX_PATH_ENV_REV" 2>/dev/null \
        | grep '"hash"' | grep -oP '"sha256-[^"]+"' | tr -d '"' || true)
    FIX_PATH_ENV_VERSION=$(grep -A2 'name = "fix-path-env"' pkg/Cargo.lock | grep 'version' | grep -oP '[\d.]+')
fi

# Update starterpack Cargo.lock
PLUGIN_DIR="$SRC_DIR/plugins/com.amansprojects.starterpack.sdPlugin"
echo "Updating starterpack Cargo.lock..."
cp "$PLUGIN_DIR/Cargo.lock" pkg/starterpack-Cargo.lock

# Check if enigo is a pinned git dependency and fetch its hash
ENIGO_REV=$(grep -oP 'git = "https://github.com/enigo-rs/enigo.git", rev = "\K[^"]+' "$PLUGIN_DIR/Cargo.toml" || true)
ENIGO_HASH=""
ENIGO_VERSION=""
if [ -n "$ENIGO_REV" ]; then
    echo "Fetching enigo hash (rev: $ENIGO_REV)..."
    ENIGO_HASH=$(nix-prefetch-git --url https://github.com/enigo-rs/enigo.git --rev "$ENIGO_REV" 2>/dev/null \
        | grep '"hash"' | grep -oP '"sha256-[^"]+"' | tr -d '"' || true)
    ENIGO_VERSION=$(grep -A2 'name = "enigo"' "$PLUGIN_DIR/Cargo.lock" | grep 'version' | grep -oP '[\d.]+')
fi

echo ""
echo "All lock files updated."
echo ""
echo "Update pkg/package.nix with:"
echo "  version = \"$VERSION\";"
echo "  srcHash = \"$SRC_HASH\";"
if [ -n "$FIX_PATH_ENV_HASH" ]; then
    echo "  fixPathEnvHash = \"$FIX_PATH_ENV_HASH\";  # cargoOutputHashes key: fix-path-env-${FIX_PATH_ENV_VERSION}"
fi
if [ -n "$ENIGO_HASH" ]; then
    echo "  enigoHash = \"$ENIGO_HASH\";  # outputHashes key: enigo-${ENIGO_VERSION}"
fi
echo ""
echo "Then: nix build .#opendeck"
