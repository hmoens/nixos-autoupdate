{
  config,
  pkgs,
  lib,
  ...
}:

let
  cfg = config."nixos-selfupdate";
  inherit (lib) types;
in

{
  options = {
    nixos-selfupdate = {
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

      rebuildCommand = lib.mkOption {
        type = types.str;
        default = "nixos-rebuild switch --flake $FLAKE_REF --fast";
        description = ''
          Command to rebuild the system. Available shell variables:
          - $FLAKE_WORKTREE: path to the checked-out git worktree
          - $FLAKE_TARGET: the flake output target (e.g. "nas")
          - $FLAKE_REF: "$FLAKE_WORKTREE#$FLAKE_TARGET" (ready to use as --flake arg)
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
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.gitSshKey != null -> cfg.ageKeyPath != null;
        message = "nixos-selfupdate: ageKeyPath must be set when gitSshKey is set";
      }
    ];

    systemd = {
      timers.nixos-selfupdate = {
        wantedBy = [ "multi-user.target" ];
        timerConfig = {
          OnCalendar = "*-*-* *:*/${cfg.frequency}";
          Persistent = true;
          RandomizedDelaySec = "60sec";
        };
      };

      services.nixos-selfupdate = {
        description = "Self-update NixOS configuration from git";
        path =
          with pkgs;
          [
            git
            nix
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

          if [ ! -d "$REPO/.git" ]; then
            log "Cloning repository..."
            mkdir -p "$(dirname "$REPO")"
            git clone --bare --branch "$BRANCH" "${cfg.repoUrl}" "$REPO"
          fi

          log "Checking for updates..."
          cd "$REPO"
          git fetch origin "$BRANCH"

          CURRENT=$(git rev-parse HEAD 2>/dev/null || echo "none")
          REMOTE=$(git rev-parse "origin/$BRANCH" 2>/dev/null || echo "none")

          if [ "$CURRENT" = "$REMOTE" ]; then
            log "No updates available (already at $CURRENT)"
            exit 0
          fi

          log "Update found: $CURRENT -> $REMOTE"

          WORK_DIR=$(mktemp -d)
          trap "rm -rf $WORK_DIR" EXIT
          git worktree add "$WORK_DIR" "$REMOTE" 2>/dev/null || git worktree add "$WORK_DIR" "origin/$BRANCH"
          chmod 755 "$WORK_DIR"

          FLAKE_WORKTREE="$WORK_DIR"
          FLAKE_TARGET="$(echo "$FLAKE_OUTPUT" | grep -oE '[^.]+$' || echo "$FLAKE_OUTPUT")"
          FLAKE_REF="$FLAKE_WORKTREE#$FLAKE_TARGET"

          log "Building new configuration..."
          if ! ${cfg.rebuildCommand} 2>&1 | tee /tmp/nixos-rebuild.log; then
            error "Rebuild failed. Log:"
            cat /tmp/nixos-rebuild.log >&2
            exit 1
          fi

          log "Update successful!"
        '';
      };
    };

    environment.systemPackages = with pkgs; [ git ];
  };
}
