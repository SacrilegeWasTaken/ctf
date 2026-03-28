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
      in {
        packages.default = pkgs.stdenvNoCC.mkDerivation {
          pname = "ctf";
          version = "0.0.0";

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
