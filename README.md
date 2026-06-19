# nixos-autoupdate

A NixOS module that periodically pulls configuration from a git repository and rebuilds the system. Supports age-encrypted SSH keys for private repos and automatic reboot when the kernel/systemd changes.

## Usage

```nix
{
  inputs.nixos-autoupdate.url = "github:youruser/nixos-autoupdate";

  outputs = { self, nixos-autoupdate, ... }: {
    nixosConfigurations.myhost = nixpkgs.lib.nixosSystem {
      modules = [
        nixos-autoupdate.nixosModules.default
        ({ ... }: {
          nixos-selfupdate = {
            enable = true;
            repoUrl = "ssh://git@github.com/youruser/nix-config";
            branch = "main";
            flakeOutput = "nixosConfigurations.myhost";
            frequency = "10min";
            ageKeyPath = "/var/lib/nixos/secrets/age.key";
            gitSshKey = "/var/lib/nixos/secrets/git-ssh-key.age";
          };
        })
      ];
    };
  };
}
```

## Options

| Option            | Type             | Default                                            | Description                                   |
| ----------------- | ---------------- | -------------------------------------------------- | --------------------------------------------- |
| `enable`          | bool             | `false`                                            | Enable the module                             |
| `repoUrl`         | string           | —                                                  | Git repository URL                            |
| `branch`          | string           | `"main"`                                           | Branch to track                               |
| `flakeOutput`     | string           | `"nixos"`                                          | Flake output to activate                      |
| `repoPath`        | path             | `"/var/lib/nixos-mgmt/repo"`                       | Local bare clone path                         |
| `frequency`       | string           | `"10min"`                                          | Check interval (systemd timer format)         |
| `ageKeyPath`      | nullOr path      | `null`                                             | Age private key path (for agenix + gitSshKey) |
| `gitSshKey`       | nullOr path      | `null`                                             | Age-encrypted SSH key for git auth            |
| `rebuildCommand`  | string           | `"nixos-rebuild switch --flake $FLAKE_REF --fast"` | Command to rebuild the system                 |
| `onGitStatus`     | nullOr lines     | `null`                                             | Script run after git fetch with `AUTOUPDATE_EVENT`/`AUTOUPDATE_STATUS` etc. |
| `onApplyStatus`   | nullOr lines     | `null`                                             | Script run after rebuild with `AUTOUPDATE_EVENT`/`AUTOUPDATE_STATUS` etc. |
| `onRebootStatus`  | nullOr lines     | `null`                                             | Script run on each reboot timer tick with `AUTOUPDATE_EVENT`/`AUTOUPDATE_STATUS` etc. |
| `notifyOnFailure` | bool             | `false`                                            | Notify on failures (requires notifier)        |
| `autoReboot`      | enum             | `"never"`                                          | Auto-reboot policy: `"never"`, `"always"`, or `"script"` |
| `rebootScript`    | nullOr path      | `null`                                             | Custom script for reboot timing (only with `autoReboot = "script"`) |
| `rebootFrequency` | string           | `"1min"`                                           | How often to check for pending reboot (systemd timer format, only when `autoReboot != "never"`) |

### Status Hooks

Each hook fires independently at a different stage of the update cycle and receives context via environment variables. All scripts must be POSIX `sh` compatible.

| Option             | Fires when                                      | Key env vars                                                                 |
| ------------------ | ----------------------------------------------- | ---------------------------------------------------------------------------- |
| `onGitStatus`      | After git fetch, before rebuild                 | `AUTOUPDATE_EVENT` `AUTOUPDATE_STATUS` `AUTOUPDATE_CHECKED_OUT_COMMIT`       |
| `onApplyStatus`    | After `nixos-rebuild switch` completes          | `AUTOUPDATE_EVENT` `AUTOUPDATE_STATUS` `AUTOUPDATE_CHECKED_OUT_COMMIT` `AUTOUPDATE_REBOOT_REQUIRED` |
| `onRebootStatus`   | On every reboot timer tick (regardless of sentinel) | `AUTOUPDATE_EVENT` `AUTOUPDATE_STATUS` `AUTOUPDATE_REBOOT_REQUIRED` |

**Common env vars available in all hooks:**

| Variable                     | Description                                      |
| ---------------------------- | ------------------------------------------------ |
| `AUTOUPDATE_HOSTNAME`        | NixOS `networking.hostName`                      |
| `AUTOUPDATE_HOST_IP`         | IPv4 address of `AUTOUPDATE_HOSTNAME` (`hostname -I`) |
| `AUTOUPDATE_EVENT`           | Machine-readable event code                      |
| `AUTOUPDATE_STATUS`          | Machine-readable status code                     |
| `AUTOUPDATE_CHECKED_OUT_COMMIT` | Git HEAD commit at time of event (SHA)         |
| `AUTOUPDATE_REBOOT_REQUIRED` | `"true"` or `"false"` (only in `onApplyStatus` and `onRebootStatus`) |

