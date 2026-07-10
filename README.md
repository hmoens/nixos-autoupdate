# nixos-autoupdate

A NixOS module that periodically pulls configuration from a git repository and
rebuilds the system as a **four-phase pipeline** — check → build → activate →
reboot. Each phase runs on its own timer and can be gated by a custom script, so
the expensive part (building) is decoupled from the disruptive part (activating
and rebooting). Ships a `nixos-update` CLI for status and manual control.

## Why phases?

`nixos-rebuild switch` welds evaluation/download/compilation to service
restarts. Splitting them means:

- **build** can run in the background the moment an update lands, resource-limited
  so it doesn't hurt a busy machine, and deferred under load via a gate;
- **activate** happens only when it is safe to disrupt the machine (its own gate),
  and is fast because everything is already built;
- **reboot** happens only when a change actually needs it (kernel / initrd /
  kernel modules / kernel params changed) — not after every update.

For interactive/desktop machines, `activate.mode = "boot"` stages the built
config for the next boot with zero runtime disruption.

## Usage

```nix
{
  inputs.nixos-autoupdate.url = "github:youruser/nixos-autoupdate";

  outputs = { self, nixpkgs, nixos-autoupdate, ... }: {
    nixosConfigurations.myhost = nixpkgs.lib.nixosSystem {
      modules = [
        nixos-autoupdate.nixosModules.default
        ({ ... }: {
          nixos-autoupdate = {
            enable = true;
            repoUrl = "ssh://git@github.com/youruser/nix-config";
            branch = "main";
            flakeOutput = "nixosConfigurations.myhost";
            ageKeyPath = "/var/lib/nixos/secrets/age.key";
            gitSshKey = "/var/lib/nixos/secrets/git-ssh-key.age";

            check.frequency = "*-*-* *:0/10:00";  # every 10 minutes
            reboot.enable = true;                 # auto-reboot when needed
          };
        })
      ];
    };
  };
}
```

## The `nixos-update` CLI

```
nixos-update                  Show pipeline status (default)
nixos-update status [--json]  Pending/built/applied commits, phase in flight,
                              reboot required, hold, last error
nixos-update run [--reboot]   Run check + build + activate now, bypassing gates,
                              streaming logs; --reboot also reboots if required
nixos-update check            Fetch and detect updates now
nixos-update build            Build the pending config now (bypasses build gate)
nixos-update activate         Activate the built config now (bypasses gate)
nixos-update reboot           Reboot now if a reboot is pending (bypasses gate)
nixos-update hold [reason]    Pause build/activate/reboot (check keeps running)
nixos-update unhold           Resume the pipeline
nixos-update log [-f]         Logs across all pipeline units
```

## Options

| Option              | Type          | Default                  | Description                                       |
| ------------------- | ------------- | ------------------------ | ------------------------------------------------- |
| `enable`            | bool          | `false`                  | Enable the module                                 |
| `repoUrl`           | string        | —                        | Git repository URL                                |
| `branch`            | string        | `"main"`                 | Branch to track                                   |
| `flakeOutput`       | string        | `"nixos"`                | Flake output; last component names the config     |
| `flakeSubdir`       | string        | `""`                     | Subdirectory holding the flake, if not at root    |
| `repoPath`          | path          | `/var/lib/nixos-mgmt/repo` | Local checkout path                             |
| `ageKeyPath`        | nullOr path   | `null`                   | Age private key (for agenix + gitSshKey)          |
| `gitSshKey`         | nullOr path   | `null`                   | Age-encrypted SSH key for git auth                |
| `check.frequency`   | string        | `"*-*-* *:0/10:00"`      | Fetch/detect cadence (OnCalendar)                 |
| `build.gate`        | nullOr lines  | `null`                   | Exit 0 to build now, non-zero to defer            |
| `build.frequency`   | string        | `"*-*-* *:0/10:00"`      | Deferred-build retry cadence                      |
| `build.resources.*` | —             | see below                | systemd/nix throttling for the build              |
| `activate.mode`     | enum          | `"switch"`               | `"switch"` (live) or `"boot"` (stage for reboot)  |
| `activate.gate`     | nullOr lines  | `null`                   | Exit 0 to activate now, non-zero to defer         |
| `activate.frequency`| string        | `"*-*-* *:0/5:00"`       | Deferred-activate retry cadence                   |
| `reboot.enable`     | bool          | `false`                  | Auto-reboot when a reboot is required             |
| `reboot.gate`       | nullOr lines  | `null`                   | Exit 0 to reboot now, non-zero to defer           |
| `reboot.frequency`  | string        | `"*-*-* *:0/5:00"`       | Reboot-check cadence                              |
| `onGitStatus`       | nullOr lines  | `null`                   | Hook after each check                             |
| `onApplyStatus`     | nullOr lines  | `null`                   | Hook after each build and activation attempt      |
| `onRebootStatus`    | nullOr lines  | `null`                   | Hook on each reboot tick                          |

`build.resources`: `cpuWeight` (25), `nice` (15), `ioSchedulingClass`
(`"idle"`), `memoryHigh` (`"50%"`), `cores` (0 = all), `maxJobs` (null). The
build unit runs with `NIX_REMOTE=local` so these limits apply to compilation
itself, not just evaluation.

## How it works

1. **check** (own timer) fetches the repo and records the pending commit in
   `status.json`. It does *not* check out — so the checkout never lies about what
   is applied. Fires `onGitStatus`.
2. **build** (own timer, gated) checks out the pending commit and runs
   `nix build …system.build.toplevel`, GC-rooted at
   `/var/lib/nixos-mgmt/pending-system`. Resource-limited. Computes whether the
   result will require a reboot, *before* activation. Fires `onApplyStatus`.
