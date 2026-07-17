# modules/zswap.nix
#
# zswap is a compressed CACHE in front of a real disk-backed swap
# device, not a swap device itself -- structurally different from zram
# (see docs/faq.md). `services.nixram.mode = "zswap"` is for
# laptops/desktops that already have `swapDevices`; the assertion that
# enforces this lives in modules/default.nix.
#
# WIRING CAVEAT, STATED PLAINLY: zswap.enabled is a kernel boot
# parameter, off by default upstream. Setting
# `services.nixram.mode = "zswap"` only takes effect on the NEXT BOOT --
# `nixos-rebuild switch` alone does not retroactively enable zswap on an
# already-running kernel. This is a real limitation of going through
# `boot.kernelParams`, not a nixram shortcut; document it to users, don't
# bury it.

{ lib, config, ... }:

with lib;

let
  cfg = config.services.nixram;
in
{
  config = mkIf (cfg.enable && cfg.mode == "zswap") {
    boot.kernelParams = [
      "zswap.enabled=1"
      "zswap.compressor=zstd"
      "zswap.zpool=zsmalloc"
      # z3fold/zbud are not offered as options: current kernels' zswap
      # exclusively uses zsmalloc, any zpool selector besides it would
      # be dead configuration. See docs/rationale.md.
      "zswap.max_pool_percent=${toString cfg.zswap.maxPoolPercent}"
      "zswap.accept_threshold_percent=${toString cfg.zswap.acceptThresholdPercent}"
    ] ++ optional cfg.zswap.shrinkerEnabled "zswap.shrinker_enabled=1";
    # shrinker_enabled requires kernel >=6.8; unrecognized kernel
    # parameters are ignored (with a dmesg warning) on older kernels,
    # not fatal -- so this is always safe to pass.
  };
}
