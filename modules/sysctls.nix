# modules/sysctls.nix
#
# The vm.* sysctl layer, plus the one MGLRU knob that ISN'T a sysctl at
# all (min_ttl_ms lives under /sys/kernel/mm/lru_gen/, not /proc/sys/vm/,
# and is set via a systemd-tmpfiles rule instead).
#
# Every assignment uses `mkDefault`: a host is always free to override
# any single knob without needing `lib.mkForce`, per the project's
# "escape hatch on every layer" stance.
#
# swappiness and page-cluster are treated as properties of the SWAP
# MEDIUM, not the box's size (see docs/rationale.md [3][4]) -- so unlike
# every other knob here, they branch on `mode`, not on the level, and
# `mode = "none"` deliberately leaves both untouched (there is no
# managed swap medium to have an opinion about).

{ lib, config, ... }:

with lib;

let
  cfg = config.services.nixram;
  levelsData = import ../levels.nix;
  inherit (levelsData) levelNames levels;

  # See modules/default.nix "EVAL SAFETY".
  activeLevelName = if cfg.level != null then cfg.level else builtins.head levelNames;
  activeLevel = levels.${activeLevelName};

  # zswap gets its own flat swappiness, distinct from zram's flat 180:
  # zswap is only a PARTIALLY cheap medium (a cache hit is cheap RAM-
  # speed decompression, a cache miss is a real disk read), so it sits
  # between the kernel's plain-disk default (60) and zram's medium-
  # cost-justified 180 rather than at either pole. Reasoned tradeoff,
  # not a verified upstream number -- see docs/rationale.md.
  zswapSwappiness = 120;

  # Disk-medium property, distinct from zram's page-cluster=0: once a
  # zswap cache miss happens, the page is still coming from a real
  # block device, so the readahead-cost logic that justifies 0 for zram
  # doesn't apply. Pop!_OS's own distinction: 2 for SSD swap, kernel
  # default (3, left untouched) for HDD swap.
  zswapPageCluster = if cfg.zswap.diskMedium == "ssd" then 2 else null;

  # zswap's own profile reuses the Pop!_OS-validated FLAT 125, rather
  # than the zram/server table's RAM-size taper: the taper is justified
  # by burst-absorption slack on long-running SERVER workloads, which
  # doesn't describe the shorter-lived, interactive pressure pattern
  # typical of a laptop/desktop session. sourced -- docs/rationale.md.
  zswapWatermarkScaleFactor = 125;

  finalMinFreeKbytes =
    if cfg.minFreeKbytesOverride != null
    then cfg.minFreeKbytesOverride
    else activeLevel.minFreeKbytesOverride;
in
{
  config = mkIf (cfg.enable && cfg.sysctls.enable) {
    boot.kernel.sysctl = mkMerge [
      {
        "vm.watermark_boost_factor" = mkDefault activeLevel.watermarkBoostFactor;
        "vm.watermark_scale_factor" = mkDefault (
          if cfg.mode == "zswap" then zswapWatermarkScaleFactor else activeLevel.watermarkScaleFactor
        );
      }
      (mkIf (cfg.mode == "zram") {
        # Medium properties, identical at every level BY DESIGN (see the
        # header comment) -- which is why they live here as constants
        # and not in levels.nix at all.
        "vm.swappiness" = mkDefault 180; # sourced -- rationale.md [3]
        "vm.page-cluster" = mkDefault 0; # sourced -- rationale.md [4]
      })
      (mkIf (cfg.mode == "zswap") ({
        "vm.swappiness" = mkDefault zswapSwappiness;
      } // optionalAttrs (zswapPageCluster != null) {
        "vm.page-cluster" = mkDefault zswapPageCluster;
      }))
      (mkIf (finalMinFreeKbytes != null) {
        "vm.min_free_kbytes" = mkDefault finalMinFreeKbytes;
      })
    ];

    # MGLRU min_ttl_ms lives under /sys/kernel/mm/lru_gen/, not
    # /proc/sys/vm/ -- a systemd-tmpfiles "w" rule, not a sysctl. Applied
    # regardless of `mode`: the kernel docs frame it as thrash
    # prevention "for users who do not have oomd" -- complementary to,
    # not redundant with, the oomd layer, and useful even on a
    # mode="none" box. Silently a no-op if MGLRU isn't compiled in
    # (CONFIG_LRU_GEN absent): systemd-tmpfiles logs a warning for a
    # missing target path on a "w" line rather than failing the boot.
    systemd.tmpfiles.rules = [
      "w /sys/kernel/mm/lru_gen/min_ttl_ms - - - - ${toString activeLevel.mglruMinTtlMs}"
    ];
  };
}
