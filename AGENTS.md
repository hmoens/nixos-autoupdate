# opencode conventions

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
