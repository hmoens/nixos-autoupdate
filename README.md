# nixos-autoupdate

Pull-based GitOps for NixOS: a builder publishes **pre-built system closures** to
a binary cache and records which one each host should run in git; every host
polls that pointer, **downloads** its system, and activates it on its own
schedule — with gates, hold, staged activation and reboot windows.

Think "container registry + Flux", for NixOS:

| Containers / Flux | Here |
| --- | --- |
| image (by digest) | system closure — `config.system.build.toplevel` store path |
| registry | binary cache |
| tag | `releases/<host>.json` in git |
| CI pushes image, moves tag | `nixos-release <host>` |
| in-cluster reconciler | the `nixos-autoupdate` agent |

## Why

`nixos-rebuild switch` on the target welds three costs together: **evaluate**,
**compile**, and **activate**. Evaluation alone needs roughly 0.5–2 GB RSS,
which is fatal on small machines — a 1 GB Raspberry Pi cannot evaluate nixpkgs
without thrashing into swap. A remote builder only offloads *compilation*; the
target still evaluates, and the builder has to be online at update time.

So the target is given a **store path**, never a flake and never a derivation.
It cannot build even in principle: realising a path with no `.drv` present can
only substitute it. If the cache does not have the closure, the fetch defers and
retries — it never falls back to compiling. Weak hosts do only **download +
activate**, and the builder can be a laptop that is offline most of the time.

See [DESIGN-v2.md](DESIGN-v2.md) for the full rationale, and [DESIGN.md](DESIGN.md)
for the v1 (build-on-target) design this replaces.

## Flow

```
 config repo  ── humans edit ──▶  the flake: what the system should be
      │
      │   builder (laptop / CI):  nixos-release nas
      │     1. nix build …nas…toplevel
      │     2. nix copy --to <cache>        ← push the artifact
      │     3. write releases/nas.json      ← move the tag (always last)
      ▼
 git ──── poll ────▶ host:  fetch closure from cache → activate → reboot
```

The ordering in step 2/3 is load-bearing: the closure reaches the cache **before**
the pointer names it, so a host that sees a pointer can always fetch it.

## Usage

On each host:

```nix
{
  imports = [ nixos-autoupdate.nixosModules.default ];

  nixos-autoupdate = {
    enable = true;
    repoUrl = "ssh://git@github.com/youruser/nix-config";
    branch = "main";
    # releaseFile defaults to "releases/<hostname>.json"

    cache = {
      url = "https://cache.example.net";
      publicKey = "cache.example.net:AbCdEf...=";
    };

    ageKeyPath = "/var/lib/nixos/secrets/age.key";
    gitSshKey = "/var/lib/nixos/secrets/git-ssh-key.age";

    check.frequency = "*-*-* *:0/10:00";
    reboot = {
      enable = true;
      gate = ''h=$(date +%H); [ "$h" -ge 3 ] && [ "$h" -lt 5 ]'';  # 03:00–05:00
    };
  };
}
```

On the builder, from the config repo:

```bash
# build, publish to the cache, write + commit releases/<host>.json
nix run github:youruser/nixos-autoupdate# -- --cache ssh-ng://nas nas
```

A `just deploy <host>` wrapper in the config repo:

```make
cache := "ssh-ng://nas"

deploy host:
    nix run github:youruser/nixos-autoupdate# -- --cache {{cache}} --push {{host}}
```

Cross-architecture hosts need nothing special: `nixos-release pished` builds the
aarch64 closure via qemu binfmt (`extra-platforms = aarch64-linux`) or a native
remote builder, and only locally-changed derivations are emulated.

## The `nixos-update` CLI (on the host)

```
nixos-update                  Show pipeline status (default)
nixos-update status [--json]  Desired/fetched/applied store paths, phase in
                              flight, reboot required, hold, last error
nixos-update run [--reboot]   check + fetch + activate now, bypassing gates,
                              streaming logs; --reboot also reboots if required
nixos-update check            Poll the release pointer now
nixos-update fetch            Download the released closure now (bypasses gate)
nixos-update activate         Activate the fetched system now (bypasses gate)
nixos-update reboot           Reboot now if one is pending (bypasses gate)
nixos-update hold [reason]    Pause fetch/activate/reboot (check keeps running)
nixos-update unhold           Resume
nixos-update log [-f]         Logs across all pipeline units
```

## The release pointer

`releases/<host>.json`, written by `nixos-release`:

```json
{
  "storePath": "/nix/store/xxxx-nixos-system-nas-26.05",
  "system": "x86_64-linux",
  "operation": "switch",
  "builtFrom": { "commit": "abc1234" },
  "builtAt": "2026-08-11T09:00:00Z"
}
```

`storePath` is the whole desired system. `operation` optionally overrides
`activate.mode` for a single release (e.g. stage a risky update for next boot).
Everything else is provenance. Rollout *policy* — gates, windows, hold — stays
in the host's own NixOS config: gates are shell scripts, and running scripts
fetched from the pointer would widen the trust boundary for nothing.

**Rollback** is reverting the pointer commit. The previous system is still on
the host and GC-rooted, so it re-activates with no download at all.

## Options

