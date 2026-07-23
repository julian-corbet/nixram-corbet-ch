# system-manager/zswap-boot-params-check.nix
#
# The NixOS module sets zswap's enabled/compressor/zpool/max_pool_percent/
# accept_threshold_percent/shrinker_enabled via `boot.kernelParams` (the
# kernel command line) -- system-manager has no equivalent option at all (see
# default.nix's header comment; it never touches the bootloader). Rather than
# silently assume those params are already set correctly on the host and
# deploy sysctls/oomd config on top of a possibly-inactive zswap, this uses
# system-manager's real `system-manager.preActivationAssertions` mechanism
# (a genuine runtime check, not an eval-time assumption) to verify zswap is
# actually live with the expected values BEFORE activation proceeds, and
# fails with the exact fix if it isn't.
#
# Two real, confirmed facts this check leans on:
#   - zswap's own kernel module parameters ARE exposed as plain, readable
#     files under /sys/module/zswap/parameters/ once the kernel boots with
#     them set -- this check only READS those files, it does not attempt to
#     write them (writing them post-boot to "fix" a mismatch would be
#     papering over a boot-time config gap, not closing it; see docs/faq.md's
#     stance on `nixram.level` for the same "detect once, paste once, don't
#     auto-fix" philosophy applied here).
#   - CachyOS ships a udev rule (`/usr/lib/udev/rules.d/30-zram.rules`) that
#     DISABLES zswap the moment it detects any zram device -- confirmed
#     directly from elitebook's own knowledge base
#     (knowledge/fleet/elitebook/responsiveness.md). A box can have the right
#     cmdline params AND still end up with zswap silently off if that rule
#     isn't overridden. This check's failure message names that gotcha
#     explicitly, not just "add these cmdline params" -- the same class of
#     "silently inert, no error" trap this project already hit once with
#     `services.zram-generator.enable` on the NixOS side.

{ lib, config, ... }:

let
  cfg = config.services.nixram;

  checkScript = ''
    set -euo pipefail

    fail=0
    param_path=/sys/module/zswap/parameters

    check_param() {
      name="$1"
      expected="$2"
      if [ ! -e "$param_path/$name" ]; then
        echo "nixram: $param_path/$name does not exist -- is zswap compiled into this kernel at all (CONFIG_ZSWAP)?" >&2
        fail=1
        return
      fi
      actual=$(cat "$param_path/$name")
      if [ "$actual" != "$expected" ]; then
        echo "nixram: zswap.$name is '$actual', expected '$expected'" >&2
        fail=1
      fi
    }

    check_param enabled Y
    check_param max_pool_percent ${toString cfg.zswap.maxPoolPercent}
    check_param shrinker_enabled ${if cfg.zswap.shrinkerEnabled then "Y" else "N"}

    if [ "$fail" != "0" ]; then
      echo "" >&2
      echo "nixram: services.nixram.mode = \"zswap\" requires zswap already active with these" >&2
      echo "values, set via the KERNEL COMMAND LINE -- system-manager cannot set this itself" >&2
      echo "(it never touches the bootloader; this is the one piece of nixram's zswap profile" >&2
      echo "that stays a manual, one-time step, same spirit as 'nix run <flake>#detect-level')." >&2
      echo "" >&2
      echo "Add to the kernel command line (e.g. /etc/kernel/cmdline + limine-mkinitcpio, or" >&2
      echo "your bootloader's equivalent) and reboot:" >&2
      echo "" >&2
      echo "    zswap.enabled=1 zswap.shrinker_enabled=${if cfg.zswap.shrinkerEnabled then "1" else "0"} zswap.max_pool_percent=${toString cfg.zswap.maxPoolPercent}" >&2
      echo "" >&2
      echo "If those params are already present and this still fails: on CachyOS (and any" >&2
      echo "distro sharing its cachyos-settings package), check for a udev rule that disables" >&2
      echo "zswap whenever a zram device is detected --" >&2
      echo "/usr/lib/udev/rules.d/30-zram.rules. Override it with an EMPTY file at" >&2
      echo "/etc/udev/rules.d/30-zram.rules (same fix elitebook's own real deployment uses)." >&2
      exit 1
    fi

    echo "nixram: zswap verified active (max_pool_percent=${toString cfg.zswap.maxPoolPercent}, shrinker_enabled=${if cfg.zswap.shrinkerEnabled then "Y" else "N"})"
  '';
in
{
  config = lib.mkIf (cfg.enable && cfg.mode == "zswap") {
    system-manager.preActivationAssertions.nixram-zswap-active = {
      enable = true;
      script = checkScript;
    };
  };
}
