# Design: phased update pipeline

Redesign of nixos-autoupdate around four phases — **check → build → activate → reboot** —
each with its own gate script and cadence, plus a `nixos-update` CLI for manual control
and status visibility. Breaking change to the option surface; no compatibility shims.

## Motivation

- `nixos-rebuild switch` welds the expensive part (eval/download/compile) to the
  disruptive part (service restarts). Splitting them lets the build run in the
  background anytime while activation is deferred for reliability reasons.
- Reboot detection today compares `/run/booted-system` to `/run/current-system`,
  which differ after *every* activation — so "reboot when needed" is effectively
  "reboot after every update".
- Applies are spawned as `systemd-run --unit=...-$(date +%s)` transient units.
  Transience is deliberate and must be kept (see "Why activation runs in a
  transient unit"), but the timestamped name means concurrent applies are
  possible and there is no stable unit to query or log.
- No way to see pipeline state or trigger/force an update by hand.

## Pipeline

```
check     frequent, cheap      git fetch; record pending commit. No checkout.
  build   gated: performance   checkout + nix build toplevel → GC root. Resource-limited.
    activate  gated: reliability  switch to prebuilt path, or set boot profile only.
      reboot  gated: reliability  only when kernel/initrd/... actually changed.
```

Each phase is a fixed-name oneshot service (`nixos-autoupdate-<phase>.service`) with
its own timer. A service tick is: check preconditions (work pending, prior phase
done, no hold) → run gate script → do the work or exit 0 quickly. Fixed names give
mutual exclusion, `systemctl is-active` queryability, and `journalctl -u` history.
Phases never start while an earlier phase's service is active.

**Exception:** the actual `switch-to-configuration switch` step runs in a
*transient* unit, not a declared one — see "Why activation runs in a transient
unit" below. It still gets a fixed name (`nixos-autoupdate-switch.service`) so
exclusivity and log queries keep working.

### check

- `git fetch` only; records `fetched_commit` in status. The working tree is **not**
  reset here — checkout moves to build time, so repo HEAD always reflects what was
  last built, never a pending config.
- Update pending ⇔ `fetched_commit != applied_commit`.

### build

- Precondition: update pending and `built_commit != fetched_commit`.
- `git reset --hard $fetched_commit && git clean -fd`, then build the toplevel
  (`nix build <flake>#nixosConfigurations.<target>.config.system.build.toplevel`)
  with `--out-link /var/lib/nixos-mgmt/pending-system` (doubles as GC root).
- Runs with `NIX_REMOTE=local` so builds happen in the unit's own cgroup —
  otherwise CPU/IO limits only throttle evaluation while nix-daemon does the real
  work unthrottled. Defaults: `CPUWeight=25`, `IOSchedulingClass=idle`, `Nice=15`,
  `MemoryHigh=50%`. Deliberately not `CPUSchedulingPolicy=idle` (starvation risk).
- After a successful build, computes `reboot_required` against the **built**
  toplevel (see below) so status can announce it before activation, and gate
  scripts can use it.

### activate

- Precondition: `built_commit != applied_commit` and pending-system exists.
- Activates exactly what was built (deterministic), even if newer commits have
  since been fetched; the next cycle picks those up.
- `mode = "switch"`: `pending-system/bin/switch-to-configuration switch` +
  set system profile. Fast — everything is prebuilt. Runs inside the transient
  `nixos-autoupdate-switch.service` (fire-and-forget from the declared activate
  unit); the transient script does the post-work itself: status update, GC-root
  cleanup, reboot sentinel, `onApplyStatus`.
- `mode = "boot"` (interactive machines): set system profile + install bootloader
  only. Zero runtime disruption; next reboot (whenever, for whatever reason) comes
  up on the new config. This replaces any shutdown-time upgrade machinery.
- On success: `applied_commit = built_commit`, drop the pending-system GC root,
  create reboot sentinel iff `reboot_required`.

### reboot

- Precondition: reboot sentinel present, no update/build/activate in flight.
- Reboot-needed test (replaces booted-vs-current comparison):
  ```sh
  for f in kernel initrd kernel-modules; do
    [ "$(readlink -f /run/booted-system/$f)" != "$(readlink -f $TOPLEVEL/$f)" ] && needed=1
  done
  cmp -s /run/booted-system/kernel-params $TOPLEVEL/kernel-params || needed=1
  ```
- Clears stale sentinels (e.g. after a manual reboot).

## Why activation runs in a transient unit

`switch-to-configuration switch` stops/restarts declared systemd units whose
definitions changed in the new configuration — **including the unit that is
running the switch**. If activation ran inside a declared unit and an update
changed that unit's definition (e.g. an update to this module itself, or to
anything in its `path`/environment), the switch would stop its own unit
mid-activation and the update would fail. This is why the current code launches
the apply via `systemd-run`: transient units are not part of the declared
configuration, so activation never considers them for restart, and they survive
the systemd daemon-reload/reexec that happens during a switch.

