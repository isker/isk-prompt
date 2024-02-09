{
  description = "The only good shell prompt yet written.";

  inputs = {
    flake-parts = {
      url = "github:hercules-ci/flake-parts";
    };
    nixpkgs = {
      url = "github:NixOS/nixpkgs/nixos-unstable";
    };
  };

  outputs = inputs @ {flake-parts, ...}:
    flake-parts.lib.mkFlake {inherit inputs;} {
      systems = ["x86_64-linux" "aarch64-linux" "aarch64-darwin" "x86_64-darwin"];
      perSystem = {
        config,
        self',
        inputs',
        pkgs,
        system,
        ...
      }: {
        packages = {
          default = pkgs.stdenvNoCC.mkDerivation {
            name = "isk-prompt";
            version = "0.1.0";
            src = ./.;
            nativeBuildInputs = [
              pkgs.zig_0_11
            ];
            # Zig wants to write to zig-cache by default, but it's readonly.
            # This directory is somehow okay.
            XDG_CACHE_HOME = ".cache";
            installPhase = ''
              runHook preInstall
              zig build -Doptimize=ReleaseFast --prefix $out install
              runHook postInstall
            '';
          };
        };

        formatter = pkgs.alejandra;
      };
    };
}
