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
#     directly from the reference laptop's own knowledge base
#     (the reference deployment's own notes). A box can have the right
#     cmdline params AND still end up with zswap silently off if that rule
#     isn't overridden. This check's failure message names that gotcha
#     explicitly, not just "add these cmdline params" -- the same class of
#     "silently inert, no error" trap this project already hit once with
#     `services.zram-generator.enable` on the NixOS side.

{ lib, config, ... }:

let
  cfg = config.nixram;

  checkScript = ''
    set -euo pipefail

    fail=0
    param_path=/sys/module/zswap/parameters

    # "Is zswap compiled in at all" is a property of the DIRECTORY, not of any
    # one parameter -- ask it once, here, so a per-parameter absence can carry
    # its own (different) meaning below.
    if [ ! -d "$param_path" ]; then
      echo "nixram: $param_path does not exist -- zswap is not compiled into this kernel (CONFIG_ZSWAP=n)." >&2
      exit 1
    fi

    check_param() {
      name="$1"
      expected="$2"
      if [ ! -e "$param_path/$name" ]; then
        echo "nixram: $param_path/$name does not exist, but zswap IS compiled in -- unexpected kernel parameter layout." >&2
        fail=1
        return
      fi
      actual=$(cat "$param_path/$name")
      if [ "$actual" != "$expected" ]; then
        echo "nixram: zswap.$name is '$actual', expected '$expected'" >&2
        fail=1
      fi
    }

    # A parameter that upstream may legitimately have REMOVED. Absent = nothing
    # to verify, not a failure; present = still verified exactly as before.
    check_param_optional() {
      name="$1"
      expected="$2"
      if [ ! -e "$param_path/$name" ]; then
        echo "nixram: zswap.$name not exposed by this kernel -- skipping (see the zpool note in nixram's zswap-boot-params-check.nix)"
        return
      fi
      check_param "$name" "$expected"
    }

    check_param enabled Y
    check_param compressor zstd
    # zpool is OPTIONAL, and that is not laziness. zbud and z3fold were removed
    # from zswap upstream in Linux 6.13, leaving zsmalloc as the only backend,
    # and the `zpool` module parameter was removed with them -- verified on a
    # live 7.1 CachyOS kernel whose /sys/module/zswap/parameters/ holds exactly
    # five entries and no `zpool`. Treating that absence as a hard failure made
    # `mode = "zswap"` UNACTIVATABLE on every current kernel, which is the exact
    # opposite of this check's purpose. On kernels that do still expose it the
    # check keeps its full value: there zbud, not zsmalloc, was the compiled-in
    # default, so an unset zswap.zpool really did mean the wrong allocator.
    check_param_optional zpool zsmalloc
    check_param max_pool_percent ${toString cfg.zswap.maxPoolPercent}
    check_param accept_threshold_percent ${toString cfg.zswap.acceptThresholdPercent}
    check_param shrinker_enabled ${if cfg.zswap.shrinkerEnabled then "Y" else "N"}

    # Only suggest a cmdline parameter this kernel actually still understands --
    # telling someone to paste `zswap.zpool=zsmalloc` into a 6.13+ cmdline just
    # earns them an "Unknown kernel command line parameters" line in dmesg.
    zpool_param=""
    if [ -e "$param_path/zpool" ]; then
      zpool_param=" zswap.zpool=zsmalloc"
    fi

    if [ "$fail" != "0" ]; then
      echo "" >&2
      echo "nixram: nixram.mode = \"zswap\" requires zswap already active with these" >&2
      echo "values, set via the KERNEL COMMAND LINE -- system-manager cannot set this itself" >&2
      echo "(it never touches the bootloader; this is the one piece of nixram's zswap profile" >&2
      echo "that stays a manual, one-time step, same spirit as 'nix run <flake>#detect-level')." >&2
      echo "" >&2
      echo "Add to the kernel command line (e.g. /etc/kernel/cmdline + limine-mkinitcpio, or" >&2
      echo "your bootloader's equivalent) and reboot:" >&2
      echo "" >&2
      echo "    zswap.enabled=1 zswap.compressor=zstd''${zpool_param} zswap.max_pool_percent=${toString cfg.zswap.maxPoolPercent} zswap.accept_threshold_percent=${toString cfg.zswap.acceptThresholdPercent} zswap.shrinker_enabled=${if cfg.zswap.shrinkerEnabled then "1" else "0"}" >&2
      echo "" >&2
      echo "If those params are already present and this still fails: on CachyOS (and any" >&2
      echo "distro sharing its cachyos-settings package), check for a udev rule that disables" >&2
      echo "zswap whenever a zram device is detected --" >&2
      echo "/usr/lib/udev/rules.d/30-zram.rules. Override it with an EMPTY file at" >&2
      echo "/etc/udev/rules.d/30-zram.rules (same fix the reference laptop's own real deployment uses)." >&2
      exit 1
    fi

    echo "nixram: zswap verified active (compressor=zstd''${zpool_param:+, zpool=zsmalloc}, max_pool_percent=${toString cfg.zswap.maxPoolPercent}, accept_threshold_percent=${toString cfg.zswap.acceptThresholdPercent}, shrinker_enabled=${if cfg.zswap.shrinkerEnabled then "Y" else "N"})"
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
