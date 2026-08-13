{ pkgs, lib, ... }:

let
  mkFakeSystem = import ./fake-system.nix { inherit pkgs; };

  # Config-only changes: kernel matches the booted one => no reboot required.
  systemV1 = mkFakeSystem { version = "1"; };
  systemV2 = mkFakeSystem { version = "2"; };
  systemV3 = mkFakeSystem { version = "3"; };

  # Test-only binary cache keypair (see tests/README rationale: committing a
  # throwaway key keeps the test hermetic and avoids import-from-derivation).
  cachePrivateKey =
    "nixos-autoupdate-test-1:VA1/Z0atYO68Na+zWJy4+crFrfff7znKkkqYHmfuN8trztmgbe4tmtJRzAJ2M1Mm9XZL0FayMXj38LqcB61qGg==";
  cachePublicKey = "nixos-autoupdate-test-1:a87ZoG3uLZrSUcwCdjNTJvV2S9BWsjF49/C6nAetaho=";
in

{
  name = "nixos-autoupdate-integration";

  nodes = {
    # Stands in for the builder + infrastructure: serves the release repo over
    # SSH and the binary cache over HTTP. It holds the built system closures
    # (system.extraDependencies) exactly as a real builder would.
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

        # The binary cache: a plain file:// store served as static files.
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

        system.extraDependencies = [
          systemV1
          systemV2
          systemV3
        ];
        nix.settings.experimental-features = [
          "nix-command"
          "flakes"
        ];

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
          ageKeyPath = "/var/lib/nixos/secrets/age.key";
          gitSshKey = "/var/lib/nixos/secrets/git-ssh-key.age";
          check.frequency = "*-*-* *:*:00";

          cache = {
            url = "http://gitserver";
            publicKey = cachePublicKey;
          };

          onGitStatus = ''
            mkdir -p /run/nixos-autoupdate
            {
              echo "EVENT=$AUTOUPDATE_EVENT"
              echo "STATUS=$AUTOUPDATE_STATUS"
              echo "HOSTNAME=$AUTOUPDATE_HOSTNAME"
              echo "PATH_=$AUTOUPDATE_STORE_PATH"
              echo "PHASE=$AUTOUPDATE_PHASE"
            } > /run/nixos-autoupdate/on-git-status.env
          '';
          onApplyStatus = ''
            mkdir -p /run/nixos-autoupdate
            echo "$AUTOUPDATE_EVENT $AUTOUPDATE_STATUS reboot=$AUTOUPDATE_REBOOT_REQUIRED" \
              >> /run/nixos-autoupdate/apply-events.log
          '';
        };

        # The target must be able to receive closures it did not build.
        virtualisation.writableStore = true;
        nix.settings.experimental-features = [
          "nix-command"
          "flakes"
        ];

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
      gitserver.wait_for_unit("nginx.service")
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

      with subtest("Setup gitserver: bare release repo"):
          gitserver.succeed("mkdir -p /var/lib/git")
          gitserver.succeed("git init --bare /var/lib/git/test-repo.git")
          gitserver.succeed("chown -R git:git /var/lib/git")
          gitserver.succeed("git config --global --add safe.directory /var/lib/git/test-repo.git")

      with subtest("Builder: publish the system closures to the binary cache"):
          # Signing key never leaves the builder; hosts only get the public key.
          gitserver.succeed(
              "umask 077 && printf '%s' '${cachePrivateKey}' > /root/cache.sec"
          )
          for path in ["${systemV1}", "${systemV2}", "${systemV3}"]:
              gitserver.succeed(
                  "nix copy --to 'file:///var/www/cache?secret-key=/root/cache.sec' " + path
              )
          # The cache is now a real, servable binary cache.
          gitserver.succeed("test -f /var/www/cache/nix-cache-info")

      def push_release(store_path, message, operation=None):
          """Write releases/autoupdate.json and push it — this is what CI does."""
          pointer = {
              "storePath": store_path,
              "system": "x86_64-linux",
              "builtFrom": {"commit": "deadbeef", "flake": "hosts/autoupdate"},
              "builtAt": "2026-08-11T00:00:00Z",
          }
          if operation is not None:
              pointer["operation"] = operation
          import base64
          blob = base64.b64encode(json.dumps(pointer).encode()).decode()
          gitserver.succeed("echo " + blob + " | base64 -d > /tmp/release.json")
          gitserver.succeed(
              "d=$(mktemp -d) && cd \"$d\" "
              "&& git clone -b main /var/lib/git/test-repo.git . 2>/dev/null "
              "|| { git init && git branch -m main && git remote add origin /var/lib/git/test-repo.git; } "
              "&& git config user.email test@test.com && git config user.name Test "
              "&& mkdir -p releases && cp /tmp/release.json releases/autoupdate.json "
              "&& git add releases/autoupdate.json "
              "&& git commit -m '" + message + "' "
              "&& git push origin main && rm -rf \"$d\""
          )

      with subtest("Release v1"):
          push_release("${systemV1}", "release v1")

      with subtest("The target does not have the closure yet"):
          autoupdate.fail("nix-store --check-validity ${systemV1}")

      with subtest("check records the desired store path"):
          autoupdate.succeed("systemctl start nixos-autoupdate-check.service")
          result = autoupdate.succeed("cat /run/nixos-autoupdate/on-git-status.env")
          assert "EVENT=UPDATE_FOUND" in result, result
          assert "STATUS=OK" in result
          assert "PHASE=check" in result
          st = status(autoupdate)
          assert st["desired_path"] == "${systemV1}", st
          # check must not download anything.
          autoupdate.fail("nix-store --check-validity ${systemV1}")

      with subtest("fetch downloads the closure from the cache"):
          autoupdate.succeed("systemctl start nixos-autoupdate-fetch.service")
          autoupdate.succeed("nix-store --check-validity ${systemV1}")
          st = status(autoupdate)
          assert st["fetched_path"] == "${systemV1}", st
          assert st["reboot_required"] is False, st
          apply_log = autoupdate.succeed("cat /run/nixos-autoupdate/apply-events.log")
          assert "FETCH_OK OK" in apply_log, apply_log

      with subtest("activate switches to the fetched system"):
          autoupdate.succeed("systemctl start nixos-autoupdate-activate.service")
          autoupdate.wait_until_succeeds("test \"$(cat /var/lib/selfupdate-version)\" = 1", timeout=30)
          st = status(autoupdate)
          assert st["applied_path"] == "${systemV1}", st
          apply_log = autoupdate.succeed("cat /run/nixos-autoupdate/apply-events.log")
          assert "SUCCESS OK" in apply_log, apply_log

      with subtest("no reboot required for a config-only change"):
          st = status(autoupdate)
          assert st["reboot_required"] is False, st
          autoupdate.fail("test -f /run/nixos-autoupdate/reboot-required")

      with subtest("Release v2 and run the whole pipeline via the CLI"):
          push_release("${systemV2}", "release v2")
          autoupdate.succeed("nixos-update run")
          autoupdate.wait_until_succeeds("test \"$(cat /var/lib/selfupdate-version)\" = 2", timeout=60)
          st = status(autoupdate)
          assert st["applied_path"] == "${systemV2}", st
          assert st["applied_path"] == st["desired_path"], st

      with subtest("hold defers the fetch"):
          autoupdate.succeed("nixos-update hold 'testing'")
          push_release("${systemV3}", "release v3")
          autoupdate.succeed("systemctl start nixos-autoupdate-check.service")
          autoupdate.succeed("rm -f /run/nixos-autoupdate/apply-events.log")
          autoupdate.succeed("systemctl start nixos-autoupdate-fetch.service")
          apply_log = autoupdate.succeed("cat /run/nixos-autoupdate/apply-events.log")
          assert "FETCH_DEFERRED" in apply_log, apply_log
          # nothing downloaded, still on v2
          autoupdate.fail("nix-store --check-validity ${systemV3}")
          assert autoupdate.succeed("cat /var/lib/selfupdate-version").strip() == "2"
          st = status(autoupdate)
          assert st["hold"] is True, st

      with subtest("unhold lets it proceed to v3"):
          autoupdate.succeed("nixos-update unhold")
          autoupdate.succeed("systemctl start nixos-autoupdate-fetch.service")
          autoupdate.succeed("systemctl start nixos-autoupdate-activate.service")
          autoupdate.wait_until_succeeds("test \"$(cat /var/lib/selfupdate-version)\" = 3", timeout=60)
          st = status(autoupdate)
          assert st["hold"] is False, st
          assert st["applied_path"] == "${systemV3}", st
    '';
}
