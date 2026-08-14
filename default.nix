{
  config,
  pkgs,
  lib,
  ...
}:

let
  cfg = config."nixos-autoupdate";
  inherit (lib) types;

  runtimeInputs =
    with pkgs;
    [
      bash
      git
      jq
      coreutils
      gnugrep
      gnused
      gawk
      iproute2
      nix
      openssh
      systemd
      diffutils
      util-linux # flock, for serialising status.json writes in lib.sh
    ]
    ++ lib.optionals (cfg.ageKeyPath != null) [ age ];

  runtimePath = lib.makeBinPath runtimeInputs;

  # A gate/hook script becomes a store path, or "" when unset.
  optScript =
    name: text:
    lib.optionalString (text != null) "${pkgs.writeShellScript "nixos-autoupdate-${name}" text}";

  releaseFile =
    if cfg.releaseFile != null then cfg.releaseFile else "releases/${config.networking.hostName}.json";

  configEnv = pkgs.writeText "nixos-autoupdate-config.env" ''
    RUNTIME_PATH='${runtimePath}'
    BASH='${pkgs.bash}/bin/bash'
    AU_HOSTNAME='${config.networking.hostName}'
    REPO_URL='${cfg.repoUrl}'
    REPO_PATH='${toString cfg.repoPath}'
    BRANCH='${cfg.branch}'
    RELEASE_FILE='${releaseFile}'
    CACHE_URL='${cfg.cache.url}'
    VERIFY_COMMITS='${lib.boolToString cfg.verifyCommitSignatures}'
    ${
      # These two look symmetric and are not. Do not "fix" one to match the other.
      #
      # ageKeyPath is the host's PRIVATE identity and must stay a plain runtime
      # path: `toString` keeps it a literal string, so nothing copies it into
      # the world-readable store.
      ""
    }AGE_KEY_PATH='${lib.optionalString (cfg.ageKeyPath != null) (toString cfg.ageKeyPath)}'
    ${
      # gitSshKey is age-encrypted ciphertext that travels WITH the system, so it
      # is interpolated rather than toString'd: interpolation carries Nix string
      # context, which is what makes the file a dependency of this config.env and
      # therefore part of the closure. With `toString` the context is stripped,
      # the file is not copied to a target that fetches a pre-built closure, and
      # the check phase dies with "Encrypted SSH key not found".
      ""
    }GIT_SSH_KEY='${lib.optionalString (cfg.gitSshKey != null) "${cfg.gitSshKey}"}'
    ON_GIT_STATUS='${optScript "on-git-status" cfg.onGitStatus}'
    ON_APPLY_STATUS='${optScript "on-apply-status" cfg.onApplyStatus}'
    ON_REBOOT_STATUS='${optScript "on-reboot-status" cfg.onRebootStatus}'
    FETCH_GATE='${optScript "fetch-gate" cfg.fetch.gate}'
    ACTIVATE_GATE='${optScript "activate-gate" cfg.activate.gate}'
    REBOOT_GATE='${optScript "reboot-gate" cfg.reboot.gate}'
    ACTIVATE_MODE='${cfg.activate.mode}'
    REBOOT_ENABLE='${lib.boolToString cfg.reboot.enable}'
  '';

  nixosUpdateCli = pkgs.runCommand "nixos-update" { nativeBuildInputs = [ pkgs.makeWrapper ]; } ''
    mkdir -p $out/bin
    install -m755 ${./scripts/nixos-update} $out/bin/nixos-update
    patchShebangs $out/bin/nixos-update
    wrapProgram $out/bin/nixos-update \
      --prefix PATH : ${
        lib.makeBinPath (
          with pkgs;
          [
            jq
            systemd
            coreutils
            util-linux
          ]
        )
      }
  '';

  # ExecStart for a phase script; scripts export their own PATH from config.env.
  phaseExec = script: "${pkgs.bash}/bin/bash /etc/nixos-autoupdate/${script}";

  commonEnv = {
    HOME = "/root";
    GIT_TERMINAL_PROMPT = "0";
  };

  rebootUnitWanted = cfg.reboot.enable || cfg.onRebootStatus != null;
in

