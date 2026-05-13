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
        description = "Local path where the git repository is stored (bare clone)";
      };

      frequency = lib.mkOption {
        type = types.str;
        default = "10min";
        description = "How often to check for updates (systemd OnCalendar format)";
        example = "10min";
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
        default = "nixos-rebuild switch --flake $FLAKE_REF --fast";
        description = ''
          Command to rebuild the system. Available shell variables:
          - $FLAKE_WORKTREE: path to the checked-out git worktree
          - $FLAKE_TARGET: the flake output target (e.g. "nas")
          - $FLAKE_SUBDIR: the flake subdirectory (e.g. "hosts/nas"), or empty
          - $FLAKE_REF: "$FLAKE_WORKTREE[/$FLAKE_SUBDIR]#$FLAKE_TARGET" (ready to use as --flake arg)
        '';
        example = ''
          nixos-rebuild switch --flake $FLAKE_REF --fast
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
        default = "1min";
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

    systemd = {
      timers = {
        nixos-autoupdate = {
          wantedBy = [ "multi-user.target" ];
          timerConfig = {
            OnCalendar = "*-*-* *:*/${cfg.frequency}";
            Persistent = true;
            RandomizedDelaySec = "60sec";
          };
        };
      }
      // lib.optionalAttrs (cfg.autoReboot != "never") {
        nixos-autoupdate-reboot = {
          wantedBy = [ "multi-user.target" ];
          timerConfig = {
            OnCalendar = "*-*-* *:*/${cfg.rebootFrequency}";
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
          };

          script = ''
            set -euo pipefail

            REPO="${cfg.repoPath}"
            FLAKE_OUTPUT="${cfg.flakeOutput}"
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
              trap "rm -f $SSH_KEY_FILE" EXIT
              age -d -i "${cfg.ageKeyPath}" -o "$SSH_KEY_FILE" "${cfg.gitSshKey}" 2>/dev/null || {
                error "Failed to decrypt SSH key"
                rm -f "$SSH_KEY_FILE"
                exit 1
              }
              chmod 600 "$SSH_KEY_FILE"
              export GIT_SSH_COMMAND="${pkgs.openssh}/bin/ssh -i $SSH_KEY_FILE -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
            ''}

            if ! git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1; then
              log "Cloning repository..."
              mkdir -p "$(dirname "$REPO")"
              git clone --bare --branch "$BRANCH" "${cfg.repoUrl}" "$REPO"
            fi

            log "Checking for updates..."
            cd "$REPO"
            git fetch origin "$BRANCH"

            CURRENT=$(git rev-parse HEAD 2>/dev/null || echo "none")
            REMOTE=$(git rev-parse FETCH_HEAD 2>/dev/null || echo "none")

            if [ "$CURRENT" = "$REMOTE" ]; then
              log "No updates available (already at $CURRENT)"
              exit 0
            fi

            log "Update found: $CURRENT -> $REMOTE"

            WORK_DIR=$(mktemp -d)
            trap "rm -rf $WORK_DIR" EXIT
            git worktree add "$WORK_DIR" FETCH_HEAD
            chmod 755 "$WORK_DIR"

            FLAKE_WORKTREE="$WORK_DIR"
            FLAKE_TARGET="$(echo "$FLAKE_OUTPUT" | grep -oE '[^.]+$' || echo "$FLAKE_OUTPUT")"
            FLAKE_SUBDIR="${cfg.flakeSubdir}"
            if [ -n "$FLAKE_SUBDIR" ]; then
              FLAKE_REF="$FLAKE_WORKTREE/$FLAKE_SUBDIR#$FLAKE_TARGET"
            else
              FLAKE_REF="$FLAKE_WORKTREE#$FLAKE_TARGET"
            fi

            log "Building new configuration..."
            if ! eval "${cfg.rebuildCommand}" 2>&1 | tee /tmp/nixos-rebuild.log; then
              error "Rebuild failed. Log:"
              cat /tmp/nixos-rebuild.log >&2
              exit 1
            fi

            log "Update successful!"

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
