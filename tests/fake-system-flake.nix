# Test fixture flake, materialised via substituteAll (@bash@, @coreutils@,
# @kerneltarget@). It exposes
#   nixosConfigurations.autoupdate.config.system.build.toplevel
# as a *raw* derivation (no nixpkgs evaluation) so the build phase's real
# `nix build ...toplevel` is cheap inside the test VM. The fake toplevel ships a
# switch-to-configuration that records the version and repoints
# /run/current-system, plus kernel/initrd/... entries that drive the module's
# reboot-needed comparison. @kerneltarget@ selects whether a reboot is needed:
#   /run/booted-system/kernel  -> matches booted, no reboot (config-only change)
#   /run/booted-system/initrd  -> differs from booted, reboot required
{
  outputs =
    { self }:
    let
      version = builtins.replaceStrings [ "\n" ] [ "" ] (builtins.readFile ./version);
      toplevel = builtins.derivation {
        name = "fake-system-${version}";
        system = "@system@";
        builder = "@bash@/bin/bash";
        args = [
          "-c"
          # The single-quoted printf args keep $0/$SELF/$TOP literal (expanded at
          # runtime by the generated script); Nix interpolates ${version}.
          ''
            @coreutils@/bin/mkdir -p $out/bin
            @coreutils@/bin/printf '%s\n' \
              '#!@bash@/bin/bash' \
              '@coreutils@/bin/echo "${version}" > /var/lib/selfupdate-version' \
              'SELF="$(@coreutils@/bin/readlink -f "$0")"' \
              'TOP="$(@coreutils@/bin/dirname "$(@coreutils@/bin/dirname "$SELF")")"' \
              '@coreutils@/bin/ln -sfn "$TOP" /run/current-system' \
              'exit 0' \
              > $out/bin/switch-to-configuration
            @coreutils@/bin/chmod +x $out/bin/switch-to-configuration
            @coreutils@/bin/ln -s @kerneltarget@ $out/kernel
            @coreutils@/bin/ln -s /run/booted-system/initrd $out/initrd
            @coreutils@/bin/ln -s /run/booted-system/kernel-modules $out/kernel-modules
            @coreutils@/bin/ln -s /run/booted-system/kernel-params $out/kernel-params
          ''
        ];
      };
    in
    {
      nixosConfigurations.autoupdate.config.system.build.toplevel = toplevel;
    };
}
