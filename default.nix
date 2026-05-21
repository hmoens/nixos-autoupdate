{
  config,
  pkgs,
  lib,
  ...
}:

let
  cfg = config."nixos-autoupdate";
  inherit (lib) types;

  rebootScriptPart = lib.optionalString (cfg.autoReboot == "script") ''
    script)
      if ${cfg.rebootScript}; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] Reboot script approved: rebooting now..."
        systemctl reboot
      else
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] Reboot script did not approve"
      fi
      ;;
  '';
  updateGitScript = pkgs.writeShellApplication {
    name = "nixos-autoupdate-update-git.sh";
    runtimeInputs = [
      pkgs.git
      pkgs.coreutils
    ]
    ++ lib.optionals (cfg.ageKeyPath != null) [ pkgs.age ];
    text = ''
      set -euo pipefail

      REPO="${cfg.repoPath}"
      STATE_DIR="/var/lib/nixos-mgmt"
      LAST_APPLIED_FILE="$STATE_DIR/last-applied-commit"
      BRANCH="${cfg.branch}"

      log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
      error() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*" >&2; }

      ${lib.optionalString (cfg.ageKeyPath != null) ''
        if [ ! -f "${cfg.ageKeyPath}" ]; then
          error "Age key not found at ${cfg.ageKeyPath}"
          exit 1
        fi
        export SOPS_AGE_KEY_FILE="${cfg.ageKeyPath}"
      ''}

      ${lib.optionalString (cfg.gitSshKey != null) ''
        if [ ! -f "${cfg.gitSshKey}" ]; then
          error "Encrypted SSH key not found at ${cfg.gitSshKey}"
          exit 1
        fi
        SSH_KEY_FILE=$(mktemp)
          trap 'rm -f $SSH_KEY_FILE' EXIT
        age -d -i "${cfg.ageKeyPath}" -o "$SSH_KEY_FILE" "${cfg.gitSshKey}" 2>/dev/null || {
          error "Failed to decrypt SSH key"
          rm -f "$SSH_KEY_FILE"
          exit 1
        }
        chmod 600 "$SSH_KEY_FILE"
        export GIT_SSH_COMMAND="${pkgs.openssh}/bin/ssh -i $SSH_KEY_FILE -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
      ''}

      if ! git -C "$REPO" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        if [ -e "$REPO" ]; then
          log "Existing repo checkout invalid, removing $REPO"
          rm -rf "$REPO"
        fi

        log "Cloning repository..."

        mkdir -p "$(dirname "$REPO")"

        git clone \
          --branch "$BRANCH" \
          "${cfg.repoUrl}" \
          "$REPO"
      fi

      cd "$REPO"

      log "Fetching latest changes..."
      git fetch --prune origin

      REMOTE=$(git rev-parse "origin/$BRANCH")
      LOCAL=$(git rev-parse HEAD)
      LAST_APPLIED=$(cat "$LAST_APPLIED_FILE" 2>/dev/null || echo "none")

      if [ "$REMOTE" = "$LAST_APPLIED" ]; then
        log "No updates available (already applied $REMOTE)"
        exit 10
      fi

      log "Update found:"
      log "  current checkout: $LOCAL"
      log "  remote:           $REMOTE"
      log "  last applied:     $LAST_APPLIED"

      log "Checking out $REMOTE..."
      git reset --hard "$REMOTE"
      git clean -fd
    '';
  };

  applyGitScript = pkgs.writeShellApplication {
    name = "nixos-autoupdate-apply-git.sh";
    runtimeInputs = with pkgs; [
      git
      coreutils
      gnugrep
      nix
      nixos-rebuild
    ];
    text = ''
      set -euo pipefail

      REPO="${cfg.repoPath}"
      STATE_DIR="/var/lib/nixos-mgmt"
      LAST_APPLIED_FILE="$STATE_DIR/last-applied-commit"

      log() {
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
      }

      cd "$REPO"

      REMOTE=$(git rev-parse HEAD)

      FLAKE_TARGET="$(echo "${cfg.flakeOutput}" | grep -oE '[^.]+$' || echo "${cfg.flakeOutput}")"

      FLAKE_WORKTREE="$REPO"
      FLAKE_SUBDIR="${cfg.flakeSubdir}"

      if [ -n "$FLAKE_SUBDIR" ]; then
        FLAKE_PATH="$FLAKE_WORKTREE/$FLAKE_SUBDIR"
      else
        FLAKE_PATH="$FLAKE_WORKTREE"
      fi

      # shellcheck disable=SC2034
      FLAKE_REF="$FLAKE_PATH#$FLAKE_TARGET"

      log "Building new configuration..."

      ${cfg.rebuildCommand}

      echo "$REMOTE" > "$LAST_APPLIED_FILE"

      log "Update successful"

      SENTINEL="/run/nixos-autoupdate/reboot-required"

      BOOTED=$(readlink /run/booted-system 2>/dev/null || echo "none")
      CURRENT=$(readlink /run/current-system 2>/dev/null || echo "none")

      if [ "$BOOTED" != "$CURRENT" ]; then
        mkdir -p "$(dirname "$SENTINEL")"
        touch "$SENTINEL"

        log "Reboot required: sentinel created"
      fi
    '';
  };
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
          The last component is used as the hostname in the flake reference.
        '';
        example = "nixosConfigurations.nas";
      };

      repoPath = lib.mkOption {
        type = types.path;
        default = "/var/lib/nixos-mgmt/repo";
        description = "Local path where the git repository is stored";
      };

      frequency = lib.mkOption {
        type = types.str;
        default = "*-*-* *:0/10:00";
        description = "How often to check for updates (systemd OnCalendar format)";
        example = "*-*-* *:0/10:00";
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

      flakeSubdir = lib.mkOption {
        type = types.str;
        default = "";
        description = ''
          Subdirectory within the git repo containing the Nix flake to build.
          Use when your flake is not at the repo root.
          Example: "hosts/nas" if the flake is at <repo>/hosts/nas/flake.nix.
        '';
      };

      rebuildCommand = lib.mkOption {
        type = types.str;
        default = "nixos-rebuild switch --flake \"$FLAKE_REF\" --fast";
        description = ''
          Command to rebuild the system. Available shell variables:
          - $FLAKE_WORKTREE: path to the checked-out git worktree
          - $FLAKE_TARGET: the flake output target (e.g. "nas")
          - $FLAKE_SUBDIR: the flake subdirectory (e.g. "hosts/nas"), or empty
          - $FLAKE_REF: "$FLAKE_WORKTREE[/$FLAKE_SUBDIR]#$FLAKE_TARGET" (ready to use as --flake arg)
        '';
        example = ''
          nixos-rebuild switch --flake "$FLAKE_REF" --fast
        '';
      };

      notifyOnFailure = lib.mkOption {
        type = types.bool;
        default = false;
        description = "Send notification on failed updates (requires configured notifier)";
      };

      autoReboot = lib.mkOption {
        type = types.enum [
          "never"
          "always"
          "script"
        ];
        default = "never";
        description = ''
          Whether to automatically reboot when an update requires it
          (i.e. /run/booted-system differs from /run/current-system).

          - "never": just log that a reboot is needed
          - "always": reboot immediately after a successful update
          - "script": run a custom script to decide when to reboot
        '';
      };

      rebootScript = lib.mkOption {
        type = types.nullOr types.path;
        default = null;
        description = ''
          Path to a script that determines when to reboot. Only used when
          autoReboot = "script". Called by the reboot service when a
          reboot is pending. Exit 0 to approve immediate reboot, non-zero
          to skip (the next timer tick will retry).
        '';
      };

      rebootFrequency = lib.mkOption {
        type = types.str;
        default = "*-*-* *:*:00";
        description = ''
          How often to check if a pending reboot should be performed
          (systemd OnCalendar format). Only applies when autoReboot is
          not "never".
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
      {
        assertion = cfg.autoReboot == "script" -> cfg.rebootScript != null;
        message = "nixos-autoupdate: rebootScript must be set when autoReboot is set to 'script'";
      }
    ];

    environment.etc."nixos-autoupdate/update-git.sh".source =
      "${updateGitScript}/bin/nixos-autoupdate-update-git.sh";

    environment.etc."nixos-autoupdate/apply-git.sh".source =
      "${applyGitScript}/bin/nixos-autoupdate-apply-git.sh";

    systemd = {
      timers = {
        nixos-autoupdate = {
          wantedBy = [ "multi-user.target" ];
          timerConfig = {
            OnCalendar = cfg.frequency;
            Persistent = true;
            RandomizedDelaySec = "60sec";
          };
        };
      }
      // lib.optionalAttrs (cfg.autoReboot != "never") {
        nixos-autoupdate-reboot = {
          wantedBy = [ "multi-user.target" ];
          timerConfig = {
            OnCalendar = cfg.rebootFrequency;
            Persistent = true;
          };
        };
      };

      services = {
        nixos-autoupdate = {
          description = "Self-update NixOS configuration from git";
          path =
            with pkgs;
            [
              git
              nix
              nixos-rebuild
              coreutils
              gnugrep
              openssh
              gnused
            ]
            ++ lib.optionals (cfg.ageKeyPath != null) [ age ];

          environment = {
            HOME = "/root";
            GIT_TERMINAL_PROMPT = "0";
          };

          serviceConfig = {
            Type = "oneshot";
            ProtectSystem = "full";
            PrivateTmp = true;
            NoNewPrivileges = false;
            SuccessExitStatus = [ 10 ];
          };

          script = ''
            set -euo pipefail

            log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

            /etc/nixos-autoupdate/update-git.sh

            log "Starting detached apply job..."

            systemd-run \
              --unit=nixos-autoupdate-apply-$(date +%s) \
              /etc/nixos-autoupdate/apply-git.sh
          '';
        };
      }
      // lib.optionalAttrs (cfg.autoReboot != "never") {
        nixos-autoupdate-reboot = {
          description = "NixOS self-update: perform pending reboot";
          path = with pkgs; [ coreutils ];
          serviceConfig.Type = "oneshot";
          script = ''
            set -euo pipefail

            SENTINEL="/run/nixos-autoupdate/reboot-required"
            if [ ! -f "$SENTINEL" ]; then
              exit 0
            fi

            if systemctl is-active --quiet nixos-autoupdate.service; then
              exit 0
            fi

            BOOTED=$(readlink /run/booted-system 2>/dev/null || echo "none")
            CURRENT=$(readlink /run/current-system 2>/dev/null || echo "none")
            if [ "$BOOTED" = "$CURRENT" ]; then
              rm -f "$SENTINEL"
              exit 0
            fi

            case "${cfg.autoReboot}" in
              always)
                echo "[$(date '+%Y-%m-%d %H:%M:%S')] autoReboot=always: rebooting now..."
                systemctl reboot
                ;;
              ${rebootScriptPart}
            esac
          '';
        };
      };
    };

    environment.systemPackages = with pkgs; [ git ];
  };
}
