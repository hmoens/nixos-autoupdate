# Handoff: phased pipeline implementation

Status as of this session. The redesign in [DESIGN.md](DESIGN.md) is **implemented**
and **evaluates**, but the NixOS VM tests were **never run** — this machine is
darwin/aarch64 and its linux-builder lacks the `nixos-test` feature. Pick up on a
Linux (ideally x86_64) host and run the tests first.

## Git state

- Branch `main`, **nothing committed** (AGENTS.md: never commit without review).
- All new/changed files are `git add`ed so the flake can see them. Review with
  `git diff --cached` (and `git diff` for anything unstaged).
- New files: `scripts/*` (lib.sh, check.sh, build.sh, activate.sh, apply.sh,
  reboot.sh, nixos-update), `tests/fake-system-flake.nix`, `DESIGN.md`,
  `CLAUDE.md`, this file.
- Rewritten: `default.nix`, `tests/integration.nix`, `tests/reboot.nix`,
  `flake.nix`, `justfile`, `README.md`, `AGENTS.md`.

## First thing to do on the Linux box

```bash
just test               # flake check + both VM tests
# or individually, verbose:
just test-integration
just test-reboot
```

If a builder question comes up: the VM tests need a builder advertising the
`nixos-test` system feature (a native x86_64-linux machine has it by default).

## What was validated (and what wasn't)

Validated here: full Nix evaluation of both `x86_64-linux` checks to drvPaths;
`bash -n` + `shellcheck` on all scripts (only expected cross-file SC2034/SC2016
infos); the nixos-test **driver** builds and its Python `testScript` passes
mypy + lint; the fixture's substituted `flake.nix` and generated
`switch-to-configuration` are correct by inspection and the fake toplevel derivation
*starts* building once its deps are present.

NOT validated: **any runtime behavior**. The pipeline has never actually run. Treat
the list below as the prime suspects for a first-run failure.

## Watch-list for the first real run

Ordered by how likely I think they are to bite:

1. **Fake toplevel build inside the VM.** `tests/fake-system-flake.nix` is a raw
   `builtins.derivation` whose `bash`/`coreutils` paths come from `replaceVars`
   and therefore carry **no Nix string-context**. The VM must have those exact
   paths in its store — provided by `system.extraDependencies = [ bash coreutils ]`
   on the test nodes. If the build phase fails with "No such file or directory"
   for bash/coreutils, that seeding is the cause.
2. **`nix build path:$REPO#nixosConfigurations.autoupdate.config.system.build.toplevel`**
   inside the VM: needs `nix-command`/`flakes` (set on nodes), `NIX_REMOTE=local`
   as root, `nix.settings.sandbox = false` (set). The flake has only a `self`
   input so no lock file is needed — but confirm `nix build` doesn't try to write
   one and fail. If it does, add `--no-write-lock-file` in `scripts/build.sh`.
3. **Transient switch unit.** `scripts/activate.sh` does
   `exec systemd-run --unit=nixos-autoupdate-switch --setenv=MODE=switch … "$BASH" …/apply.sh`.
   Verify it returns immediately, the transient unit runs `apply.sh`, writes the
   version file, sets `applied_commit`, drops the GC root and raises the sentinel.
   Check `journalctl -u nixos-autoupdate-switch`.
4. **Reboot detection via symlinks.** The fake toplevel's `kernel`/`initrd`/… are
   symlinks into `/run/booted-system/*` (dangling in the store, resolved at
   runtime by `reboot_needed_between` in `scripts/lib.sh`). Integration expects
   `reboot_required=false` (kernel → booted/kernel); reboot test expects `true`
   (kernel → booted/initrd). The fake `switch-to-configuration` repoints
   `/run/current-system` so the reboot phase's stale-sentinel check keeps the
   sentinel. If reboot detection is inverted, look here.
5. **`status.json` via jq.** `status_get` returns "" for null and
   "true"/"false" for booleans (see `scripts/lib.sh`). The Python tests compare
   `st["reboot_required"] is False` etc. against the raw JSON — confirm types
   match (jq writes real booleans, so this should hold).
6. **CLI `nixos-update run`** backgrounds `journalctl -f`, runs each phase
   blocking, then `wait_unit`s the transient switch. Confirm it terminates and
   the trap kills the journal follower.
7. **hold / gate deferral** events: `BUILD_DEFERRED` (integration hold subtest)
   and `REBOOT_DEFERRED` (reboot gate subtest) must reach the hooks.

## Known non-blocking issues / possible cleanups

- `nixos-update run` creates a `force-check` flag that nothing consumes (check has
  no gate). Harmless litter on tmpfs; could stop creating it.
- Cross-phase state races on `status.json` are possible in theory (each write is
  atomic via tmp+mv, but there's no lock across read-modify-write). Phases
  coordinate through commit fields and same-unit systemd exclusion, and the
  transient switch is mutually excluded by its fixed unit name, so this is benign
  in practice. Add `flock` if it ever matters.
- `apply.sh` captures the exit of `switch-to-configuration` but not of the
  preceding `nix-env --set`; if `nix-env` fails the switch will fail anyway, but
  the reported exit could be tidier.

## Architecture recap (so you don't have to re-read DESIGN)

- Four phases, each a fixed-name oneshot service + timer + optional `gate`
  (`nullOr lines`, exit 0 = proceed): **check** (fetch, record pending, no
  checkout), **build** (checkout + `nix build` toplevel → GC-rooted
  `/var/lib/nixos-mgmt/pending-system`, resource-limited, computes
  reboot-required), **activate** (`switch` via transient unit / `boot` inline),
  **reboot** (precise kernel/initrd/modules/params compare + gate).
- State in `/var/lib/nixos-mgmt/status.json` (atomic writes); the `nixos-update`
  CLI reads it and drives phases via force-flags + `systemctl`.
- Scripts are plain files installed to `/etc/nixos-autoupdate/`, sourcing
  `config.env` (generated by the module) and `lib.sh`. No Nix-string escaping.
- The live switch MUST stay in a transient unit — see the invariant in AGENTS.md.
