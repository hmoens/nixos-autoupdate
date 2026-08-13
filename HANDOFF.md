# Handoff

## Branches

- **`phased-pipeline`** — v1: four-phase pipeline that builds *on the target*
  ([DESIGN.md](DESIGN.md)). Validated on x86_64-linux (both VM tests +
  `nix flake check` pass). Superseded by v2, kept for reference.
- **`v2`** (current) — artifact-pull: the target downloads a **pre-built system
  closure** named by a git release pointer ([DESIGN-v2.md](DESIGN-v2.md)).

Nothing is committed on either branch (AGENTS.md: never commit without review).
Review `v2` with `git diff phased-pipeline`.

## v2 status: implemented and validated

```
just test-integration   # pointer -> signed download -> activate, hold/unhold  -> PASS
just test-reboot        # reboot detection + gate deferral + boot-mode staging -> PASS
nix flake check         # module + package + both checks                       -> PASS (exit 0)
just lint               # bash -n over all scripts                             -> PASS
```

The integration test proves the real property: it asserts the target does **not**
have the closure (`nix-store --check-validity` must fail), then observes
`copying path '…' from 'http://gitserver'` during the fetch phase — a genuine
signed download from a binary cache the builder published to.

## What changed from v1

| v1 | v2 |
| --- | --- |
| `check.sh` git fetch + `fetched_commit` | polls the pointer, reads `releases/<host>.json` via `git show` from a `--no-checkout` clone |
| `build.sh` checkout + eval + `nix build` | **`fetch.sh`**: `nix copy --from <cache>` + GC root. No eval, no build. |
| `activate.sh` / `apply.sh` / `reboot.sh` | reused; state is store paths, not commits |
| `flakeOutput`, `flakeSubdir`, `build.resources.*` | removed (nothing is compiled on the target) |
| — | **`cache.url` / `cache.publicKey`**, `releaseFile`, `verifyCommitSignatures` |
| — | **`scripts/nixos-release`** (builder side), exposed as `packages.<sys>.nixos-release` |

State (`status.json`) now tracks `desired_path` / `fetched_path` / `applied_path`
(+ `desired_commit` for provenance) instead of commits. `applied_path` is seeded
on first run from `readlink -f /run/current-system`, so a fresh host already
knows what it runs.

Hook events: `BUILD_*` → `FETCH_*`. New env var `AUTOUPDATE_STORE_PATH`;
`AUTOUPDATE_CHECKED_OUT_COMMIT` kept (now the source commit) so existing hook
scripts keep working.

## Open decisions (not blocking)

- **Cache backend.** Deliberately abstracted to a substituter URL + public key,
  so harmonia / nix-serve / S3 / MinIO all work with no code change. attic was
  ruled out (self-described early prototype). Suggested starting point: harmonia
  on the always-on nas.
- **Where pointers live.** Currently the same repo as the config
  (`releases/<host>.json`). A separate releases repo would narrow what hosts can
  read, at the cost of another repo to manage.
- **Not yet wired:** a `just deploy <host>` recipe in the config repo
  (`/home/hmoens/src/nixws/nix`) calling `nixos-release`, and a real cache on the
  nas. `hosts/pished` (Pi 3, 1 GB, aarch64) is the intended first beneficiary —
  it is eval-bound, which a remote builder could not have fixed.

## Invariants (see AGENTS.md)

1. The target never builds — no local-build fallback when the cache lacks the
   closure; defer and retry instead.
2. The builder pushes the closure to the cache **before** committing the pointer.
3. Never pass `--no-check-sigs` to the fetch.
4. The live switch stays in a *transient* systemd unit.
