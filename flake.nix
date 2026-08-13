{
  description = "NixOS self-update module - automatically pull git config and rebuild";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";

  outputs =
    { self, nixpkgs }:
    let
      forAllSystems = nixpkgs.lib.genAttrs [
        "x86_64-linux"
        "aarch64-linux"
      ];
    in
    {
      nixosModules.default = import ./default.nix;

      # The builder-side tool: build a host, publish the closure, move the
      # pointer. Run it from the config repo, e.g. via `just deploy <host>`.
      packages = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        {
          nixos-release = pkgs.writeShellApplication {
            name = "nixos-release";
            runtimeInputs = with pkgs; [
              nix
              git
              jq
              coreutils
            ];
            text = builtins.readFile ./scripts/nixos-release;
          };
          default = self.packages.${system}.nixos-release;
        }
      );

      checks = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        {
          integration = pkgs.testers.runNixOSTest ./tests/integration.nix;
          reboot = pkgs.testers.runNixOSTest ./tests/reboot.nix;
        }
      );
    };
}