| Option | Type | Default | Description |
| --- | --- | --- | --- |
| `enable` | bool | `false` | Enable the agent |
| `repoUrl` | string | — | Git repo holding the release pointers |
| `branch` | string | `"main"` | Branch to track |
| `releaseFile` | nullOr string | `null` | Pointer path; default `releases/<hostname>.json` |
| `repoPath` | path | `/var/lib/nixos-mgmt/repo` | Local clone (`--no-checkout`) |
| `cache.url` | string | `""` | Binary cache to fetch closures from |
| `cache.publicKey` | nullOr string | `null` | Key added to `trusted-public-keys` |
| `verifyCommitSignatures` | bool | `false` | Require a signed pointer commit |
| `ageKeyPath` | nullOr path | `null` | Age key (agenix + gitSshKey) |
| `gitSshKey` | nullOr path | `null` | Age-encrypted SSH key for git auth |
| `check.frequency` | string | `"*-*-* *:0/10:00"` | Pointer poll cadence |
| `fetch.gate` | nullOr lines | `null` | Exit 0 to download now, non-zero to defer |
| `fetch.frequency` | string | `"*-*-* *:0/10:00"` | Deferred-fetch retry cadence |
| `activate.mode` | enum | `"switch"` | `"switch"` (live) or `"boot"` (stage) |
| `activate.gate` | nullOr lines | `null` | Exit 0 to activate now, non-zero to defer |
| `activate.frequency` | string | `"*-*-* *:0/5:00"` | Deferred-activate retry cadence |
| `reboot.enable` | bool | `false` | Auto-reboot when a reboot is required |
| `reboot.gate` | nullOr lines | `null` | Exit 0 to reboot now, non-zero to defer |
| `reboot.frequency` | string | `"*-*-* *:0/5:00"` | Reboot-check cadence |
| `onGitStatus` | nullOr lines | `null` | Hook after each check |
| `onApplyStatus` | nullOr lines | `null` | Hook after each fetch/activation |
| `onRebootStatus` | nullOr lines | `null` | Hook on each reboot tick |

## Security

Two independent signatures matter, and they protect different things:

1. **The closure** — signed by the cache key, verified against
   `trusted-public-keys`. The fetch never passes `--no-check-sigs`.
2. **The pointer commit** — set `verifyCommitSignatures = true`. A validly
   signed closure does not prove the host was aimed at the *right* closure; only
   signing the pointer closes that gap.

Secrets are not in the closure (they are age-decrypted at runtime), so the cache
holds only software and config.

## Gates

`fetch`, `activate` and `reboot` each take an optional `gate` (POSIX `sh`): exit
0 to proceed, non-zero to defer to the next tick. Gates get the full
`AUTOUPDATE_*` environment, including `AUTOUPDATE_REBOOT_REQUIRED`, which is
known *before* activation. `nixos-update <phase>` and `run` bypass them.

```nix
# only download over the wired link
fetch.gate = ''[ "$(cat /sys/class/net/eth0/carrier 2>/dev/null)" = 1 ]'';

# only activate when nobody is logged in
activate.gate = ''[ "$(loginctl list-sessions --no-legend | wc -l)" -eq 0 ]'';
```

## Status hooks

| Hook | Fires when | Events |
| --- | --- | --- |
| `onGitStatus` | after each check | `UPDATE_FOUND`, `NOOP`, `UPDATE_FAILED` |
| `onApplyStatus` | after each fetch and activation | `FETCH_OK`, `FETCH_FAILED`, `FETCH_DEFERRED`, `ACTIVATE_DEFERRED`, `SUCCESS`, `APPLY_FAILED` |
| `onRebootStatus` | on each reboot tick | `REBOOT_NEEDED`, `NO_REBOOT_NEEDED`, `REBOOT_DEFERRED` |

Env: `AUTOUPDATE_EVENT`, `AUTOUPDATE_STATUS`, `AUTOUPDATE_PHASE`,
`AUTOUPDATE_HOSTNAME`, `AUTOUPDATE_HOST_IP`, `AUTOUPDATE_STORE_PATH` (the
artifact — new in v2), `AUTOUPDATE_CHECKED_OUT_COMMIT` (the source commit it was
built from), `AUTOUPDATE_REBOOT_REQUIRED`, `AUTOUPDATE_MESSAGE`.

## Choosing a cache

The agent needs only a substituter URL and a public key, so any backend works:

- **harmonia / nix-serve** — serves one always-on host's store over HTTP.
  Simplest to run; one shared store means paths common to several hosts are
  stored once, and `nix.settings.auto-optimise-store` hardlinks identical files.
- **S3 / MinIO / R2** — plain object storage, no server logic, manual GC.
- A cache is keyed by store path, so closures **shared between hosts are stored
  once on every backend**. Backends differ only in whether they also dedup
  between *different versions* of a path.

Whatever you pick, GC-root on the cache host the closures any pointer may still
reference (current release plus whatever history you want to roll back to).

## Testing

```bash
just test               # flake check + both VM tests
just test-integration   # pointer → signed download → activate, hold/unhold
just test-reboot        # reboot detection + gate deferral + boot-mode staging
just lint               # bash -n over all scripts
```

The VM tests stand up a real builder + signed binary cache + git release repo,
and assert the target does **not** have the closure until it fetches it.
They require an `x86_64-linux` builder with the `nixos-test` feature.
