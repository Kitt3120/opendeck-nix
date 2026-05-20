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
PROJECT_ROOT="$PWD"

echo "==> Updating OpenDeck to version $VERSION"

# Step 1: Fetch source and get hash
echo "==> Fetching source hash..."
SRC_HASH_B32=$(nix-prefetch-url --unpack "https://github.com/nekename/opendeck/archive/refs/tags/v${VERSION}.tar.gz")
SRC_HASH=$(nix hash convert --hash-algo sha256 --to sri "$SRC_HASH_B32")
echo "    srcHash = \"${SRC_HASH}\""

# Step 2: Download source for lock file generation
echo "==> Downloading source..."
TEMP_DIR=$(mktemp -d)
trap "rm -rf $TEMP_DIR" EXIT

curl -sL "https://github.com/nekename/opendeck/archive/refs/tags/v${VERSION}.tar.gz" | tar xz -C "$TEMP_DIR"
SRC_DIR="$TEMP_DIR/OpenDeck-${VERSION}"

# Step 3: Download deno.lock from the tagged release
echo "==> Downloading deno.lock..."
curl -sL "https://raw.githubusercontent.com/nekename/opendeck/v${VERSION}/deno.lock" -o "$PROJECT_ROOT/pkg/deno.lock"
echo "    ✓ deno.lock updated"

# Step 4: Generate main Cargo.lock
echo "==> Generating main Cargo.lock..."
cd "$SRC_DIR/src-tauri"
cargo generate-lockfile
cp Cargo.lock "$PROJECT_ROOT/pkg/Cargo.lock"
echo "    ✓ Cargo.lock updated"

# Step 4b: Fetch fix-path-env hash from its git source in the new Cargo.lock
echo "==> Fetching fix-path-env hash..."
FIX_PATH_ENV_REV=$(grep -oP 'git\+https://github\.com/tauri-apps/fix-path-env-rs\?rev=\K[^#]+' "$PROJECT_ROOT/pkg/Cargo.lock" | head -1) || FIX_PATH_ENV_REV=""
if [ -n "$FIX_PATH_ENV_REV" ]; then
    echo "    Found fix-path-env rev: $FIX_PATH_ENV_REV"
    FIX_PATH_ENV_HASH=$(nix-prefetch-git --url https://github.com/tauri-apps/fix-path-env-rs.git --rev "$FIX_PATH_ENV_REV" 2>/dev/null | grep '"hash"' | grep -oP '"sha256-[^"]+"' | tr -d '"') || FIX_PATH_ENV_HASH=""
    echo "    fixPathEnvHash = \"$FIX_PATH_ENV_HASH\""
else
    echo "    fix-path-env not found as a git dependency, skipping"
    FIX_PATH_ENV_HASH=""
fi

# Step 5: Copy starterpack Cargo.lock from source (with enigo as git dep)
echo "==> Copying starterpack Cargo.lock..."
PLUGIN_DIR="$SRC_DIR/plugins/com.amansprojects.starterpack.sdPlugin"

# Check if the plugin still uses enigo as a git dependency
ENIGO_REV=$(grep -oP 'git = "https://github.com/enigo-rs/enigo.git", rev = "\K[^"]+' "$PLUGIN_DIR/Cargo.toml" || echo "")
if [ -n "$ENIGO_REV" ]; then
    echo "    Found enigo rev: $ENIGO_REV"

    # Get the hash of the enigo git source for importCargoLock.outputHashes
    ENIGO_HASH=$(nix-prefetch-git --url https://github.com/enigo-rs/enigo.git --rev "$ENIGO_REV" 2>/dev/null | grep '"hash"' | grep -oP '"sha256-[^"]+"' | tr -d '"') || ENIGO_HASH=""
    echo "    enigoHash = \"$ENIGO_HASH\""
fi

# Use the upstream Cargo.lock as-is (it has enigo as a git dep, which importCargoLock
# handles via outputHashes — no machine-specific path hacks needed)
cp "$PLUGIN_DIR/Cargo.lock" "$PROJECT_ROOT/pkg/starterpack-Cargo.lock"
echo "    ✓ starterpack-Cargo.lock updated"

# Step 6: Summary of changes needed
echo ""
echo "==> Lock files updated:"
echo "    ✓ deno.lock"
echo "    ✓ Cargo.lock"
echo "    ✓ starterpack-Cargo.lock"

echo ""
echo "==> Summary of changes needed in pkg/package.nix:"
echo "    version = \"$VERSION\";"
echo "    srcHash = \"${SRC_HASH}\";"
if [ -n "${FIX_PATH_ENV_REV:-}" ] && [ -n "${FIX_PATH_ENV_HASH:-}" ]; then
    FIX_PATH_ENV_VERSION=$(grep -A2 'name = "fix-path-env"' "$PROJECT_ROOT/pkg/Cargo.lock" | grep 'version' | grep -oP '[\d.]+')
    echo "    fixPathEnvHash = \"$FIX_PATH_ENV_HASH\";"
    echo "    (cargoOutputHashes key should be: \"fix-path-env-${FIX_PATH_ENV_VERSION}\")"
fi
if [ -n "${ENIGO_REV:-}" ]; then
    ENIGO_VERSION=$(grep -A2 'name = "enigo"' "$PLUGIN_DIR/Cargo.lock" | grep 'version' | grep -oP '[\d.]+')
    echo "    enigoHash = \"$ENIGO_HASH\";"
    echo "    (outputHashes key should be: \"enigo-${ENIGO_VERSION}\")"
fi

echo ""
echo "==> Next steps:"
echo "    1. Update package.nix with the values listed above."
echo "    2. Try building: nix build .#opendeck"
echo "    3. Update hashes in package.nix"
echo "    4. Build again until it works"