**Event/status values:**

| AUTOUPDATE_EVENT    | Meaning                                            |
| ------------------- | -------------------------------------------------- |
| `NOOP`              | No new commits (exit 10 from `update-git.sh`)      |
| `UPDATE_FOUND`      | New commits checked out, about to rebuild          |
| `UPDATE_FAILED`     | Git fetch or checkout failed                       |
| `SUCCESS`           | `nixos-rebuild switch` succeeded                   |
| `APPLY_FAILED`      | `nixos-rebuild switch` failed                      |
| `REBOOT_NEEDED`     | Reboot sentinel present on timer tick              |
| `NO_REBOOT_NEEDED`  | No reboot sentinel on timer tick                   |

| AUTOUPDATE_STATUS   | Meaning                                            |
| ------------------- | -------------------------------------------------- |
| `OK`                | Everything nominal                                  |
| `GIT_ERROR`         | Git operation failed                                |
| `NIX_ERROR`         | Rebuild failed                                      |
| `REBOOT_NEEDED`     | Reboot required (mirrors event)                     |

**Typical usage — push metrics to a Pushgateway:**

```nix
nixos-autoupdate.onApplyStatus = ''
  curl -s -o /dev/null http://127.0.0.1:9091/metrics/job/autoupdate/instance/$AUTOUPDATE_HOSTNAME \
    --data-binary @- <<EOF
  # HELP autoupdate_nix_status NixOS rebuild status
  # TYPE autoupdate_nix_status gauge
  autoupdate_nix_status{host="$AUTOUPDATE_HOSTNAME",status="$AUTOUPDATE_STATUS",event="$AUTOUPDATE_EVENT",reboot_required="$AUTOUPDATE_REBOOT_REQUIRED"} 1
  EOF
'';
```

### autoReboot

After `nixos-rebuild switch`, the update service compares `/run/booted-system` and `/run/current-system`. If they differ (e.g. kernel, initrd, or systemd changed), it creates a sentinel at `/run/nixos-selfupdate/reboot-required`.

A separate reboot service (only created when `autoReboot != "never"`) periodically checks for the sentinel and acts per policy:

- `"never"` — sentinel is still created (for external notification watchers) but no reboot service runs. Manual reboot clears it (tmpfs).
- `"always"` — reboot immediately when sentinel is found
- `"script"` — run a custom script to decide when to reboot (exit 0 = reboot now, non-zero = skip; retried on next timer tick)

The reboot service guards against races by checking `systemctl is-active nixos-selfupdate.service` and skipping if an update is in progress. If the reboot condition clears before execution (e.g. manual reboot happened), it removes the stale sentinel.

### rebuildCommand

Available shell variables in the rebuild command:

| Variable         | Description                                      |
| ---------------- | ------------------------------------------------ |
| `$FLAKE_WORKTREE` | Path to the checked-out git worktree             |
| `$FLAKE_TARGET`   | The flake output target (e.g. `"myhost"`)        |
| `$FLAKE_REF`      | `"$FLAKE_WORKTREE#$FLAKE_TARGET"` (ready for `--flake`) |

## Testing

```bash
just test               # run flake check + all tests (summary output)
just test-integration   # integration test (verbose)
just test-reboot        # reboot test (verbose)
just debug-integration  # interactive test shell (integration)
just debug-reboot       # interactive test shell (reboot)
```

## How it works

1. A systemd timer triggers the update service at the configured `frequency`
2. The service fetches the latest commits from the git repo
3. If `onGitStatus` is set, it is called with the event/status after git fetch
4. On new commits (or always if `onGitStatus` is set), checks out a worktree
5. Runs the rebuild command (default: `nixos-rebuild switch --flake $FLAKE_REF --fast`)
6. If `onApplyStatus` is set, it is called with the rebuild result
7. After rebuild, compares `/run/booted-system` and `/run/current-system` — if different, creates a sentinel at `/run/nixos-selfupdate/reboot-required`
8. Cleans up the worktree
9. A separate reboot timer fires on every tick, calls `onRebootStatus` (if set), and when `autoReboot != "never"` checks the sentinel at the configured `rebootFrequency`, handles reboot per policy, and removes stale sentinels

## SSH Authentication via Age-Encrypted Keys

For private repositories, the module supports decrypting an SSH key at runtime:

1. Encrypt your SSH private key with age: `age -e -r "$AGE_PUBKEY" -o git-ssh-key.age /path/to/ssh-key`
2. Set `gitSshKey` to the encrypted file path
3. The module decrypts it at runtime and configures `GIT_SSH_COMMAND`
