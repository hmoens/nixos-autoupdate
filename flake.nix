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

          # A target fetches a pre-built closure and never builds, so anything
          # config.env points at must travel inside that closure. `toString` on
          # a path silently strips Nix string context, which drops the file from
          # the closure while leaving a perfectly plausible-looking path in the
          # file — the target then dies at runtime with "Encrypted SSH key not
          # found". The VM tests do not catch it, because there gitSshKey is a
          # runtime path created inside the VM rather than a store path.
          git-ssh-key-in-closure =
            let
              # A path LITERAL, not a derivation: that is what real configs pass
              # (gitSshKey = ./.secrets/foo.age), and it is the case where
              # `toString` strips context. A writeText derivation would not
              # reproduce the bug, because toString keeps context for those.
              testKey = ./tests/fixtures/fake-git-key.age;
              sys = nixpkgs.lib.nixosSystem {
                inherit system;
                modules = [
                  ./default.nix
                  {
                    nixos-autoupdate = {
                      enable = true;
                      repoUrl = "ssh://git@example/repo.git";
                      ageKeyPath = "/var/lib/nixos/secrets/age.key";
                      gitSshKey = testKey;
                    };
                    boot.loader.grub.enable = false;
                    fileSystems."/".device = "none";
                    networking.hostName = "closure-check";
                    system.stateVersion = "25.11";
                  }
                ];
              };
              env = sys.config.environment.etc."nixos-autoupdate/config.env".source;
              closure = pkgs.closureInfo { rootPaths = [ env ]; };
            in
            pkgs.runCommand "git-ssh-key-in-closure" { } ''
              if ! grep -q '${testKey}' ${env}; then
                echo "config.env does not mention the key at all" >&2; exit 1
              fi
              # The reference is to the store path CONTAINING the file, so
              # compare against that root rather than the full file path.
              root=$(printf '%s' '${testKey}' | cut -d/ -f1-4)
              if ! grep -qx "$root" ${closure}/store-paths; then
                echo "REGRESSION: config.env references ${testKey}" >&2
                echo "but it is not in the closure, so it will be missing on any" >&2
                echo "host that fetches this system instead of building it." >&2
                exit 1
              fi
              echo ok > $out
            '';
        }
      );
    };
}
