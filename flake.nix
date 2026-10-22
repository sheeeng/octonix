{
  description = "Manage GitHub resources declaratively with Nix.";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      systems = [
        "aarch64-darwin"
        "x86_64-darwin"
        "aarch64-linux"
        "x86_64-linux"
      ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
      octonixLib = import ./lib { inherit (nixpkgs) lib; };
      exampleConfiguration = octonixLib.evalConfig [ ./examples/stikkontakten.nix ];
    in
    {
      lib = octonixLib;

      modules.default = ./modules;

      inherit (exampleConfiguration) requests;

      packages = forAllSystems (system: rec {
        default = switch;
        switch = octonixLib.mkSwitch nixpkgs.legacyPackages.${system} exampleConfiguration.requests;
      });

      devShells = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        {
          default = pkgs.mkShell {
            packages = [
              pkgs.gh
              pkgs.jq
              pkgs.nixfmt
            ];
          };
        }
      );

      formatter = forAllSystems (system: nixpkgs.legacyPackages.${system}.nixfmt-tree);

      checks = forAllSystems (system: {
        inherit (self.packages.${system}) switch;
      });
    };
}
