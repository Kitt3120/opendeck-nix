{
  description = "OpenDeck - Linux software for the Elgato Stream Deck with support for original Stream Deck plugins";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs =
    { self, nixpkgs }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forEachSystem = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
    in
    {
      packages = forEachSystem (pkgs: rec {
        opendeck = pkgs.callPackage ./pkg/package.nix { };
        default = opendeck;
      });

      overlays.default = final: _prev: {
        opendeck = final.callPackage ./pkg/package.nix { };
      };
    };
}
