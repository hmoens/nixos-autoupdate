# Design v2: artifact-pull ("image registry + GitOps") pipeline

v1 (see [DESIGN.md](DESIGN.md)) splits an update into check → build → activate →
reboot, all on the target. That fixed *when* the disruption happens, but the
target still **evaluates and compiles**. v2 removes both from the target.

## Motivation: eval is the cost you cannot offload with a remote builder

A NixOS update costs **evaluate → compile → download → activate**.

- A remote builder (`nix.buildMachines`) offloads **compile** only. The host must
  still evaluate the flake locally to produce the derivation graph.
- Evaluating a NixOS config needs roughly 0.5–2 GB RSS. That is what kills small
  machines — `hosts/pished` (Raspberry Pi 3, 1 GB) cannot evaluate nixpkgs
  without thrashing into swap.
- A remote builder must also be **online at update time**. The most powerful
  machine here is a laptop, which is not.

So v2 ships the target a **pre-built artifact**, not a config to realise.

## The model

```
 config repo   humans edit ──▶ the flake: what the system should be
      │
      │  builder (laptop / CI): nix build .#nixosConfigurations.<h>…toplevel
      │                         nix copy --to <cache>          (push artifact)
      │                         write releases/<h>.json        (move the tag)
      ▼
 pointer (releases/<host>.json, in git)  ─── the HelmRelease: which build, where from
      │
      ▼  agent polls git (pull), never evaluates
   host:  read pointer → realise store path from cache → activate → reboot
```

Container analogy: the **closure** is the image (content-addressed), the
**binary cache** is the registry, `releases/<host>.json` is the tag, and the
agent is the reconciler.

### Why the host physically cannot build

The host receives a **store path**, not a derivation and not a flake. Realising
a path whose `.drv` is absent can only **substitute** it — there is nothing to
build from. "Never build locally" is therefore structural, not a flag that can
be misconfigured. If the cache lacks the path, the fetch fails and the pipeline
**defers to the next tick** (it never falls back to compiling).

This is also why v1's `NIX_REMOTE=local` + CPU/IO/memory limits on the build
unit are gone: there is no local compilation left to throttle.

## Phases

Same four-phase skeleton, same fixed-name units, gates, hold, and status file.
Only the second phase changes.

| Phase | v1 | v2 |
| --- | --- | --- |
| **check** | git fetch, record `fetched_commit` | git fetch, read `releases/<host>.json`, record `desired_path` |
| **build** → **fetch** | checkout + `nix build` toplevel | `nix copy --from <cache>` the store path (substitute-only), GC-root it |
| **activate** | set profile + `switch-to-configuration` | unchanged |
| **reboot** | kernel/initrd/params compare + gate | unchanged |

`activate`, `reboot`, the gates, hold/unhold, hooks, `status.json` and the
transient-unit invariant (see [AGENTS.md](AGENTS.md)) are **reused as-is**.

## The pointer

`releases/<host>.json`, written by the builder, committed to git:

```json
{
  "storePath": "/nix/store/xxxx-nixos-system-nas-26.05",
  "system": "x86_64-linux",
  "operation": "switch",
  "builtFrom": { "commit": "abc1234", "flake": "hosts/nas" },
  "builtAt": "2026-08-11T09:00:00Z"
}
```

- `storePath` — the artifact. This is the whole desired system state.
- `operation` — optional per-release override of `activate.mode`
  (`switch` | `boot`), so a risky release can be staged for next boot without
  touching the host's config.
- `builtFrom` / `builtAt` — provenance for humans and `nixos-update status`.

Rollout *policy* (gates, windows, hold) stays in the host's NixOS config: gates
are shell scripts, and executing scripts fetched from the pointer would widen
the trust boundary for no gain. The pointer decides **what**, the module decides
**when**.

## Ordering invariant (the one that matters)

The builder must **push the closure to the cache before committing the
pointer** — same as pushing an image before moving the tag. A pointer that
names a path the cache does not have makes every host defer until it appears.
`just deploy` enforces this order.

## Cache

The agent only needs a **substituter URL + a trusted public key**, so the
backend is swappable and the module is backend-agnostic:

- **harmonia / nix-serve** — serves one always-on host's store over HTTP.
  Simplest to run. All hosts' closures live in one store, so shared paths are
  stored once, and `nix.settings.auto-optimise-store` additionally hardlinks
  identical files.
- **S3 / MinIO / R2** — plain object storage, maximally mature, no server logic.
  Manual GC, self-managed signing key.
- ~~attic~~ — chunk-level dedup, but self-described as an early prototype; not
  used here.

Dedup note: a cache is keyed by store path, so paths **shared between hosts are
uploaded and stored once on every backend**. Only dedup *between different
versions* of a path (churn) differs between backends.

**Signing.** Two independent things need signatures:
1. the **closure** — cache signing key; hosts list it in `trusted-public-keys`;
2. the **pointer commit** — otherwise a tampered pointer could aim a host at a
   different (validly signed, but wrong) closure.

Secrets are not in the closure (they are age-decrypted at runtime), so the cache
holds only software and config.

## Garbage collection

The artifact must survive GC on both ends:

- **host** — the fetched path is GC-rooted at
  `/var/lib/nixos-mgmt/pending-system` until activation makes it the system
  profile (unchanged from v1).
- **cache host** — closures must be GC-rooted for as long as any pointer may
  reference them (current release plus enough history to roll back to).

## Rollback

Rollback is a store path and a profile: the previous generation is still on the
host and GC-rooted, so reverting is `nix-env --set` + `switch-to-configuration`
with **no download**. Reverting the pointer commit converges the fleet back.

## Cross-architecture

`nix build .#nixosConfigurations.<host>…` builds for that host's
`nixpkgs.hostPlatform`; the builder reaches aarch64 via qemu binfmt
(`extra-platforms = aarch64-linux`, as `hosts/pished` already does) or a native
remote builder. Only locally-changed derivations are emulated — the rest
substitutes from `cache.nixos.org`. Nothing about the agent is
architecture-specific; only same-architecture closures share store paths.

## What v1 machinery is retired

`flakeOutput`, `flakeSubdir`, `build.resources.*` (cpuWeight/nice/io/memoryHigh/
cores/maxJobs) and the repo checkout on the target. The target no longer holds a
working tree of the config at all — it only reads a pointer file.
