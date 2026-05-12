check:
    nix flake check

test: check
    nix build ".#checks.x86_64-linux.integration"

debug:
    nix build ".#checks.x86_64-linux.integration.driverInteractive"
