# opencode conventions

## Critical invariant: the target never builds

v2 ships hosts a pre-built **store path** (see DESIGN-v2.md), never a flake or a
derivation. That is what keeps eval and compile — the parts that thrash small
machines — off the target entirely. Do not "helpfully" add a fallback that
builds locally when the cache is missing the closure: the correct behaviour when
a fetch fails is to defer and retry, and the absence of a `.drv` on the host is
what makes "never build here" structural rather than a flag.

Related: never pass `--no-check-sigs` to the fetch. Closure signatures are the
only thing standing between the cache and arbitrary code running as the system.

## Critical invariant: the builder pushes before it points

`nixos-release` must copy the closure to the cache **before** writing/committing
the release pointer, exactly like pushing an image before moving the tag. A
pointer that names a closure the cache does not have stalls every host that sees
it. Keep those two steps in that order.

## Critical invariant: activation must run in a transient systemd unit

`switch-to-configuration switch` stops/restarts declared units whose definitions
changed — including the unit performing the switch itself. If the apply/activate
step ran in a declared (named, config-managed) unit and an update changed that
unit's definition, the switch would kill its own unit mid-activation and the
update would fail. That is why the apply is launched via `systemd-run` as a
transient unit: transient units are not part of the declared configuration and
are never stopped by activation.

Never "clean up" the `systemd-run` invocation into a regular declared service.
A fixed transient unit *name* is fine (gives mutual exclusion and queryable
logs); transience itself is the load-bearing part. See DESIGN.md.

## Build & test

- `just check` — run `nix flake check`
- `just test` — run `nix flake check && nix build .#checks.x86_64-linux.integration`
- `just debug` — build the integration test driver for interactive use

## Rule: never commit and push in this repository

All changes must be vetted by the user before being committed.
