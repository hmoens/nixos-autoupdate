{ pkgs, lib, ... }:

let
  mkFakeSystem = import ./fake-system.nix { inherit pkgs; };

  # kernel resolves to the booted *initrd*, i.e. differs from the booted kernel
  # => a reboot is required to fully apply this system.
  systemV1 = mkFakeSystem {
    version = "1";
    kernelTarget = "/run/booted-system/initrd";
  };

  cachePrivateKey =
    "nixos-autoupdate-test-1:VA1/Z0atYO68Na+zWJy4+crFrfff7znKkkqYHmfuN8trztmgbe4tmtJRzAJ2M1Mm9XZL0FayMXj38LqcB61qGg==";
  cachePublicKey = "nixos-autoupdate-test-1:a87ZoG3uLZrSUcwCdjNTJvV2S9BWsjF49/C6nAetaho=";

  clientBase =
    { pkgs, ... }:
    {
      imports = [ ../default.nix ];

      virtualisation.writableStore = true;
      nix.settings.experimental-features = [
        "nix-command"
        "flakes"
      ];

      environment.systemPackages = with pkgs; [ age ];
      system.stateVersion = "25.11";
      boot.loader.grub.enable = false;
      fileSystems."/".device = "none";
      networking.useDHCP = true;
      networking.firewall.enable = false;
    };

  commonAutoupdate = {
    enable = true;
    repoUrl = "ssh://git@gitserver/var/lib/git/test-repo.git";
    branch = "main";
    ageKeyPath = "/var/lib/nixos/secrets/age.key";
    gitSshKey = "/var/lib/nixos/secrets/git-ssh-key.age";
    check.frequency = "*-*-* *:*:00";
    cache = {
      url = "http://gitserver";
      publicKey = cachePublicKey;
    };
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

        systemd.tmpfiles.rules = [ "d /var/www/cache 0755 root root -" ];
        services.nginx = {
          enable = true;
          virtualHosts."cache" = {
            default = true;
            listen = [
              {
                addr = "0.0.0.0";
                port = 80;
              }
            ];
            root = "/var/www/cache";
          };
        };

        system.extraDependencies = [ systemV1 ];
        nix.settings.experimental-features = [
          "nix-command"
          "flakes"
        ];

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
        nixos-autoupdate = commonAutoupdate // {
          releaseFile = "releases/autoreboot.json";
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

    # Boot-mode node: stages the new system for next boot, no live switch.
    bootmode =
      { pkgs, ... }:
      {
        imports = [ clientBase ];
        networking.hostName = "bootmode";
        nixos-autoupdate = commonAutoupdate // {
          releaseFile = "releases/bootmode.json";
          activate.mode = "boot";
          reboot.enable = false;
        };
      };
  };

  testScript = ''
    import json, base64

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
    gitserver.wait_for_unit("nginx.service")
    autoreboot.wait_for_unit("multi-user.target")
    bootmode.wait_for_unit("multi-user.target")

    with subtest("Setup git auth for both client nodes"):
        setup_git_auth(autoreboot)
        setup_git_auth(bootmode)

    with subtest("Builder: bare repo + publish the closure to the cache"):
        gitserver.succeed("mkdir -p /var/lib/git")
        gitserver.succeed("git init --bare /var/lib/git/test-repo.git")
        gitserver.succeed("chown -R git:git /var/lib/git")
        gitserver.succeed("git config --global --add safe.directory /var/lib/git/test-repo.git")
        gitserver.succeed(
            "umask 077 && printf '%s' '${cachePrivateKey}' > /root/cache.sec"
        )
        gitserver.succeed(
            "nix copy --to 'file:///var/www/cache?secret-key=/root/cache.sec' ${systemV1}"
        )

    with subtest("Release the same system to both hosts"):
        pointer = {
            "storePath": "${systemV1}",
            "system": "x86_64-linux",
            "builtFrom": {"commit": "deadbeef", "flake": "hosts/test"},
            "builtAt": "2026-08-11T00:00:00Z",
        }
        blob = base64.b64encode(json.dumps(pointer).encode()).decode()
        gitserver.succeed("echo " + blob + " | base64 -d > /tmp/release.json")
        gitserver.succeed(
            "d=$(mktemp -d) && cd \"$d\" && git init && git branch -m main "
            "&& git config user.email test@test.com && git config user.name Test "
            "&& mkdir -p releases "
            "&& cp /tmp/release.json releases/autoreboot.json "
            "&& cp /tmp/release.json releases/bootmode.json "
            "&& git add releases && git commit -m 'release v1' "
            "&& git remote add origin /var/lib/git/test-repo.git "
            "&& git push origin main && rm -rf \"$d\""
        )

    with subtest("autoreboot: fetch + activate creates the reboot sentinel"):
        autoreboot.succeed("nixos-update run")
        autoreboot.wait_until_succeeds("test \"$(cat /var/lib/selfupdate-version)\" = 1", timeout=90)
        st = status(autoreboot)
        assert st["reboot_required"] is True, st
        assert st["applied_path"] == "${systemV1}", st
        autoreboot.succeed("test -f /run/nixos-autoupdate/reboot-required")

    with subtest("autoreboot: reboot phase runs the gate but defers"):
        autoreboot.succeed("systemctl start nixos-autoupdate-reboot.service")
        autoreboot.succeed("test -f /run/nixos-autoupdate/reboot-gate-ran")
        events = autoreboot.succeed("cat /run/nixos-autoupdate/reboot-events.log")
        assert "REBOOT_NEEDED" in events, events
        assert "REBOOT_DEFERRED" in events, events
        # Gate deferred, so the sentinel is still there and no reboot happened.
        autoreboot.succeed("test -f /run/nixos-autoupdate/reboot-required")

    with subtest("bootmode: stages the system for next boot without live switch"):
        bootmode.succeed("nixos-update run")
        bootmode.wait_until_succeeds("test \"$(cat /var/lib/selfupdate-version)\" = 1", timeout=90)
        st = status(bootmode)
        assert st["applied_path"] == "${systemV1}", st
        # No transient live-switch unit is used in boot mode.
        bootmode.fail("systemctl is-active --quiet nixos-autoupdate-switch.service")
  '';
}
