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
      # Set OCTONIX_CONFIG to a TOML file and pass --impure to use it instead of the example.
      configurationFile = builtins.getEnv "OCTONIX_CONFIG";
      exampleConfiguration = octonixLib.evalConfig [
        (
          if configurationFile == "" then
            ./examples/stikkontakten.nix
          else
            builtins.fromTOML (builtins.readFile configurationFile)
        )
      ];
    in
    {
      lib = octonixLib;

      modules.default = ./modules;

      inherit (exampleConfiguration) requests;

      packages = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        rec {
          default = switch;
          schema = pkgs.writeText "octonix.schema.json" (builtins.toJSON octonixLib.schema);
          switch = octonixLib.mkSwitch pkgs exampleConfiguration.requests;
          build = pkgs.writeShellApplication {
            name = "octonix-build";
            text = ''exec ${nixpkgs.lib.getExe switch} --build "$@"'';
          };
        }
      );

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
        inherit (self.packages.${system}) build switch;
      });
    };
}
