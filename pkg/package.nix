{
  lib,
  stdenv,
  rustPlatform,
  fetchFromGitHub,

  # OpenDeck specific dependencies
  deno,
  wrapGAppsHook3,
  systemd,
  libayatana-appindicator,
  glib-networking,

  # Tauri dependencies
  pkg-config,
  gobject-introspection,
  cargo,
  at-spi2-atk,
  atkmm,
  cairo,
  gdk-pixbuf,
  glib,
  gtk3,
  harfbuzz,
  librsvg,
  libsoup_3,
  pango,
  webkitgtk_4_1,
  openssl,

  # Plugin dependencies
  libxkbcommon,
  wayland,
  libx11,
  libxrandr,
  libxi,
  autoPatchelfHook,
  jq,
}:

let
  # OpenDeck
  version = "2.12.0";
  srcHash = "sha256-ZXYRCBFUBeoC8PFx3RY/yU9xc1bqZ6z9+72tMxDVczQ=";

  # Additional output hashes of external cargo git dependencies that need to be specified
  cargoOutputHashes = {
    "fix-path-env-0.0.0" = "sha256-UygkxJZoiJlsgp8PLf1zaSVsJZx1GGdQyTXqaFv3oGk=";
  };
  pluginCargoOutputHashes = {
    "enigo-0.6.1" = "sha256-zcxgs30L5dQiq/tJNUla6rwZvS2FGOc0O7tTDKifLPo=";
  };

  # Fixed Output Derivation (FOD) output hashes
  frontendHash = "sha256-dWBkG2O2CpI/d0vVONUmZ4Qj/NfKwBejs2M+dTcuXYQ=";
  pluginDenoDepsHash = "sha256-2onuAQfHyVvf21mYJ18oEu+jNRWCdr5xiRk4/1Pp1ak=";

  # src info that is inherited by the frontend, plugins, plugin deps, and the actual OpenDeck derivation
  src = fetchFromGitHub {
    owner = "nekename";
    repo = "opendeck";
    rev = "v${version}";
    hash = srcHash;
  };

  # The frontend derivation
  # We're building this as a FOD since it requires network access
  frontend = stdenv.mkDerivation {
    pname = "opendeck-frontend";
    inherit version src;

    # Makes this a FOD for network access
    outputHashMode = "recursive";
    outputHash = frontendHash;

    nativeBuildInputs = [ deno ];

    # Provide our vendored deno.lock to make the FOD reproducible and build the frontend
    # We also have to patch 2 things to make the FOD reproducible:
    # - svelte.config.ts: Include a fixed version.name to prevent embedding
    #   Date.now() in the JS bundles and _app/version.json
    # - index.html: Replace the random uid with a fixed value
    # - _app/version.json: Replace the Date.now() timestamp with a fixed value
    buildPhase = ''
      runHook preBuild

      cp ${./deno.lock} deno.lock
      export DENO_DIR="$TMPDIR/deno"
      deno install --frozen

      sed -i 's/adapter: adapter(),/adapter: adapter(), version: { name: "${version}" },/' svelte.config.ts
      deno task build

      if [ -f build/index.html ]; then
        uid=$(grep -o '__sveltekit_[a-z0-9]*' build/index.html | head -1 | sed 's/__sveltekit_//')
        if [ -n "$uid" ]; then
          sed -i "s/__sveltekit_''${uid}/__sveltekit_opendeck/g" build/index.html
        fi
      fi
      if [ -f build/_app/version.json ]; then
        printf '{"version":"%s"}' "${version}" > build/_app/version.json
      fi

      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall

      cp -r build/ $out

      runHook postInstall
    '';
  };

  # The plugin dependencies derivation.
  # We're building the actual plugins after this.
  # However, the plugins' build.ts files have deno dependencies.
  # To avoid also having to build the plugins as FODs, we build only the deno dependencies here as a FOD.
  # These will then be used when building the plugins, letting the plugins compile without network access.
  pluginDenoDeps = stdenv.mkDerivation {
    pname = "opendeck-plugin-deno-deps";
    inherit version src;

    # Makes this a FOD for network access
    outputHashMode = "recursive";
    outputHash = pluginDenoDepsHash;

    nativeBuildInputs = [
      deno
      jq
    ];

    # Cache dependencies of all plugins by running their build.ts files with the vendored deno.lock.
    # This populates the DENO_DIR cache with all dependencies needed to build the plugins.
    buildPhase = ''
      runHook preBuild

      cp ${./deno.lock} deno.lock
      export DENO_DIR="$TMPDIR/deno"
      for plugin in plugins/*; do
        if [ -d "$plugin" ] && [ -f "$plugin/build.ts" ]; then
          deno cache --frozen --allow-scripts "$plugin/build.ts"
        fi
      done

      runHook postBuild
    '';

    # Deno 2.x appends a trailing comment to every cached file:
    #   // denoCacheMetadata={"headers":{...},"url":"...","time":...}
    # This comment MUST be kept, deno uses the embedded URL for cache lookup.
    # However, it contains non-deterministic fields that vary across builds, making the output non-reproducible.
    # We patch the comment to make the output identical across builds:
    # - Remove non-deterministic response headers
    # - Override cache-control to "immutable" so deno never tries to re-fetch
    #   cached entries in the offline plugins build
    # - Set time to a fixed far-future value so deno always considers the cache entries valid
    # - Sort remaining headers for determinism
    installPhase = ''
      runHook preInstall

      mkdir -p "$out"
      cp -r "$TMPDIR/deno/remote" "$out/"

      find "$out/remote" -type f | while IFS= read -r f; do
        last=$(tail -n1 "$f")
        case "$last" in
          "// denoCacheMetadata="*)
            json=''${last#// denoCacheMetadata=}
            normalized=$(printf '%s' "$json" | jq -c '
              del(.headers.date, .headers["cf-ray"], .headers["report-to"], .headers["nel"], .headers["alt-svc"])
              | .headers["cache-control"] = "public, max-age=31536000, immutable"
              | .time = 9999999999
              | .headers |= (to_entries | sort_by(.key) | from_entries)
            ')
            sed -i '$ d' "$f"
            printf '// denoCacheMetadata=%s' "$normalized" >> "$f"
            ;;
        esac
      done

      runHook postInstall
    '';
  };

  # The plugins derivation.
  # We can now build the plugins using the pre-built deno dependencies.
  # The enigo dependency is a git dependency and needs some special handling.
  # This also uses our vendored starterpack-Cargo.lock to ensure reproducible builds.
  # The enigo git dependency is vendored via importCargoLock outputHashes.
  plugins = stdenv.mkDerivation {
    pname = "opendeck-plugins";
    inherit version src;

    # provide enigo hash here so importCargoLock can resolve the lockfile without network access
    cargoDeps = rustPlatform.importCargoLock {
      lockFile = ./starterpack-Cargo.lock;
      outputHashes = pluginCargoOutputHashes;
    };

    nativeBuildInputs = [
      deno
      cargo
      rustPlatform.cargoSetupHook
      autoPatchelfHook
    ];

    buildInputs = [
      libxkbcommon
      wayland
      libx11
      libxrandr
      libxi
      stdenv.cc.cc.lib
    ];

    # Copy our pinned starterpack-Cargo.lock to:
    # 1. $sourceRoot/Cargo.lock: for cargoSetupPostPatchHook lockfile validation
    # 2. the plugin directory: so cargo uses our pinned lockfile during the build
    postUnpack = ''
      cp ${./starterpack-Cargo.lock} $sourceRoot/Cargo.lock
      cp ${./starterpack-Cargo.lock} $sourceRoot/plugins/com.amansprojects.starterpack.sdPlugin/Cargo.lock
    '';

    # Patch build.ts to add --locked to cargo install so it uses the vendored enigo source.
    # Otherwise, cargo tries to fetch the git dependency from GitHub during the plugin build.
    # This would fail because we have no network access.
    postPatch = ''
      substituteInPlace plugins/com.amansprojects.starterpack.sdPlugin/build.ts \
        --replace-fail '"--root", join(outDir, target)]' '"--root", join(outDir, target), "--locked"]'
    '';

    # Copy pre-fetched deno cache to a writable location
    # (the nix store is read-only; deno may need to write into npm/ at runtime)
    buildPhase = ''
      runHook preBuild

      cp ${./deno.lock} deno.lock
      export DENO_DIR="$TMPDIR/deno"
      cp -r ${pluginDenoDeps}/. "$DENO_DIR"
      chmod -R u+w "$DENO_DIR"
      export HOME="$TMPDIR"

      mkdir -p target/plugins
      for plugin in plugins/*; do
        if [ -d "$plugin" ]; then
          plugin_name=$(basename "$plugin")
          plugin_out="$PWD/target/plugins/$plugin_name"

          cd "$plugin"
          deno run --allow-all --frozen build.ts "$plugin_out" "${stdenv.hostPlatform.rust.rustcTarget}"
          cd "$OLDPWD"
        fi
      done

      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall

      mkdir -p $out
      cp -r target/plugins/* $out/

      runHook postInstall
    '';
  };

in

# OpenDeck derivation
# This builds against our vendored Cargo.lock to ensure reproducible builds.
# This uses the pre-built frontend and plugins.
rustPlatform.buildRustPackage {
  pname = "opendeck";
  inherit version src;

  nativeBuildInputs = [
    deno
    wrapGAppsHook3
    pkg-config
    gobject-introspection
    cargo
  ];

  buildInputs = [
    systemd
    libayatana-appindicator
    at-spi2-atk
    atkmm
    cairo
    gdk-pixbuf
    glib
    gtk3
    harfbuzz
    librsvg
    libsoup_3
    pango
    webkitgtk_4_1
    openssl
  ];

  # The Rust code is in the src-tauri subdirectory
  buildAndTestSubdir = "src-tauri";

  cargoLock = {
    lockFile = ./Cargo.lock;
    outputHashes = cargoOutputHashes;
  };

  # Copy our vendored Cargo.lock into the build environment for cargoSetupPostPatchHook validation
  # This must happen before patchPhase because cargoSetupPostPatchHook validates it
  postUnpack = ''
    cp ${./Cargo.lock} $sourceRoot/Cargo.lock
    cp ${./Cargo.lock} $sourceRoot/src-tauri/Cargo.lock
  '';

  # Some fixes for our build environment:
  # - Disable frontend and plugin building since we pre-built them
  # - Remove devUrl to fix frontend-backend connection. Idk why this even works upstream?
  # - Patch libappindicator to use correct library path
  postPatch = ''
    # Frontend building
    substituteInPlace src-tauri/tauri.conf.json \
      --replace-fail '"beforeBuildCommand": "deno task build",' '"beforeBuildCommand": "",' \
      --replace-fail '"beforeDevCommand": "deno task dev",' '"beforeDevCommand": "",'  

    # Plugin building
    substituteInPlace src-tauri/build.rs \
      --replace-fail 'for entry in fs::read_dir("../plugins")?.flatten()' 'for entry in std::iter::empty::<std::fs::DirEntry>()'

    # devUrl removal
    substituteInPlace src-tauri/tauri.conf.json \
      --replace-fail $',\n\t\t"devUrl": "http://localhost:5173"' ""

    # libappindicator path fix
    substituteInPlace $cargoDepsCopy/libappindicator-sys-*/src/lib.rs \
      --replace-fail 'libayatana-appindicator3.so.1' '${libayatana-appindicator}/lib/libayatana-appindicator3.so.1'
  '';

  # Here we inject our pre-built frontend and plugins into the build process of OpenDeck:
  # - Copy pre-built frontend into build/ directory for Tauri to bundle
  # - Copy pre-built plugins into src-tauri/target/plugins for Tauri to validate
  preConfigure = ''
    # Copy pre-built frontend
    cp -r ${frontend} build/

    # Copy pre-built plugins for build-time bundling
    # Tauri needs these during build to validate the resources configuration
    mkdir -p src-tauri/target/plugins
    cp -r ${plugins}/* src-tauri/target/plugins/
    chmod -R +w src-tauri/target/plugins
  '';

  # Runtime fixes:
  # - Install plugins to the hardcoded path the app expects
  # - The app tries to access $out/usr/lib/opendeck/plugins for builtin plugins
  # - Set APPDIR environment variable for OpenDeck to find its resources
  # - Set GIO_EXTRA_MODULES for glib-networking (required for HTTPS in WebKitGTK)
  preFixup = ''
    mkdir -p $out/usr/lib/opendeck/plugins
    cp -r ${plugins}/* $out/usr/lib/opendeck/plugins/

    gappsWrapperArgs+=(
      --set APPDIR "$out"
      --prefix GIO_EXTRA_MODULES : "${glib-networking}/lib/gio/modules"
    )
  '';

  # Additional installation steps:
  # - Install udev rules that come with OpenDeck
  # - Install icon
  # - Create a desktop file
  postInstall = ''
        # Install udev rules
        install -Dm644 src-tauri/bundle/40-streamdeck.rules -t $out/lib/udev/rules.d/

        # Install icon
        install -Dm644 src-tauri/icons/icon.png $out/share/pixmaps/opendeck.png

        # Create a desktop file
        mkdir -p $out/share/applications
        cat > $out/share/applications/opendeck.desktop << EOF
    [Desktop Entry]
    Name=OpenDeck
    Comment=Control your Stream Deck on Linux
    Exec=opendeck
    Icon=opendeck
    Type=Application
    Categories=Utility;
    EOF
  '';

  passthru = {
    inherit
      frontend
      pluginDenoDeps
      plugins
      ;
  };

  meta = {
    description = "Linux software for the Elgato Stream Deck with support for original Stream Deck plugins";
    homepage = "https://github.com/nekename/opendeck";
    downloadPage = "https://github.com/nekename/opendeck/releases/tag/v${version}";
    changelog = "https://github.com/nekename/opendeck/releases/tag/v${version}";
    license = lib.licenses.gpl3Plus;
    platforms = lib.platforms.linux;
    mainProgram = "opendeck";
    maintainers = with lib.maintainers; [ Kitt3120 ];
  };
}
