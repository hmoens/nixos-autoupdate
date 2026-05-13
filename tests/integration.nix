{ pkgs, lib, ... }:

let
  flakeNix = pkgs.writeText "flake.nix" ''
    {
      outputs = { ... }: {};
    }
  '';

  versionV1 = pkgs.writeText "version-v1" "1\n";
  versionV2 = pkgs.writeText "version-v2" "2\n";
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

        nixos-autoupdate = {
          enable = true;
          repoUrl = "ssh://git@gitserver/var/lib/git/test-repo.git";
          branch = "main";
          flakeOutput = "nixosConfigurations.autoupdate";
          frequency = "1min";
          ageKeyPath = "/var/lib/nixos/secrets/age.key";
          gitSshKey = "/var/lib/nixos/secrets/git-ssh-key.age";
          rebuildCommand = "cp \"$FLAKE_WORKTREE/version\" /var/lib/selfupdate-version";
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

      with subtest("Setup autoupdate VM: age keypair"):
          autoupdate.succeed("mkdir -p /var/lib/nixos/secrets")
          autoupdate.succeed("chmod 700 /var/lib/nixos/secrets")
          autoupdate.succeed("age-keygen -o /var/lib/nixos/secrets/age.key 2>&1")
          autoupdate.succeed("chmod 600 /var/lib/nixos/secrets/age.key")

          pubkey = autoupdate.succeed(
              "age-keygen -y /var/lib/nixos/secrets/age.key"
          ).strip()

      with subtest("Setup autoupdate VM: SSH keypair encrypted with age"):
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

      with subtest("Setup gitserver: authorized_keys"):
          gitserver.succeed("mkdir -p ~git/.ssh")
          gitserver.succeed(
              'echo "' + ssh_pubkey + '" >> ~git/.ssh/authorized_keys'
          )
          gitserver.succeed("chmod 700 ~git/.ssh")
          gitserver.succeed("chmod 600 ~git/.ssh/authorized_keys")
          gitserver.succeed("chown -R git:git ~git")

      with subtest("Setup gitserver: bare git repo"):
          gitserver.succeed("mkdir -p /var/lib/git")
          gitserver.succeed("git init --bare /var/lib/git/test-repo.git")
          gitserver.succeed("chown -R git:git /var/lib/git")

      with subtest("Push v1 to git repo"):
          gitserver.copy_from_host_via_shell("${flakeNix}", "/tmp/flake.nix")
          gitserver.copy_from_host_via_shell("${../default.nix}", "/tmp/module.nix")
          gitserver.copy_from_host_via_shell("${versionV1}", "/tmp/version")

          gitserver.succeed(
              "git config --global --add safe.directory /var/lib/git/test-repo.git"
          )
          gitserver.succeed(
              "d=$(mktemp -d) && cd \"$d\" && git init && git branch -m main "
              "&& git config user.email test@test.com && git config user.name Test "
              "&& cp /tmp/flake.nix flake.nix && cp /tmp/module.nix default.nix "
              "&& cp /tmp/version version && git add flake.nix default.nix version "
              "&& git commit -m 'Initial config v1' "
              "&& git remote add origin /var/lib/git/test-repo.git "
              "&& git push origin main && rm -rf \"$d\""
          )

      with subtest("First service run: clone repo (expect no rebuild)"):
          autoupdate.succeed("systemctl start nixos-autoupdate.service")

      with subtest("Push v2 to git repo"):
          gitserver.copy_from_host_via_shell("${versionV2}", "/tmp/version2")

          gitserver.succeed("""
            WORKDIR=$(mktemp -d)
            cd "$WORKDIR"
            git clone -b main /var/lib/git/test-repo.git clone-dir
            cd clone-dir
            git config user.email "test@test.com"
            git config user.name "Test"
            cp /tmp/version2 version
            git add version
            git commit -m "Update to v2"
            git push origin main
            rm -rf "$WORKDIR"
          """)

      with subtest("Second service run: detect v2, rebuild"):
          autoupdate.succeed("systemctl start nixos-autoupdate.service")

      with subtest("Verify version"):
          result = autoupdate.succeed("cat /var/lib/selfupdate-version").strip()
          assert result == "2", f"Expected version 2, got {result}"
    '';
}
