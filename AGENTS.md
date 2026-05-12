# opencode conventions

## Build & test
- `just check` — run `nix flake check`
- `just test` — run `nix flake check && nix build .#checks.x86_64-linux.integration`
- `just debug` — build the integration test driver for interactive use
