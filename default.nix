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
    ]
    ++ lib.optionals (cfg.ageKeyPath != null) [ age ];

  runtimePath = lib.makeBinPath runtimeInputs;

  # A gate/hook script becomes a store path, or "" when unset.
  optScript =
    name: text:
    lib.optionalString (text != null) "${pkgs.writeShellScript "nixos-autoupdate-${name}" text}";

  nixBuildFlags = lib.concatStringsSep " " (
    [
      "--cores"
      (toString cfg.build.resources.cores)
    ]
    ++ lib.optionals (cfg.build.resources.maxJobs != null) [
      "--max-jobs"
      (toString cfg.build.resources.maxJobs)
    ]
  );

  configEnv = pkgs.writeText "nixos-autoupdate-config.env" ''
    RUNTIME_PATH='${runtimePath}'
    BASH='${pkgs.bash}/bin/bash'
    AU_HOSTNAME='${config.networking.hostName}'
    REPO_URL='${cfg.repoUrl}'
    REPO_PATH='${toString cfg.repoPath}'
    BRANCH='${cfg.branch}'
    FLAKE_OUTPUT='${cfg.flakeOutput}'
    FLAKE_SUBDIR='${cfg.flakeSubdir}'
    AGE_KEY_PATH='${lib.optionalString (cfg.ageKeyPath != null) (toString cfg.ageKeyPath)}'
    GIT_SSH_KEY='${lib.optionalString (cfg.gitSshKey != null) (toString cfg.gitSshKey)}'
    ON_GIT_STATUS='${optScript "on-git-status" cfg.onGitStatus}'
    ON_APPLY_STATUS='${optScript "on-apply-status" cfg.onApplyStatus}'
    ON_REBOOT_STATUS='${optScript "on-reboot-status" cfg.onRebootStatus}'
    BUILD_GATE='${optScript "build-gate" cfg.build.gate}'
    ACTIVATE_GATE='${optScript "activate-gate" cfg.activate.gate}'
    REBOOT_GATE='${optScript "reboot-gate" cfg.reboot.gate}'
    ACTIVATE_MODE='${cfg.activate.mode}'
    REBOOT_ENABLE='${lib.boolToString cfg.reboot.enable}'
    NIX_BUILD_FLAGS='${nixBuildFlags}'
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
      enable = lib.mkEnableOption "Self-update system that pulls config from git and rebuilds";

      repoUrl = lib.mkOption {
        type = types.str;
        description = "Git repository URL to pull updates from";
        example = "https://github.com/user/nix-config";
      };

      branch = lib.mkOption {
        type = types.str;
        default = "main";
        description = "Git branch to track";
      };

      flakeOutput = lib.mkOption {
        type = types.str;
        default = "nixos";
        description = ''
          Flake output to activate, e.g. "nixosConfigurations.nas" or just "nas".
          The last component is used as the configuration name; the module builds
          `<flake>#nixosConfigurations.<name>.config.system.build.toplevel`.
        '';
        example = "nixosConfigurations.nas";
      };

      repoPath = lib.mkOption {
        type = types.path;
        default = "/var/lib/nixos-mgmt/repo";
        description = "Local path where the git repository is stored";
      };

      flakeSubdir = lib.mkOption {
        type = types.str;
        default = "";
        description = ''
          Subdirectory within the git repo containing the Nix flake to build.
          Use when your flake is not at the repo root, e.g. "hosts/nas".
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

      build = {
        gate = lib.mkOption {
          type = types.nullOr types.lines;
          default = null;
          description = ''
            Shell script deciding whether to build now. Exit 0 to proceed, non-zero
            to defer to the next build tick. Receives the AUTOUPDATE_* environment.
            Typically used to avoid building under load. null = always build.
          '';
        };
        frequency = lib.mkOption {
          type = types.str;
          default = "*-*-* *:0/10:00";
          description = "How often to (re)attempt a deferred build (systemd OnCalendar format)";
        };
        resources = {
          cpuWeight = lib.mkOption {
            type = types.int;
            default = 25;
            description = "systemd CPUWeight for the build unit (1-10000, lower yields under contention)";
          };
          nice = lib.mkOption {
            type = types.int;
            default = 15;
            description = "systemd Nice level for the build unit";
          };
          ioSchedulingClass = lib.mkOption {
            type = types.str;
            default = "idle";
            description = "systemd IOSchedulingClass for the build unit";
          };
          memoryHigh = lib.mkOption {
            type = types.str;
            default = "50%";
            description = "systemd MemoryHigh throttling threshold for the build unit";
          };
          cores = lib.mkOption {
            type = types.int;
            default = 0;
            description = "nix build --cores (0 = all available)";
          };
          maxJobs = lib.mkOption {
            type = types.nullOr types.int;
            default = null;
            description = "nix build --max-jobs (null = nix default)";
          };
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
          Shell script run after each build and activation attempt. Called with
          AUTOUPDATE_* environment variables. Events: BUILD_OK, BUILD_FAILED,
          BUILD_DEFERRED, ACTIVATE_DEFERRED, SUCCESS, APPLY_FAILED.
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

    environment.etc."nixos-autoupdate/config.env".source = configEnv;
    environment.etc."nixos-autoupdate/lib.sh".source = ./scripts/lib.sh;
    environment.etc."nixos-autoupdate/check.sh".source = ./scripts/check.sh;
    environment.etc."nixos-autoupdate/build.sh".source = ./scripts/build.sh;
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
      nixos-autoupdate-build = {
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnCalendar = cfg.build.frequency;
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
        description = "nixos-autoupdate: fetch git repo and detect updates";
        environment = commonEnv;
        serviceConfig = {
          Type = "oneshot";
          ExecStart = phaseExec "check.sh";
        };
      };

      nixos-autoupdate-build = {
        description = "nixos-autoupdate: build pending configuration";
        environment = commonEnv;
        serviceConfig = {
          Type = "oneshot";
          ExecStart = phaseExec "build.sh";
          CPUWeight = cfg.build.resources.cpuWeight;
          IOSchedulingClass = cfg.build.resources.ioSchedulingClass;
          Nice = cfg.build.resources.nice;
          MemoryHigh = cfg.build.resources.memoryHigh;
        };
      };

      nixos-autoupdate-activate = {
        description = "nixos-autoupdate: activate built configuration";
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

    environment.systemPackages = [
      pkgs.git
      nixosUpdateCli
    ];
  };
}
