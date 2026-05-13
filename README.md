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
| `notifyOnFailure` | bool             | `false`                                            | Notify on failures (requires notifier)        |
| `autoReboot`      | enum             | `"never"`                                          | Auto-reboot policy: `"never"`, `"always"`, or `"script"` |
| `rebootScript`    | nullOr path      | `null`                                             | Custom script for reboot timing (only with `autoReboot = "script"`) |

### autoReboot

After `nixos-rebuild switch`, the module checks if `/run/booted-system` differs from `/run/current-system`. If they differ (e.g. kernel, initrd, or systemd changed), a reboot is needed.

- `"never"` — log that a reboot is needed, require manual action
- `"always"` — reboot immediately after a successful update
- `"script"` — run a custom script to decide when to reboot (exit 0 = reboot now, non-zero = skip)

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

1. A systemd timer periodically triggers the update service
2. The service fetches the latest commits from the git repo
3. If the remote branch has new commits, it checks out a worktree
4. Runs the rebuild command (default: `nixos-rebuild switch --flake $FLAKE_REF --fast`)
5. Compares `/run/booted-system` and `/run/current-system` — if different, handles reboot per `autoReboot` setting
6. Cleans up the worktree

## SSH Authentication via Age-Encrypted Keys

For private repositories, the module supports decrypting an SSH key at runtime:

1. Encrypt your SSH private key with age: `age -e -r "$AGE_PUBKEY" -o git-ssh-key.age /path/to/ssh-key`
2. Set `gitSshKey` to the encrypted file path
3. The module decrypts it at runtime and configures `GIT_SSH_COMMAND`
