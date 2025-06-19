{
  inputs = {
    utils.url = "github:numtide/flake-utils";
    nixpkgs.url = "github:nixos/nixpkgs/nixos-25.05";
  };

  outputs = { self, nixpkgs, utils }:
    utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        zig_target = {
          "x86_64-linux" = "x86_64-linux-gnu";
          "aarch64-linux" = "aarch64-linux-gnu";
          "x86_64-darwin" = "x86_64-macos";
          "aarch64-darwin" = "aarch64-macos";
        }.${system} or (throw "Unknown Zig target for system ${system}");
      in
      {
        devShell = pkgs.mkShell {
          buildInputs = with pkgs; [ zig ];
          shellHook = ''
            zsh
          '';
        };

        packages.default = pkgs.stdenv.mkDerivation {
          name = "zak";
          src = ./.;

          nativeBuildInputs = [ pkgs.zig ];

          buildPhase = ''
            export ZIG_GLOBAL_CACHE_DIR=$TMPDIR/zig-global-cache
            zig build -Doptimize=ReleaseSafe -Dtarget=${zig_target}
          '';

          installPhase = ''
            mkdir -p $out/bin
            cp zig-out/bin/zak $out/bin/
          '';
        };
      }
    );
}
