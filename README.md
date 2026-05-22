# opendeck-nix

This repository contains a nixpkg derivation which builds [OpenDeck](https://github.com/nekename/opendeck). In addition to that, a module is provided, so you can enable OpenDeck support by just adding `programs.opendeck.enable = true;` to your configuration.

## Installation

Add the following input to your `flake.nix`:

```nix
{
  inputs = {
    opendeck-nix.url = "github:Kitt3120/opendeck-nix";
  };
}
```

**Please do not set `opendeck-nix.inputs.nixpkgs.follows = "nixpkgs";`**. You will end up with hash-mismatches.

Enable OpenDeck:

```nix
{ inputs, ... }:

{
  imports = [ inputs.opendeck-nix.nixosModules.default ];
  programs.opendeck.enable = true;
}
```

Apply your configuration and enjoy OpenDeck! :)

## Why?

OpenDeck is a pretty complex piece of software. It uses [Tauri](https://tauri.app/), which bundles a Rust backend and a Deno frontend into a single application. Both Rust and Deno have a complex dependency management with lockfiles.

As you may know, nix is deterministic. Defining a complex build process like the one of OpenDeck in a deterministic way is not trivial. Especially when it comes to dependencies.

### Network access, FODs and build helpers

When a nix derivation builds, network access in the sandbox environment is prohibited to ensure that the build is deterministic. This is a very good thing. But have you ever tried to run `cargo build` or `deno install` without network access, in a clean environment, without pre-fetching all dependencies? Spoiler: It's not going to work. :)

There are 2 solutions to this problem. A hard one and an easy (but not so pretty) one. For both approaches, you need to understand what Fixed Output Derivations (FODs) are.

You can actually enable network access during the build of a derivation. However, as you can imagine, when involving network access, the build process is no longer deterministic. To solve this problem, when defining a derivation as a FOD, you provide an output hash. This means that you'll get network access, but you have to make sure that your build process produces the exact same output every time. Otherwise, the build will fail. But that's exactly what lockfiles are for. So by combining network access and lockfiles, you can achieve a deterministic build process even when involving network access.

### The hard solution and its roadblock

The hard solution is to define a function that takes in some kind of dependency definition (like a Cargo or Deno lockfile). The function parses the lockfile and creates a FOD for each dependency. The output hashes are defined by the lockfile. The dependency is downloaded/built with network access and provided by the derivation. So all dependencies get pre-fetched and provided as derivations by this function. These derivations can then be provided as inputs to the actual build process of the main derivation.

This way, we split the downloading/building of dependencies, which requires network access, and the actual build of the main derivation, which does not require network access. The dependencies are pre-fetched with network access, but the main derivation can be built without network access. The build is deterministic. This exact approach is what some of [the nixpkgs build helpers](https://github.com/NixOS/nixpkgs/tree/master/pkgs/build-support) achieve. In fact, there already is a [build helper for Rust](https://github.com/NixOS/nixpkgs/blob/master/pkgs/build-support/rust/build-rust-package/default.nix), and it's awesome. We use it in this repository to build the Rust part of OpenDeck. It takes a Cargo.lock, grabs all the Rust dependencies with network access, and then builds the OpenDeck Rust backend without network access.

Sounds good so far. So what's the problem?

The problem is that nixpkgs does not have a build helper for Deno. I don't know a lot about Deno myself, but from what I saw on the nixpkgs issue tracker, it's a pain to implement a build helper for Deno. In fact, it is so hard that the upstream nixpkgs maintainers have been struggling for almost a year (as of now) to implement one, merging and reverting issues, closing issues, and a PR with an implementation on stale because no one has the expertise to review it. (Note: This is not a criticism of the maintainers. They are doing their best, and I wish I had the expertise to help them. It's just an unfortunate situation.)

Relevant issues are:

- [#407434](https://github.com/NixOS/nixpkgs/issues/407434) - Initial approach for a Deno build helper (it was merged, but got reverted later)
- [#419255](https://github.com/NixOS/nixpkgs/issues/419255) - A reopen of the reverted PR, which is now closed
- [#442056](https://github.com/NixOS/nixpkgs/issues/442056) - Also part of that reopened PR, also now closed
- [#453904](https://github.com/NixOS/nixpkgs/issues/453904) - A re-implementation of the previously reverted PR, getting things right this time, following the same approach as the fetchNpmDeps build helper. This PR is stale and awaiting review since February 2026.
- [#358223](https://github.com/NixOS/nixpkgs/issues/358223) - There even is an upstream PR for OpenDeck already, which is waiting for a Deno build helper to be implemented

So as you can see, building something with Deno through nix is not trivial at the moment.

### The easy solution

The easy solution is to pre-fetch the Deno lockfile, the starterpack plugin dependency lockfile, and some output hashes, then using FODs and a multi-step build process, injecting the lockfile into the build environments. We can then build OpenDeck just like usual, using the `deno install --freeze` command to ensure that the exact same dependencies are used every time. This is the approach I took in this repository.

First, the frontend part is built as an FOD using the deno.lock file. The frontend output hash is hardcoded in the derivation definition.

The starterpack plugin has some Deno dependencies. So we first have to build the Deno dependencies of the starterpack plugin as an FOD, using the same deno.lock file and a hardcoded output hash. The starterpack plugin also has a git dependency (enigo), of which the output hash is also hardcoded in the derivation definition.

With the dependencies built, we can build the starterpack plugin as an FOD. The dependencies are provided to the build environment and the starterpack-Cargo.lock file is provided. The output hash of the starterpack plugin is also hardcoded in the derivation definition.

Finally, we can build the OpenDeck application itself. Here, we use the Rust build helper. The Cargo.lock file is provided, as well as the pre-built frontend and starterpack plugin is provided to the build environment. The output hash of the OpenDeck application is also hardcoded in the derivation definition. The OpenDeck application also has a git dependency (fix-path-env), of which the output hash is also hardcoded in the derivation definition.

This approach is easy to implement, and it works. However, it is more brittle than using a build helper, and it has a lot of hardcoded hashes instead of just relying on lockfiles. This makes it more difficult to maintain because you have to manually update the lockfiles and output hashes whenever there is a dependency update. But this has been partly automated by the [update.sh](utils/update.sh) script.

This should be okay for now, but I also plan on adding a GitHub Action workflow to detect and automatically update the lockfiles and output hashes, edit the derivation's definition, and commit it. This completely automates the maintenance of this repository, as long as upstream OpenDeck has no breaking changes.

## Why a flake? Why don't you just upstream this to nixpkgs?

I am a nixpkgs maintainer, and thus I also planned on upstreaming this. However, there are some guidelines when it comes to contributing to nixpkgs. Build helpers should be preferred over using stdenv.mkDerivation, and FODs are a big no-no. The nixpkgs maintainers learned this the hard way, when Deno was updated and all Deno-based packages broke.

So I will keep this as a flake for now. If a Deno build helper gets implemented in the future, I will be happy to refactor this repository to use it, and then we can talk about upstreaming it to nixpkgs. :)

## Why no arm64 support?

The software should work on arm64 just fine. However, I have my suspicions that it will produce different output hashes, and thus break the build. I have arm64 hardware, so I can try this.

## Why no macOS support?

OpenDeck should be able to compile for Windows, Linux, and macOS. Same problem regarding the output hashes, though. I also have no macOS hardware, so I can't test this. Feel free to open a PR! :)

## TODO

- [ ] arm64 support
- [ ] GitHub Action workflow for automatic updates
