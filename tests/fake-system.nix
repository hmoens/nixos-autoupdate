# A fake system toplevel for the VM tests, standing in for
# `config.system.build.toplevel`.
#
# In v2 the artifact is built by the *builder* and shipped as a closure, so
# unlike v1 this is an ordinary derivation rather than an in-VM flake build.
# It deliberately has an (almost) empty closure: the script uses /bin/sh and
# resolves its tools from PATH, so nothing but the output itself has to travel
# through the binary cache.
#
# It ships:
#   - bin/switch-to-configuration: records the version and repoints
#     /run/current-system, like the real activation would;
#   - kernel/initrd/kernel-modules/kernel-params: dangling symlinks into
#     /run/booted-system/*, which drive the module's reboot-needed comparison.
#     `kernelTarget` selects the outcome:
#       /run/booted-system/kernel -> matches booted  => no reboot needed
#       /run/booted-system/initrd -> differs         => reboot required
#   - sw: symlink to the booted system's sw, so that once /run/current-system
#     points here, the NixOS test backdoor's `/run/current-system/sw/bin` PATH
#     entry still resolves and the driver can keep running commands.
{ pkgs }:

{
  version,
  kernelTarget ? "/run/booted-system/kernel",
}:

pkgs.runCommand "fake-system-${version}" { } ''
  mkdir -p $out/bin
  cat > $out/bin/switch-to-configuration <<'SCRIPT'
#!/bin/sh
echo "@VERSION@" > /var/lib/selfupdate-version
SELF="$(readlink -f "$0")"
TOP="$(dirname "$(dirname "$SELF")")"
ln -sfn "$TOP" /run/current-system
exit 0
SCRIPT
  substituteInPlace $out/bin/switch-to-configuration \
    --replace-fail '@VERSION@' '${version}'
  chmod +x $out/bin/switch-to-configuration

  ln -s ${kernelTarget} $out/kernel
  ln -s /run/booted-system/initrd $out/initrd
  ln -s /run/booted-system/kernel-modules $out/kernel-modules
  ln -s /run/booted-system/kernel-params $out/kernel-params
  ln -s /run/booted-system/sw $out/sw
''
