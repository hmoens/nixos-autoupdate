{ pkgs, lib, ... }:

let
  flakeTemplate = ''
    {
      inputs.nixpkgs.url = "path:__NIXPKGS_PATH__";
      outputs = { self, nixpkgs }: let
        system = "x86_64-linux";
      in {
        nixosConfigurations.autoupdate = nixpkgs.lib.nixosSystem {
          inherit system;
          modules = [
            "''${nixpkgs}/nixos/modules/virtualisation/qemu-vm.nix"
            ./default.nix
            ({ config, pkgs, ... }: {
              system.stateVersion = "25.11";
              boot.loader.grub.enable = false;
              fileSystems."/".device = "none";
              networking.hostName = "autoupdate";
              networking.useDHCP = true;
              networking.firewall.enable = false;
              services.openssh.enable = true;
              services.openssh.settings.PermitRootLogin = "yes";
              users.users.root.openssh.authorizedKeys.keys = [];
              environment.etc."selfupdate-version".text = "__VERSION__";
              nixos-selfupdate = {
                enable = true;
                repoUrl = "ssh://git@gitserver/var/lib/git/test-repo.git";
                branch = "main";
                flakeOutput = "nixosConfigurations.autoupdate";
                frequency = "1min";
                ageKeyPath = "/var/lib/nixos/secrets/age.key";
                gitSshKey = "/var/lib/nixos/secrets/git-ssh-key.age";
              };
            })
          ];
        };
      };
    }
  '';

  flakeV1 = pkgs.writeText "flake-v1" (
    builtins.replaceStrings [ "__NIXPKGS_PATH__" "__VERSION__" ] [ (toString pkgs.path) "1" ]
      flakeTemplate
  );
  flakeV2 = pkgs.writeText "flake-v2" (
    builtins.replaceStrings [ "__NIXPKGS_PATH__" "__VERSION__" ] [ (toString pkgs.path) "2" ]
      flakeTemplate
  );
in

{
  name = "nixos-autoupdate-integration";

  nodes = {
    gitserver =
      { pkgs, ... }:
      {
        environment.systemPackages = with pkgs; [ git ];

        users.users.git = {
          isNormalUser = true;
          createHome = true;
          group = "git";
          openssh.authorizedKeys.keys = [ ];
          shell = "${pkgs.git}/bin/git-shell";
        };
        users.groups.git = { };
        services.openssh = {
          enable = true;
          settings.PermitRootLogin = "yes";
          settings.PasswordAuthentication = false;
        };
        networking.firewall.enable = false;
        system.stateVersion = "25.11";
      };

    autoupdate =
      { pkgs, ... }:
      {
        imports = [ ../default.nix ];

        nixos-selfupdate = {
          enable = true;
          repoUrl = "ssh://git@gitserver/var/lib/git/test-repo.git";
          branch = "main";
          flakeOutput = "nixosConfigurations.autoupdate";
          frequency = "1min";
          ageKeyPath = "/var/lib/nixos/secrets/age.key";
          gitSshKey = "/var/lib/nixos/secrets/git-ssh-key.age";
        };

        environment.systemPackages = with pkgs; [ age ];

        system.stateVersion = "25.11";
        boot.loader.grub.enable = false;
        fileSystems."/".device = "none";
        networking.hostName = "autoupdate";
        networking.useDHCP = true;
        networking.firewall.enable = false;
      };
  };

  testScript =
    { nodes, ... }:
    ''
      start_all()

      gitserver.wait_for_unit("multi-user.target")
      autoupdate.wait_for_unit("multi-user.target")

      # ---- Setup autoupdate VM: age keypair ----
      autoupdate.succeed("mkdir -p /var/lib/nixos/secrets")
      autoupdate.succeed("chmod 700 /var/lib/nixos/secrets")
      autoupdate.succeed("age-keygen -o /var/lib/nixos/secrets/age.key 2>&1")
      autoupdate.succeed("chmod 600 /var/lib/nixos/secrets/age.key")

      pubkey = autoupdate.succeed(
          "age-keygen -y /var/lib/nixos/secrets/age.key"
      ).strip()

      # ---- Setup autoupdate VM: SSH keypair encrypted with age ----
      autoupdate.succeed(
          "ssh-keygen -t ed25519 -N \"\" -f /var/lib/nixos/secrets/git-ssh-key"
      )
      autoupdate.succeed(
          'age -e -r "' + pubkey + '" -o /var/lib/nixos/secrets/git-ssh-key.age '
          "/var/lib/nixos/secrets/git-ssh-key"
      )
      autoupdate.succeed("chmod 600 /var/lib/nixos/secrets/git-ssh-key.age")

      ssh_pubkey = autoupdate.succeed(
          "cat /var/lib/nixos/secrets/git-ssh-key.pub"
      ).strip()

      # ---- Setup gitserver: authorized_keys ----
      gitserver.succeed("mkdir -p ~git/.ssh")
      gitserver.succeed(
          'echo "' + ssh_pubkey + '" >> ~git/.ssh/authorized_keys'
      )
      gitserver.succeed("chmod 700 ~git/.ssh")
      gitserver.succeed("chmod 600 ~git/.ssh/authorized_keys")
      gitserver.succeed("chown -R git:git ~git")

      # ---- Setup gitserver: bare git repo ----
      gitserver.succeed("mkdir -p /var/lib/git")
      gitserver.succeed("git init --bare /var/lib/git/test-repo.git")
      gitserver.succeed("chown -R git:git /var/lib/git")

      # ---- Push initial flake (v1) + module to git repo ----
      gitserver.copy_from_host_via_shell("${flakeV1}", "/tmp/flake.nix")
      gitserver.copy_from_host_via_shell("${../default.nix}", "/tmp/module.nix")

      gitserver.succeed("""
        WORKDIR=$(mktemp -d)
        cd "$WORKDIR"
        git init
        cp /tmp/flake.nix flake.nix
        cp /tmp/module.nix default.nix
        git add flake.nix default.nix
        git commit -m "Initial config v1"
        git remote add origin /var/lib/git/test-repo.git
        git push origin main
        rm -rf "$WORKDIR"
      """)

      # ---- Trigger selfupdate on autoupdate VM (clone + rebuild to v1) ----
      autoupdate.succeed("systemctl start nixos-selfupdate.service")

      result = autoupdate.succeed("cat /etc/selfupdate-version").strip()
      assert result == "1", "Expected version 1, got " + result

      # ---- Push updated flake (v2) to git repo ----
      gitserver.copy_from_host_via_shell("${flakeV2}", "/tmp/flake-v2.nix")

      gitserver.succeed("""
        WORKDIR=$(mktemp -d)
        cd "$WORKDIR"
        git clone /var/lib/git/test-repo.git clone-dir
        cd clone-dir
        cp /tmp/flake-v2.nix flake.nix
        git add flake.nix
        git commit -m "Update to v2"
        git push origin main
        rm -rf "$WORKDIR"
      """)

      # ---- Trigger selfupdate again (fetch v2 + rebuild) ----
      autoupdate.succeed("systemctl start nixos-selfupdate.service")

      result = autoupdate.succeed("cat /etc/selfupdate-version").strip()
      assert result == "2", "Expected version 2, got " + result
    '';
}