3. **activate** (own timer, gated) activates the prebuilt path. `"switch"`
   activates live (in a transient unit — see below); `"boot"` only stages it for
   the next boot. Sets the reboot sentinel iff a reboot is required. Fires
   `onApplyStatus`.
4. **reboot** (own timer, gated) reboots when the sentinel is present, a reboot
   is genuinely needed, and `reboot.enable` (or a force via the CLI). Fires
   `onRebootStatus`.

State lives in `/var/lib/nixos-mgmt/status.json` (written atomically). Inspect it
with `nixos-update status`.

### Why activation runs in a transient unit

`switch-to-configuration switch` restarts declared units whose definitions
changed — including the unit performing the switch. So the live switch runs in a
fixed-name **transient** unit (`nixos-autoupdate-switch.service`) spawned via
`systemd-run`, which is not part of the declared configuration and therefore
cannot stop itself mid-activation. See DESIGN.md and AGENTS.md — do not turn this
into a normal declared service.

## Gates

Each of `build`, `activate` and `reboot` takes an optional `gate` script (POSIX
`sh`): exit 0 to proceed, non-zero to defer to the next tick. Gates receive the
full `AUTOUPDATE_*` environment (including `AUTOUPDATE_REBOOT_REQUIRED`, known
before activation). `nixos-update <phase>` and `nixos-update run` bypass gates.

**Reboot only during a maintenance window:**

```nix
reboot.enable = true;
reboot.gate = ''
  h=$(date +%H)
  [ "$h" -ge 3 ] && [ "$h" -lt 5 ]   # 03:00–05:00
'';
```

**Defer the build while the machine is busy (idle detection):**

```nix
build.gate = ''
  # defer if 1-min load average is above 2.0
  load=$(cut -d' ' -f1 /proc/loadavg)
  awk -v l="$load" 'BEGIN { exit !(l < 2.0) }'
'';
```

**Activate only when nobody is logged in:**

```nix
activate.gate = ''
  [ "$(loginctl list-sessions --no-legend | wc -l)" -eq 0 ]
'';
```

## Status hooks

Each hook fires at its phase and receives context via `AUTOUPDATE_*` environment
variables (POSIX `sh`).

| Hook             | Fires when                          | Events                                                        |
| ---------------- | ----------------------------------- | ------------------------------------------------------------- |
| `onGitStatus`    | after each check                    | `UPDATE_FOUND`, `NOOP`, `UPDATE_FAILED`                       |
| `onApplyStatus`  | after each build and activation     | `BUILD_OK`, `BUILD_FAILED`, `BUILD_DEFERRED`, `ACTIVATE_DEFERRED`, `SUCCESS`, `APPLY_FAILED` |
| `onRebootStatus` | on each reboot tick                 | `REBOOT_NEEDED`, `NO_REBOOT_NEEDED`, `REBOOT_DEFERRED`        |

Common env vars: `AUTOUPDATE_EVENT`, `AUTOUPDATE_STATUS`, `AUTOUPDATE_PHASE`,
`AUTOUPDATE_HOSTNAME`, `AUTOUPDATE_HOST_IP`, `AUTOUPDATE_CHECKED_OUT_COMMIT`,
`AUTOUPDATE_REBOOT_REQUIRED`, `AUTOUPDATE_MESSAGE`.

**Push metrics to a Pushgateway:**

```nix
onApplyStatus = ''
  {
    echo '# TYPE autoupdate_nix_status gauge'
    echo "autoupdate_nix_status{host=\"$AUTOUPDATE_HOSTNAME\",status=\"$AUTOUPDATE_STATUS\",event=\"$AUTOUPDATE_EVENT\",reboot_required=\"$AUTOUPDATE_REBOOT_REQUIRED\"} 1"
  } | curl -s -o /dev/null --data-binary @- \
    "http://127.0.0.1:9091/metrics/job/autoupdate/instance/$AUTOUPDATE_HOSTNAME"
'';
```

## Testing

```bash
just test               # flake check + all VM tests (summary)
just test-integration   # pipeline: check/build/activate, status, hold (verbose)
just test-reboot        # reboot detection + gate deferral + boot-mode (verbose)
just debug-integration  # interactive test shell
```

The VM tests require an `x86_64-linux` builder with the `nixos-test` feature.

## SSH authentication via age-encrypted keys

For private repositories:

1. Encrypt your SSH private key: `age -e -r "$AGE_PUBKEY" -o git-ssh-key.age /path/to/ssh-key`
2. Set `gitSshKey` to the encrypted file and `ageKeyPath` to your age key
3. The module decrypts it at runtime (during **check**) and configures `GIT_SSH_COMMAND`

## Migrating from the pre-phase module

Breaking option changes:

| Old                                     | New                                          |
| --------------------------------------- | -------------------------------------------- |
| `frequency`                             | `check.frequency`                            |
| `autoReboot = "never"`                  | `reboot.enable = false` (default)            |
| `autoReboot = "always"`                 | `reboot.enable = true`                       |
| `autoReboot = "script"; rebootScript=p` | `reboot.enable = true; reboot.gate = "exec ${p}"` |
| `rebootFrequency`                       | `reboot.frequency`                           |
| `rebuildCommand`                        | removed (activation is no longer `nixos-rebuild`) |
| `notifyOnFailure`                       | removed (was never wired)                    |
| `onGitStatus` / `onApplyStatus` / `onRebootStatus` | unchanged                         |

On first run the module seeds `applied_commit` from the legacy
`/var/lib/nixos-mgmt/last-applied-commit`, so upgrading does not trigger a
spurious rebuild.
