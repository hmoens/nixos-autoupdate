check:
    nix flake check

test: check
    @echo "Running all tests..."
    @failed=""; \
    for t in defaultRebuildCommand integration reboot; do \
        printf "  %-12s " "$t"; \
        if nix build --rebuild --no-link ".#checks.x86_64-linux.$t" > /tmp/nix-test-$t.log 2>&1; then \
            echo "PASSED"; \
        else \
            echo "FAILED"; \
            cat /tmp/nix-test-$t.log; \
            failed="$failed $t"; \
        fi; \
    done; \
    if [ -n "$failed" ]; then echo "FAILED:$failed" && exit 1; else echo "All tests PASSED"; fi

test-integration:
    nix build --rebuild -L ".#checks.x86_64-linux.integration"
    @echo "integration: PASSED"

test-reboot:
    nix build --rebuild -L ".#checks.x86_64-linux.reboot"
    @echo "reboot: PASSED"

debug-integration:
    nix build ".#checks.x86_64-linux.integration.driverInteractive"

debug-reboot:
    nix build ".#checks.x86_64-linux.reboot.driverInteractive"
