{ pkgs, lib, ... }:

let
  versionV1 = pkgs.writeText "version-v1" "1\n";
  versionV2 = pkgs.writeText "version-v2" "2\n";
  versionV3 = pkgs.writeText "version-v3" "3\n";

  # Fake toplevel whose kernel matches the booted system => config-only change,
  # no reboot required. See tests/fake-system-flake.nix.
  testFlake = pkgs.replaceVars ./fake-system-flake.nix {
    bash = pkgs.bash;
    coreutils = pkgs.coreutils;
    system = pkgs.stdenv.hostPlatform.system;
    kerneltarget = "/run/booted-system/kernel";
  };
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
          ageKeyPath = "/var/lib/nixos/secrets/age.key";
          gitSshKey = "/var/lib/nixos/secrets/git-ssh-key.age";
          check.frequency = "*-*-* *:*:00";

          onGitStatus = ''
            mkdir -p /run/nixos-autoupdate
            {
              echo "EVENT=$AUTOUPDATE_EVENT"
              echo "STATUS=$AUTOUPDATE_STATUS"
              echo "HOSTNAME=$AUTOUPDATE_HOSTNAME"
              echo "COMMIT=$AUTOUPDATE_CHECKED_OUT_COMMIT"
              echo "PHASE=$AUTOUPDATE_PHASE"
            } > /run/nixos-autoupdate/on-git-status.env
          '';
          onApplyStatus = ''
            mkdir -p /run/nixos-autoupdate
            echo "$AUTOUPDATE_EVENT $AUTOUPDATE_STATUS reboot=$AUTOUPDATE_REBOOT_REQUIRED" \
              >> /run/nixos-autoupdate/apply-events.log
          '';
        };

        # Seed the store so the fake toplevel builds offline inside the VM.
        system.extraDependencies = with pkgs; [
          bash
          coreutils
        ];
        nix.settings = {
          experimental-features = [
            "nix-command"
            "flakes"
          ];
          sandbox = false;
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
      import json

      def status(node):
          return json.loads(node.succeed("nixos-update status --json"))

      start_all()

      gitserver.wait_for_unit("multi-user.target")
      autoupdate.wait_for_unit("multi-user.target")

      with subtest("Setup autoupdate VM: age keypair"):
          autoupdate.succeed("mkdir -p /var/lib/nixos/secrets")
          autoupdate.succeed("chmod 700 /var/lib/nixos/secrets")
          autoupdate.succeed("age-keygen -o /var/lib/nixos/secrets/age.key 2>&1")
          autoupdate.succeed("chmod 600 /var/lib/nixos/secrets/age.key")
          pubkey = autoupdate.succeed("age-keygen -y /var/lib/nixos/secrets/age.key").strip()

      with subtest("Setup autoupdate VM: SSH keypair encrypted with age"):
          autoupdate.succeed("ssh-keygen -t ed25519 -N \"\" -f /var/lib/nixos/secrets/git-ssh-key")
          autoupdate.succeed(
              'age -e -r "' + pubkey + '" -o /var/lib/nixos/secrets/git-ssh-key.age '
              "/var/lib/nixos/secrets/git-ssh-key"
          )
          autoupdate.succeed("chmod 600 /var/lib/nixos/secrets/git-ssh-key.age")
          ssh_pubkey = autoupdate.succeed("cat /var/lib/nixos/secrets/git-ssh-key.pub").strip()

      with subtest("Setup gitserver: authorized_keys"):
          gitserver.succeed("mkdir -p ~git/.ssh")
          gitserver.succeed('echo "' + ssh_pubkey + '" >> ~git/.ssh/authorized_keys')
          gitserver.succeed("chmod 700 ~git/.ssh")
          gitserver.succeed("chmod 600 ~git/.ssh/authorized_keys")
          gitserver.succeed("chown -R git:git ~git")

      with subtest("Setup gitserver: bare git repo"):
          gitserver.succeed("mkdir -p /var/lib/git")
          gitserver.succeed("git init --bare /var/lib/git/test-repo.git")
          gitserver.succeed("chown -R git:git /var/lib/git")

      def push_version(version_store_path, message):
          gitserver.copy_from_host_via_shell("${testFlake}", "/tmp/flake.nix")
          gitserver.copy_from_host_via_shell(version_store_path, "/tmp/version")
          gitserver.succeed("git config --global --add safe.directory /var/lib/git/test-repo.git")
          gitserver.succeed(
              "d=$(mktemp -d) && cd \"$d\" "
              "&& git clone -b main /var/lib/git/test-repo.git . 2>/dev/null "
              "|| { git init && git branch -m main && git remote add origin /var/lib/git/test-repo.git; } "
              "&& git config user.email test@test.com && git config user.name Test "
              "&& cp /tmp/flake.nix flake.nix && cp /tmp/version version "
              "&& git add flake.nix version "
              "&& git commit -m '" + message + "' "
              "&& git push origin main && rm -rf \"$d\""
          )

      with subtest("Push v1"):
          push_version("${versionV1}", "config v1")

      with subtest("check detects the first update"):
          autoupdate.succeed("systemctl start nixos-autoupdate-check.service")
          result = autoupdate.succeed("cat /run/nixos-autoupdate/on-git-status.env")
          assert "EVENT=UPDATE_FOUND" in result, result
          assert "STATUS=OK" in result
          assert "PHASE=check" in result
          st = status(autoupdate)
          assert st["fetched_commit"], st
          assert st["applied_commit"] is None, st

      with subtest("build then activate v1"):
          autoupdate.succeed("systemctl start nixos-autoupdate-build.service")
          st = status(autoupdate)
          assert st["built_commit"] == st["fetched_commit"], st
          assert st["reboot_required"] is False, st

          autoupdate.succeed("systemctl start nixos-autoupdate-activate.service")
          autoupdate.wait_until_succeeds("test \"$(cat /var/lib/selfupdate-version)\" = 1", timeout=30)
          st = status(autoupdate)
          assert st["applied_commit"] == st["built_commit"], st
          apply_log = autoupdate.succeed("cat /run/nixos-autoupdate/apply-events.log")
          assert "BUILD_OK OK" in apply_log, apply_log
          assert "SUCCESS OK" in apply_log, apply_log

      with subtest("no reboot required for a config-only change"):
          st = status(autoupdate)
          assert st["reboot_required"] is False, st
          autoupdate.fail("test -f /run/nixos-autoupdate/reboot-required")

      with subtest("Push v2 and run the whole pipeline via the CLI"):
          push_version("${versionV2}", "config v2")
          autoupdate.succeed("nixos-update run")
          autoupdate.wait_until_succeeds("test \"$(cat /var/lib/selfupdate-version)\" = 2", timeout=60)
          st = status(autoupdate)
          assert st["applied_commit"] == st["fetched_commit"], st

      with subtest("hold defers the build"):
          autoupdate.succeed("nixos-update hold 'testing'")
          push_version("${versionV3}", "config v3")
          autoupdate.succeed("systemctl start nixos-autoupdate-check.service")
          autoupdate.succeed("rm -f /run/nixos-autoupdate/apply-events.log")
          autoupdate.succeed("systemctl start nixos-autoupdate-build.service")
          apply_log = autoupdate.succeed("cat /run/nixos-autoupdate/apply-events.log")
          assert "BUILD_DEFERRED" in apply_log, apply_log
          # still on v2
          assert autoupdate.succeed("cat /var/lib/selfupdate-version").strip() == "2"
          st = status(autoupdate)
          assert st["hold"] is True, st

      with subtest("unhold lets it proceed to v3"):
          autoupdate.succeed("nixos-update unhold")
          autoupdate.succeed("systemctl start nixos-autoupdate-build.service")
          autoupdate.succeed("systemctl start nixos-autoupdate-activate.service")
          autoupdate.wait_until_succeeds("test \"$(cat /var/lib/selfupdate-version)\" = 3", timeout=60)
          st = status(autoupdate)
          assert st["hold"] is False, st
          assert st["applied_commit"] == st["fetched_commit"], st
    '';
}
