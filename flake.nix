{
  description = "dependency-cruiser, built with its TypeScript parser bundled";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
  };

  outputs = { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];
      forAllSystems = f:
        nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
      mkDependencyCruiser = pkgs:
        pkgs.buildNpmPackage {
          pname = "dependency-cruiser";
          version = (builtins.fromJSON (builtins.readFile ./package.json)).version;
          src = self;
          npmDepsHash = "sha256-RYKAHJ23EWvksIPnMmAbdNG3jzfn/5vJROyoW6g90iw=";
          dontNpmBuild = true;
          npmFlags = [ "--ignore-scripts" ];
          meta = {
            description = "Validate and visualize dependencies";
            homepage = "https://github.com/sverweij/dependency-cruiser";
            license = nixpkgs.lib.licenses.mit;
            mainProgram = "depcruise";
          };
        };
    in {
      packages = forAllSystems (pkgs:
        let dependency-cruiser = mkDependencyCruiser pkgs;
        in {
          inherit dependency-cruiser;
          default = dependency-cruiser;
        });
    };
}
