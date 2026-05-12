check:
    nix flake check

test: check
    @echo "Running integration test..."
    nix build --rebuild -L ".#checks.x86_64-linux.integration"
    @echo "Integration test: PASSED"

debug:
    nix build ".#checks.x86_64-linux.integration.driverInteractive"