The redesign keeps the transient unit but gives it a **fixed name**
(`systemd-run --unit=nixos-autoupdate-switch …`):

- fixed name ⇒ `systemd-run` refuses to start a second instance while one is
  running (mutual exclusion), and `systemctl is-active` / `journalctl -u`
  work for status and log streaming;
- transient ⇒ immune to being stopped by the switch it performs.

The declared activate unit does gate/precondition checks, spawns the transient
unit, and exits; it must `systemctl reset-failed nixos-autoupdate-switch`
beforehand, since failed transient units linger until reset and would block the
next run. The check, build, and reboot phases don't activate anything, and
`mode = "boot"` doesn't restart units, so those run as plain declared units.
A declared unit with `restartIfChanged = false` / `stopIfChanged = false` was
considered instead, but it doesn't cover unit removal/rename and depends on
which generation's flags `switch-to-configuration` consults — the transient
approach is unconditional.

## State

`/var/lib/nixos-mgmt/status.json`, written atomically (tmp + mv) by every phase:

```json
{
  "phase": "idle | checking | building | built | activating | reboot-pending",
  "hold": false,
  "last_check": "2026-07-06T10:00:00Z",
  "fetched_commit": "abc123",
  "built_commit": "abc123",
  "applied_commit": "def456",
  "reboot_required": false,
  "last_error": { "phase": "build", "message": "...", "at": "..." }
}
```

Plus: `/var/lib/nixos-mgmt/pending-system` (GC root), `/run/nixos-autoupdate/`
(reboot sentinel, per-phase force flags, hold file mirrored persistently in the
state dir so it survives reboots).

## CLI: `nixos-update`

`writeShellApplication` in `environment.systemPackages`. Named to sit next to
`nixos-rebuild` without clashing; the module keeps its `nixos-autoupdate` name.

```
nixos-update                     status (default)
nixos-update status [--json]     pipeline state: pending/built/applied commits,
                                 phase in flight (via systemctl is-active),
                                 reboot required, hold, last error
nixos-update run [--reboot]      full update now: check + build + activate,
                                 bypassing gates, streaming logs to the terminal;
                                 --reboot also reboots afterwards if required
nixos-update check|build|activate|reboot
                                 run one phase now, bypassing its gate
nixos-update hold [reason]       pause build/activate/reboot (check keeps running)
nixos-update unhold
nixos-update log [-f]            journalctl across all pipeline units
                                 (incl. the transient nixos-autoupdate-switch)
```

Force semantics: the CLI touches `/run/nixos-autoupdate/force-<phase>` then
`systemctl start`s the unit; the gate check is skipped when the flag is present
and the service consumes it. Foreground streaming: start the unit with
`--no-block`, follow `journalctl -f -u <unit>` until the unit goes inactive,
exit with the unit's result.

## Options (breaking)

