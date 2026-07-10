{ pkgs, lib, ... }:

let
  versionV1 = pkgs.writeText "version-v1" "1\n";

  # Fake toplevel whose kernel resolves to the booted *initrd* => differs from
  # the booted kernel => reboot required. See tests/fake-system-flake.nix.
  testFlake = pkgs.replaceVars ./fake-system-flake.nix {
    bash = pkgs.bash;
    coreutils = pkgs.coreutils;
    system = pkgs.stdenv.hostPlatform.system;
    kerneltarget = "/run/booted-system/initrd";
  };

  clientBase =
    { pkgs, ... }:
    {
      imports = [ ../default.nix ];

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
      networking.useDHCP = true;
      networking.firewall.enable = false;
    };
in

{
  name = "nixos-autoupdate-reboot";

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

    # Live-switch node with auto-reboot enabled but a gate that always defers,
    # so the VM never actually reboots.
    autoreboot =
      { pkgs, ... }:
      {
        imports = [ clientBase ];
        networking.hostName = "autoreboot";
        nixos-autoupdate = {
          enable = true;
          repoUrl = "ssh://git@gitserver/var/lib/git/test-repo.git";
          branch = "main";
          flakeOutput = "nixosConfigurations.autoupdate";
          ageKeyPath = "/var/lib/nixos/secrets/age.key";
          gitSshKey = "/var/lib/nixos/secrets/git-ssh-key.age";
          check.frequency = "*-*-* *:*:00";
          activate.mode = "switch";
          reboot = {
            enable = true;
            gate = ''
              mkdir -p /run/nixos-autoupdate
              touch /run/nixos-autoupdate/reboot-gate-ran
              exit 1
            '';
          };
          onRebootStatus = ''
            mkdir -p /run/nixos-autoupdate
            echo "$AUTOUPDATE_EVENT $AUTOUPDATE_STATUS reboot=$AUTOUPDATE_REBOOT_REQUIRED" \
              >> /run/nixos-autoupdate/reboot-events.log
          '';
        };
      };

    # Boot-mode node: stages the new config for next boot, no live switch.
    bootmode =
      { pkgs, ... }:
      {
        imports = [ clientBase ];
        networking.hostName = "bootmode";
        nixos-autoupdate = {
          enable = true;
          repoUrl = "ssh://git@gitserver/var/lib/git/test-repo.git";
          branch = "main";
          flakeOutput = "nixosConfigurations.autoupdate";
          ageKeyPath = "/var/lib/nixos/secrets/age.key";
          gitSshKey = "/var/lib/nixos/secrets/git-ssh-key.age";
          check.frequency = "*-*-* *:*:00";
          activate.mode = "boot";
          reboot.enable = false;
        };
      };
  };

  testScript = ''
    import json

    def status(node):
        return json.loads(node.succeed("nixos-update status --json"))

    def setup_git_auth(node):
        node.succeed("mkdir -p /var/lib/nixos/secrets")
        node.succeed("chmod 700 /var/lib/nixos/secrets")
        node.succeed("age-keygen -o /var/lib/nixos/secrets/age.key 2>&1")
        node.succeed("chmod 600 /var/lib/nixos/secrets/age.key")
        pubkey = node.succeed("age-keygen -y /var/lib/nixos/secrets/age.key").strip()
        node.succeed("ssh-keygen -t ed25519 -N \"\" -f /var/lib/nixos/secrets/git-ssh-key")
        node.succeed(
            'age -e -r "' + pubkey + '" -o /var/lib/nixos/secrets/git-ssh-key.age '
            "/var/lib/nixos/secrets/git-ssh-key"
        )
        node.succeed("chmod 600 /var/lib/nixos/secrets/git-ssh-key.age")
        ssh_pubkey = node.succeed("cat /var/lib/nixos/secrets/git-ssh-key.pub").strip()
        gitserver.succeed("mkdir -p ~git/.ssh")
        gitserver.succeed('echo "' + ssh_pubkey + '" >> ~git/.ssh/authorized_keys')
        gitserver.succeed("chmod 700 ~git/.ssh")
        gitserver.succeed("chmod 600 ~git/.ssh/authorized_keys")
        gitserver.succeed("chown -R git:git ~git")

    start_all()

    gitserver.wait_for_unit("multi-user.target")
    autoreboot.wait_for_unit("multi-user.target")
    bootmode.wait_for_unit("multi-user.target")

    with subtest("Setup git auth for both client nodes"):
        setup_git_auth(autoreboot)
        setup_git_auth(bootmode)

    with subtest("Setup gitserver: bare git repo and push v1"):
        gitserver.succeed("mkdir -p /var/lib/git")
        gitserver.succeed("git init --bare /var/lib/git/test-repo.git")
        gitserver.succeed("chown -R git:git /var/lib/git")
        gitserver.copy_from_host_via_shell("${testFlake}", "/tmp/flake.nix")
        gitserver.copy_from_host_via_shell("${versionV1}", "/tmp/version")
        gitserver.succeed("git config --global --add safe.directory /var/lib/git/test-repo.git")
        gitserver.succeed(
            "d=$(mktemp -d) && cd \"$d\" && git init && git branch -m main "
            "&& git config user.email test@test.com && git config user.name Test "
            "&& cp /tmp/flake.nix flake.nix && cp /tmp/version version "
            "&& git add flake.nix version && git commit -m 'config v1' "
            "&& git remote add origin /var/lib/git/test-repo.git "
            "&& git push origin main && rm -rf \"$d\""
        )

    with subtest("autoreboot: build + activate creates the reboot sentinel"):
        autoreboot.succeed("nixos-update run")
        autoreboot.wait_until_succeeds("test \"$(cat /var/lib/selfupdate-version)\" = 1", timeout=90)
        st = status(autoreboot)
        assert st["reboot_required"] is True, st
        assert st["applied_commit"] == st["fetched_commit"], st
        autoreboot.succeed("test -f /run/nixos-autoupdate/reboot-required")

    with subtest("autoreboot: reboot phase runs the gate but defers"):
        autoreboot.succeed("systemctl start nixos-autoupdate-reboot.service")
        autoreboot.succeed("test -f /run/nixos-autoupdate/reboot-gate-ran")
        events = autoreboot.succeed("cat /run/nixos-autoupdate/reboot-events.log")
        assert "REBOOT_NEEDED" in events, events
        assert "REBOOT_DEFERRED" in events, events
        # Gate deferred, so the sentinel is still there and no reboot happened.
        autoreboot.succeed("test -f /run/nixos-autoupdate/reboot-required")

    with subtest("bootmode: stages the config for next boot without live switch"):
        bootmode.succeed("nixos-update run")
        bootmode.wait_until_succeeds("test \"$(cat /var/lib/selfupdate-version)\" = 1", timeout=90)
        st = status(bootmode)
        assert st["applied_commit"] == st["fetched_commit"], st
        # No transient live-switch unit is used in boot mode.
        bootmode.fail("systemctl is-active --quiet nixos-autoupdate-switch.service")
    '';
}
