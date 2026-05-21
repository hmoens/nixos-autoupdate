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

      checks = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};

          defaultRebuildCommandEval = nixpkgs.lib.nixosSystem {
            system = system;
            modules = [
              self.nixosModules.default
              {
                nixos-autoupdate = {
                  enable = true;
                  repoUrl = "https://example.com/repo.git";
                  flakeOutput = "nixosConfigurations.test";
                };
                system.stateVersion = "25.11";
                boot.loader.grub.enable = false;
                fileSystems."/".device = "none";
              }
            ];
          };
          inherit (defaultRebuildCommandEval.config.environment.etc."nixos-autoupdate/apply-git.sh") source;
        in
        {
          integration = pkgs.testers.runNixOSTest ./tests/integration.nix;
          reboot = pkgs.testers.runNixOSTest ./tests/reboot.nix;
          defaultRebuildCommand = pkgs.runCommand "test-default-rebuild-command" { } ''
            cat ${source} > $out
          '';
        }
      );
    };
}
