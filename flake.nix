{
  description = "ctf — clang-tidy runner per module";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        zig = pkgs.zig_0_15;
        version =
          let
            zon = builtins.readFile ./build.zig.zon;
            after = builtins.elemAt (builtins.split "\\.version = \"" zon) 2;
          in builtins.elemAt (builtins.split "\"" after) 0;
      in {
        packages.default = pkgs.stdenvNoCC.mkDerivation {
          pname = "ctf";
          inherit version;

          src = ./.;

          nativeBuildInputs = [ zig ];

          buildPhase = ''
            zig build -Doptimize=ReleaseSafe \
              --global-cache-dir "$TMPDIR/zig-cache" \
              --prefix $out
          '';

          installPhase = "true";

          meta = {
            description = "Run clang-tidy per module defined in ctf.toml";
            mainProgram = "ctf";
          };
        };

        devShells.default = pkgs.mkShell {
          packages = [ zig pkgs.clang-tools ];
        };
      });
}
