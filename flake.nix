{
  description = "A library for handling packwiz modpacks using nix";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/release-24.11";
  };

  outputs = { self, nixpkgs }:
  let
    lib = nixpkgs.lib;
    forAllSystems = lib.genAttrs lib.systems.flakeExposed;
  in
  {
    lib = import ./lib;

    overlays = {
      default = final: prev: {
        parsePackwiz = self.lib.parsePackwiz final;
      };
    };

    packages = forAllSystems (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
      in
      {
        parsePackwiz = self.lib.parsePackwiz pkgs;
      }
    );
  };
}
