#!/usr/bin/env nix-shell
#!nix-shell -i bash -p curl nix-prefetch-scripts gnugrep cargo
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

# Update starterpack Cargo.lock
PLUGIN_DIR="$SRC_DIR/plugins/com.amansprojects.starterpack.sdPlugin"
echo "Updating starterpack Cargo.lock..."
cp "$PLUGIN_DIR/Cargo.lock" pkg/starterpack-Cargo.lock

# Fetch the NAR hash for a git dependency using builtins.fetchGit + nix hash path.
# This only requires nix itself and works without nix-prefetch-git.
# Usage: fetch_git_hash <url> <rev>
fetch_git_hash() {
    local url="$1" rev="$2"
    local store_path
    store_path=$(nix eval --impure --raw --expr \
        "(builtins.fetchGit { url = \"${url}\"; rev = \"${rev}\"; allRefs = true; }).outPath" \
        2>/dev/null || true)
    if [ -n "$store_path" ]; then
        nix hash path --type sha256 "$store_path" 2>/dev/null || true
    fi
}

# Print outputHashes entries for all git dependencies found in a Cargo.lock file.
# Usage: print_cargo_git_hashes <lockfile>
print_cargo_git_hashes() {
    local lockfile="$1"
    local name="" version=""
    while IFS= read -r line; do
        case "$line" in
            "[[package]]")
                name="" ; version="" ;;
            name\ =\ \"*)
                name="${line#name = \"}"; name="${name%\"}" ;;
            version\ =\ \"*)
                version="${line#version = \"}"; version="${version%\"}" ;;
            source\ =\ \"git+*)
                local url rev
                # The Cargo.lock source format is: git+<url>?rev=<short-or-full-rev>#<full-commit-hash>
                # Always use the full commit hash (after #) as the rev for builtins.fetchGit
                url=$(echo "$line" | sed 's|source = "git+\([^?]*\)?rev=[^#]*#.*"|\1|')
                rev=$(echo "$line" | sed 's|source = "git+[^?]*?rev=[^#]*#\(.*\)"|\1|')
                if [ -n "$name" ] && [ -n "$version" ] && [ -n "$rev" ]; then
                    echo "  Fetching ${name}-${version} hash (rev: ${rev})..." >&2
                    local hash
                    hash=$(fetch_git_hash "$url" "$rev")
                    if [ -n "$hash" ]; then
                        echo "    \"${name}-${version}\" = \"${hash}\";"
                    else
                        echo "    \"${name}-${version}\" = \"<FETCH FAILED — run nix-prefetch-git manually>\";" >&2
                    fi
                fi ;;
        esac
    done < "$lockfile"
}

echo ""
echo "Fetching cargo git dependency hashes for Cargo.lock..."
CARGO_GIT_HASHES=$(print_cargo_git_hashes pkg/Cargo.lock)

echo ""
echo "Fetching cargo git dependency hashes for starterpack-Cargo.lock..."
PLUGIN_CARGO_GIT_HASHES=$(print_cargo_git_hashes pkg/starterpack-Cargo.lock)

echo ""
echo "All lock files updated."
echo ""
echo "Update pkg/package.nix with:"
echo "  version = \"$VERSION\";"
echo "  srcHash = \"$SRC_HASH\";"
if [ -n "$CARGO_GIT_HASHES" ]; then
    echo "  cargoOutputHashes = {"
    echo "$CARGO_GIT_HASHES"
    echo "  };"
fi
if [ -n "$PLUGIN_CARGO_GIT_HASHES" ]; then
    echo "  pluginCargoOutputHashes = {"
    echo "$PLUGIN_CARGO_GIT_HASHES"
    echo "  };"
fi
echo ""
echo "Then rebuild FOD hashes by running: nix build .#opendeck"
echo "(FOD hash mismatches will tell you the correct frontendHash and pluginDenoDepsHash)"
