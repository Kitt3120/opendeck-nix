#!/usr/bin/env bash
set -euo pipefail

# OpenDeck update script
# Usage: ./update.sh <version>
# Example: ./update.sh 2.7.2

if [ $# -ne 1 ]; then
    echo "Usage: $0 <version>"
    echo "Example: $0 2.7.2"
    exit 1
fi

VERSION="$1"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "==> Updating OpenDeck to version $VERSION"

# Step 1: Fetch source and get hash
echo "==> Fetching source hash..."
SRC_HASH=$(nix-prefetch-url --unpack "https://github.com/nekename/opendeck/archive/refs/tags/v${VERSION}.tar.gz")
echo "    srcHash = \"sha256-${SRC_HASH}\""

# Step 2: Download source for lock file generation
echo "==> Downloading source..."
TEMP_DIR=$(mktemp -d)
trap "rm -rf $TEMP_DIR" EXIT

curl -sL "https://github.com/nekename/opendeck/archive/refs/tags/v${VERSION}.tar.gz" | tar xz -C "$TEMP_DIR"
SRC_DIR="$TEMP_DIR/opendeck-${VERSION}"

# Step 3: Download deno.lock from the tagged release
echo "==> Downloading deno.lock..."
curl -sL "https://raw.githubusercontent.com/nekename/opendeck/v${VERSION}/deno.lock" -o "$SCRIPT_DIR/deno.lock"
echo "    ✓ deno.lock updated"

# Step 4: Generate main Cargo.lock
echo "==> Generating main Cargo.lock..."
cd "$SRC_DIR/src-tauri"
cargo generate-lockfile
cp Cargo.lock "$SCRIPT_DIR/Cargo.lock"
echo "    ✓ Cargo.lock updated"

# Step 5: Copy starterpack Cargo.lock from source (with enigo as git dep)
echo "==> Copying starterpack Cargo.lock..."
PLUGIN_DIR="$SRC_DIR/plugins/com.amansprojects.starterpack.sdPlugin"

# Check if the plugin still uses enigo as a git dependency
ENIGO_REV=$(grep -oP 'git = "https://github.com/enigo-rs/enigo.git", rev = "\K[^"]+' "$PLUGIN_DIR/Cargo.toml" || echo "")
if [ -n "$ENIGO_REV" ]; then
    echo "    Found enigo rev: $ENIGO_REV"

    # Get the hash of the enigo git source for importCargoLock.outputHashes
    ENIGO_HASH=$(nix-prefetch-git --url https://github.com/enigo-rs/enigo.git --rev "$ENIGO_REV" 2>/dev/null | grep '"hash"' | grep -oP '"sha256-[^"]+"' | tr -d '"')
    echo "    enigoHash = \"$ENIGO_HASH\""
fi

# Use the upstream Cargo.lock as-is (it has enigo as a git dep, which importCargoLock
# handles via outputHashes — no machine-specific path hacks needed)
cp "$PLUGIN_DIR/Cargo.lock" "$SCRIPT_DIR/starterpack-Cargo.lock"
echo "    ✓ starterpack-Cargo.lock updated"

# Step 6: Summary of changes needed
echo ""
echo "==> Summary of changes needed in package.nix:"
echo "    version = \"$VERSION\";"
echo "    srcHash = \"sha256-${SRC_HASH}\";"
if [ -n "${ENIGO_REV:-}" ]; then
    ENIGO_VERSION=$(grep -A2 'name = "enigo"' "$PLUGIN_DIR/Cargo.lock" | grep 'version' | grep -oP '[\d.]+')
    echo "    enigoHash = \"$ENIGO_HASH\";"
    echo "    (outputHashes key should be: \"enigo-${ENIGO_VERSION}\")"
fi

# Step 7: Update FOD hashes by letting the build fail and reading the expected hashes
echo ""
echo "==> After updating package.nix, run the following to get the new FOD hashes:"
echo "    nix build .#opendeck.passthru.frontend 2>&1 | grep 'got:'"
echo "    nix build .#opendeck.passthru.pluginDenoDeps 2>&1 | grep 'got:'"
echo ""
echo "    Or just run: nix build .#opendeck"
echo "    and copy the 'got:' hashes from the error messages into package.nix"

echo ""
echo "==> Lock files updated:"
echo "    ✓ deno.lock"
echo "    ✓ Cargo.lock"
echo "    ✓ starterpack-Cargo.lock"
echo ""
echo "==> Next steps:"
echo "    1. Update version and hashes in package.nix"
echo "    2. Try building: nix build .#opendeck"
echo "    3. Update frontendHash and pluginDenoDepsHash from build errors"
echo "    4. Build again until it works"