Removed: `frequency` (→ `check.frequency`), `autoReboot`/`rebootScript`/
`rebootFrequency` (→ `reboot.*`), `rebuildCommand` (activation of a prebuilt
toplevel is no longer a `nixos-rebuild` invocation), `notifyOnFailure`
(declared today but never wired to anything).
Kept as-is: `enable`, `repoUrl`, `branch`, `flakeOutput`, `flakeSubdir`,
`repoPath`, `ageKeyPath`, `gitSshKey`, and the three hooks **`onGitStatus`,
`onApplyStatus`, `onRebootStatus`** — same option names, same `AUTOUPDATE_*`
env contract, so existing hook scripts (pushgateway pushes etc.) keep working
unchanged. Renaming them to per-phase hooks was considered and rejected as
churn: the existing three map cleanly onto the pipeline (check / "is the new
config applied" / reboot).

```nix
nixos-autoupdate = {
  check.frequency = "*-*-* *:0/10:00";

  build = {
    gate = null;                 # nullOr lines; exit 0 = proceed, non-zero = defer
    frequency = "*-*-* *:0/10:00";
    resources = {
      cpuWeight = 25; nice = 15; ioSchedulingClass = "idle";
      memoryHigh = "50%"; cores = 0; maxJobs = null;
    };
  };

  activate = {
    mode = "switch";             # "switch" | "boot"
    gate = null;
    frequency = "*-*-* *:0/5:00";
  };

  reboot = {
    enable = false;              # false: sentinel + status only, no reboot service
    gate = null;                 # null with enable=true ⇒ reboot as soon as needed
    frequency = "*-*-* *:0/5:00";
  };

  # unchanged from today (nullOr lines, AUTOUPDATE_* env contract):
  onGitStatus = null;            # after each check
  onApplyStatus = null;          # after each build/activate attempt
  onRebootStatus = null;         # on each reboot tick
};
```

Gate scripts receive the full `AUTOUPDATE_*` environment (notably
`AUTOUPDATE_REBOOT_REQUIRED`, known pre-activation). Idle detection is a
documented gate recipe (load average, `loginctl list-sessions`, …), not a
built-in.

Hook events — existing names keep their meaning; new phases add new values:

- `onGitStatus`: `NOOP`, `UPDATE_FOUND`, `UPDATE_FAILED` (unchanged).
- `onApplyStatus`: `SUCCESS` and `APPLY_FAILED` keep meaning "activation
  succeeded/failed" (statuses `OK`/`NIX_ERROR` as today). New: `BUILD_OK`
  (build ready, status `OK`), `BUILD_FAILED` (status `NIX_ERROR`),
  `BUILD_DEFERRED` / `ACTIVATE_DEFERRED` (gate said no, status `DEFERRED`).
- `onRebootStatus`: `REBOOT_NEEDED`, `NO_REBOOT_NEEDED` (unchanged);
  new `REBOOT_DEFERRED` (status `DEFERRED`).

Env vars as today: `AUTOUPDATE_EVENT`, `AUTOUPDATE_STATUS`,
`AUTOUPDATE_HOSTNAME`, `AUTOUPDATE_HOST_IP`, `AUTOUPDATE_CHECKED_OUT_COMMIT`,
`AUTOUPDATE_REBOOT_REQUIRED`, `AUTOUPDATE_MESSAGE`; new additive
`AUTOUPDATE_PHASE` (`check|build|activate|reboot`). Existing pushgateway hook
scripts that label by `$AUTOUPDATE_EVENT`/`$AUTOUPDATE_STATUS` need no changes.

Gate scripts are `nullOr lines` like hooks. Today's `rebootScript` is a path;
a config like `rebootScript = pkgs.writeScript "reboot-window" …` migrates to
`reboot.gate = "exec ${pkgs.writeScript "reboot-window" …}"` or inlines the
body directly.

## Migration notes (for existing deployments)

| Today                                   | New                                        |
| --------------------------------------- | ------------------------------------------ |
| `frequency = "*-*-* *:*:00"`            | `check.frequency = "*-*-* *:*:00"`         |
| `autoReboot = "never"`                  | `reboot.enable = false` (default)          |
| `autoReboot = "always"`                 | `reboot.enable = true;`                    |
| `autoReboot = "script"; rebootScript=p` | `reboot.enable = true; reboot.gate = "exec ${p}"` |
| `rebootFrequency`                       | `reboot.frequency`                         |
| `onGitStatus` / `onApplyStatus` / `onRebootStatus` | unchanged                       |

- **Seeding state:** on first run the new module reads the legacy
  `/var/lib/nixos-mgmt/last-applied-commit` (if `status.json` is absent) to
  seed `applied_commit`, so upgrading doesn't trigger a spurious rebuild.
- **Behavior change (intentional):** today an apply is spawned on *every*
  successful check tick, even `NOOP` — with a one-minute `frequency` that is a
  full `nixos-rebuild switch` eval per minute. The new pipeline only builds
  when `fetched_commit != applied_commit`. Forced reconvergence (e.g. after
  manual fiddling) is `nixos-update run`.
- Timer details preserved: `Persistent = true`, `RandomizedDelaySec = 60` on
  the check timer; state dir stays `/var/lib/nixos-mgmt`, sentinel stays
  `/run/nixos-autoupdate/reboot-required`; phase scripts stay exposed under
  `/etc/nixos-autoupdate/` for the transient unit and manual inspection.

## Future: desktop update notifications

For `activate.mode = "boot"` desktops, the eventual UX is a GUI notification
for "update found" / "building" / "staged, reboot to apply". Hooks run as root
system services and cannot reach a user's D-Bus session bus directly, so the
integration point is `status.json`: a small systemd **user** service watching
it (inotify) and raising `notify-send` on phase transitions. Out of scope for
the initial implementation; the design only needs to guarantee that
`status.json` is updated atomically on every transition, which it does.

## Implementation plan

1. **Shared shell library** (`writeText`, sourced by all phase scripts): logging,
   atomic status.json read/update (jq), `AUTOUPDATE_*` env export, gate-or-force
   evaluation, hold check.
2. **check**: strip checkout/apply-spawning from the current update script;
   fetch, record, fire `onGitStatus`. Timer as today.
3. **build unit**: checkout + `nix build` with GC root; resource limits +
   `NIX_REMOTE=local`; reboot-required computation; `onApplyStatus`
   (`BUILD_*` events).
4. **activate unit**: declared unit for gate/preconditions; `switch` mode spawns
   the fixed-name transient `nixos-autoupdate-switch.service` via `systemd-run`
   (with `reset-failed` first) which runs `switch-to-configuration` +
   `nix-env -p /nix/var/nix/profiles/system --set`, GC-root cleanup, sentinel,
   `onApplyStatus`; `boot` mode runs inline in the declared unit.
5. **reboot unit**: rewrite around the sentinel + precise needs-reboot test +
   gate; `onRebootStatus`.
6. **Options rewrite** in `default.nix`: new surface, assertions
   (`gitSshKey → ageKeyPath` kept), wire the four timers/services.
7. **CLI** `nixos-update` package + systemPackages.
8. **Tests**: rework `tests/integration.nix` for the phased flow (update pending →
   built → activated; gate deferral; hold; force via CLI; `status --json`
   assertions). Rework `tests/reboot.nix`: no-reboot on a config-only change,
   reboot on a kernel-param change, boot-mode activation.
9. **Docs**: rewrite README (options table, phase diagram, CLI, gate recipes
   including an idle-detection example).

Suggested order of PRs: (1–2) check split + library, (3–5) phase units,
(6–7) options + CLI, (8–9) tests + docs — or one branch with commits in that
order, since the option break lands all at once anyway.