{
  options = {
    nixos-autoupdate = {
      enable = lib.mkEnableOption ''
        Self-updating system that pulls a pre-built system closure from a binary
        cache, as named by a release pointer in git. The host never evaluates or
        builds anything: see DESIGN-v2.md
      '';

      repoUrl = lib.mkOption {
        type = types.str;
        description = "Git repository URL holding the release pointers";
        example = "https://github.com/user/nix-config";
      };

      branch = lib.mkOption {
        type = types.str;
        default = "main";
        description = "Git branch to track";
      };

      releaseFile = lib.mkOption {
        type = types.nullOr types.str;
        default = null;
        description = ''
          Path within the repo of this host's release pointer, a JSON file with
          at least a `storePath` key naming the system closure to run. Defaults
          to "releases/<hostname>.json".

          The pointer may also carry `operation` ("switch" or "boot") to
          override [](#opt-nixos-autoupdate.activate.mode) for one release, and
          `builtFrom.commit` / `builtAt` for provenance.
        '';
        example = "releases/nas.json";
      };

      repoPath = lib.mkOption {
        type = types.path;
        default = "/var/lib/nixos-mgmt/repo";
        description = ''
          Local path for the release repository clone. Cloned with
          `--no-checkout`: the host only reads the pointer file out of the git
          object store and never materialises a working tree.
        '';
      };

      cache = {
        url = lib.mkOption {
          type = types.str;
          default = "";
          description = ''
            Binary cache to fetch system closures from, e.g.
            "https://cache.example.net" or "s3://my-bucket". Added to
            `nix.settings.substituters`. When empty, the fetch phase falls back
            to whatever substituters the system already has configured.
          '';
          example = "https://cache.example.net";
        };
        publicKey = lib.mkOption {
          type = types.nullOr types.str;
          default = null;
          description = ''
            Public key used to verify closures from [](#opt-nixos-autoupdate.cache.url),
            added to `nix.settings.trusted-public-keys`. Signatures are always
            verified; the fetch never passes `--no-check-sigs`.
          '';
          example = "cache.example.net:AbCdEf0123456789...=";
        };
      };

      verifyCommitSignatures = lib.mkOption {
        type = types.bool;
        default = false;
        description = ''
          Require a valid signature on the release-pointer commit before acting
          on it. A signed closure alone does not prove the host was pointed at
          the *right* closure, so signing the pointer closes that gap. Requires
          the allowed signers to be configured for git on the host.
        '';
      };

      ageKeyPath = lib.mkOption {
        type = types.nullOr types.path;
        default = null;
        description = ''
          Path to the Age private key. Used to set SOPS_AGE_KEY_FILE for agenix
          and to decrypt the gitSshKey. Set to null if not using age/agenix.
        '';
      };

      gitSshKey = lib.mkOption {
        type = types.nullOr types.path;
        default = null;
        description = ''
          Path to an age-encrypted SSH private key for git authentication.
          Decrypted at runtime using ageKeyPath. Requires ageKeyPath to be set.
        '';
      };

      check = {
        frequency = lib.mkOption {
          type = types.str;
          default = "*-*-* *:0/10:00";
          description = "How often to fetch and check for updates (systemd OnCalendar format)";
          example = "*-*-* *:*:00";
        };
      };

      fetch = {
        gate = lib.mkOption {
          type = types.nullOr types.lines;
          default = null;
          description = ''
            Shell script deciding whether to download the new system closure now.
            Exit 0 to proceed, non-zero to defer to the next fetch tick. Receives
            the AUTOUPDATE_* environment. Typically used to avoid downloading over
            a metered or busy link. null = always fetch.
          '';
        };
        frequency = lib.mkOption {
          type = types.str;
          default = "*-*-* *:0/10:00";
          description = "How often to (re)attempt a deferred fetch (systemd OnCalendar format)";
        };
      };

      activate = {
        mode = lib.mkOption {
          type = types.enum [
            "switch"
            "boot"
          ];
          default = "switch";
          description = ''
            How to activate a built configuration:
            - "switch": activate live now (switch-to-configuration switch)
            - "boot": only stage it for the next boot (switch-to-configuration boot).
              Zero runtime disruption; ideal for interactive/desktop machines.
          '';
        };
        gate = lib.mkOption {
          type = types.nullOr types.lines;
          default = null;
          description = ''
            Shell script deciding whether to activate now. Exit 0 to proceed,
            non-zero to defer. Receives the AUTOUPDATE_* environment (including
            AUTOUPDATE_REBOOT_REQUIRED, known before activation). null = always.
          '';
        };
        frequency = lib.mkOption {
          type = types.str;
          default = "*-*-* *:0/5:00";
          description = "How often to (re)attempt a deferred activation (systemd OnCalendar format)";
        };
      };

      reboot = {
        enable = lib.mkOption {
          type = types.bool;
          default = false;
          description = ''
            Whether to automatically reboot when an activated update needs a reboot
            to take effect (kernel/initrd/modules/kernel-params changed). When false,
            the reboot sentinel and status are still maintained but no reboot happens
            automatically (`nixos-update reboot` still works).
          '';
        };
        gate = lib.mkOption {
          type = types.nullOr types.lines;
          default = null;
          description = ''
            Shell script deciding whether to reboot now. Exit 0 to proceed, non-zero
            to defer. Receives the AUTOUPDATE_* environment. Typically a maintenance
            window or idle check. null with reboot.enable = reboot as soon as needed.
          '';
        };
        frequency = lib.mkOption {
          type = types.str;
          default = "*-*-* *:0/5:00";
          description = "How often to check whether a pending reboot should happen (systemd OnCalendar format)";
        };
      };

      onGitStatus = lib.mkOption {
        type = types.nullOr types.lines;
        default = null;
        description = ''
          Shell script run after each check. Called with AUTOUPDATE_* environment
          variables. Events: NOOP, UPDATE_FOUND, UPDATE_FAILED.
        '';
      };

      onApplyStatus = lib.mkOption {
        type = types.nullOr types.lines;
        default = null;
        description = ''
          Shell script run after each fetch and activation attempt. Called with
          AUTOUPDATE_* environment variables. Events: FETCH_OK, FETCH_FAILED,
          FETCH_DEFERRED, ACTIVATE_DEFERRED, SUCCESS, APPLY_FAILED.
        '';
      };

      onRebootStatus = lib.mkOption {
        type = types.nullOr types.lines;
        default = null;
        description = ''
          Shell script run on each reboot tick. Called with AUTOUPDATE_* environment
          variables. Events: REBOOT_NEEDED, NO_REBOOT_NEEDED, REBOOT_DEFERRED.
        '';
      };
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.gitSshKey != null -> cfg.ageKeyPath != null;
        message = "nixos-autoupdate: ageKeyPath must be set when gitSshKey is set";
      }
    ];

    warnings = lib.optional (cfg.cache.url != "" && cfg.cache.publicKey == null) ''
      nixos-autoupdate: cache.url is set but cache.publicKey is not. Closures
      from that cache will only be accepted if they are signed by a key this
      host already trusts, so fetches will fail unless the key is configured
      elsewhere.
    '';

    environment.etc."nixos-autoupdate/config.env".source = configEnv;
    environment.etc."nixos-autoupdate/lib.sh".source = ./scripts/lib.sh;
    environment.etc."nixos-autoupdate/check.sh".source = ./scripts/check.sh;
    environment.etc."nixos-autoupdate/fetch.sh".source = ./scripts/fetch.sh;
    environment.etc."nixos-autoupdate/activate.sh".source = ./scripts/activate.sh;
    environment.etc."nixos-autoupdate/apply.sh".source = ./scripts/apply.sh;
    environment.etc."nixos-autoupdate/reboot.sh".source = ./scripts/reboot.sh;

    systemd.timers = {
      nixos-autoupdate-check = {
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnCalendar = cfg.check.frequency;
          Persistent = true;
          RandomizedDelaySec = "60sec";
        };
      };
      nixos-autoupdate-fetch = {
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnCalendar = cfg.fetch.frequency;
          Persistent = true;
        };
      };
      nixos-autoupdate-activate = {
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnCalendar = cfg.activate.frequency;
          Persistent = true;
        };
      };
    }
    // lib.optionalAttrs rebootUnitWanted {
      nixos-autoupdate-reboot = {
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnCalendar = cfg.reboot.frequency;
          Persistent = true;
        };
      };
    };

    systemd.services = {
      nixos-autoupdate-check = {
        description = "nixos-autoupdate: poll release pointer and detect updates";
        environment = commonEnv;
        serviceConfig = {
          Type = "oneshot";
          ExecStart = phaseExec "check.sh";
        };
      };

      nixos-autoupdate-fetch = {
        description = "nixos-autoupdate: fetch the released system closure";
        environment = commonEnv;
        serviceConfig = {
          Type = "oneshot";
          ExecStart = phaseExec "fetch.sh";
        };
      };

      nixos-autoupdate-activate = {
        description = "nixos-autoupdate: activate fetched configuration";
        environment = commonEnv;
        serviceConfig = {
          Type = "oneshot";
          ExecStart = phaseExec "activate.sh";
        };
      };

      nixos-autoupdate-reboot = {
        description = "nixos-autoupdate: perform pending reboot";
        environment = commonEnv;
        serviceConfig = {
          Type = "oneshot";
          ExecStart = phaseExec "reboot.sh";
        };
      };
    };

    # The host only ever downloads closures, so it needs the cache as a
    # substituter and its key as trusted. Signatures are always verified.
    nix.settings = lib.mkMerge [
      (lib.mkIf (cfg.cache.url != "") { substituters = [ cfg.cache.url ]; })
      (lib.mkIf (cfg.cache.publicKey != null) { trusted-public-keys = [ cfg.cache.publicKey ]; })
    ];

    environment.systemPackages = [
      pkgs.git
      nixosUpdateCli
    ];
  };
}
