{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs =
    { self, nixpkgs }:
    let
      inherit (nixpkgs) lib;
      supportedSystems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAllSystems = f: lib.genAttrs supportedSystems (system: f nixpkgs.legacyPackages.${system});
    in
    {
      nixosModules = {
        jellyfin = ./nix/modules/jellyfin.nix;
        jellyfin-plugins = ./nix/modules/jellyfin-plugins.nix;
        server-sync = ./nix/modules/server-sync.nix;
        replica = ./nix/modules/replica.nix;
      };

      packages = forAllSystems (pkgs: rec {
        jellyfin-plugin-peer-login = pkgs.callPackage ./plugin/package.nix { };
        default = jellyfin-plugin-peer-login;
      });

      # Fast checks only; `nix flake check` runs these on every PR.
      checks = forAllSystems (pkgs: {
        # Building the plugin runs its unit tests.
        plugin = self.packages.${pkgs.stdenv.hostPlatform.system}.jellyfin-plugin-peer-login;
        modules = import ./nix/tests/modules.nix { inherit nixpkgs pkgs; };
        scripts = import ./nix/tests/scripts.nix { inherit pkgs; };
      });

      # Heavy checks stay out of `checks`; `just verify` and CI on main build them.
      legacyPackages = forAllSystems (pkgs: {
        heavyChecks.replica-login = pkgs.testers.runNixOSTest ./nix/tests/replica-login.nix;
      });

      devShells = forAllSystems (pkgs: {
        default = pkgs.mkShell {
          packages = with pkgs; [
            bash
            dotnetCorePackages.sdk_10_0
            just
            nixfmt
            shellcheck
            shfmt
          ];
          DOTNET_CLI_TELEMETRY_OPTOUT = "1";
          DOTNET_NOLOGO = "1";
        };
      });

      formatter = forAllSystems (pkgs: pkgs.nixfmt);
    };
}
