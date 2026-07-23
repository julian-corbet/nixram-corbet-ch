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
# page-cluster is a property of the SWAP MEDIUM, not the box's size (see
# docs/rationale.md [4]) -- it branches on `mode`, not the level, and
# `mode = "none"` deliberately leaves it untouched (there is no managed
# swap medium to have an opinion about).
#
# swappiness for zram DOES vary by level (docs/rationale.md [3]): it is
# not purely a medium-cost question -- the medium-cost ratio (zram is
# cheap to swap into) is scale-invariant and argues for a flat value,
# but a SEPARATE, real consideration doesn't stay flat: how much true
# RAM remains behind the physical leg, and how much file cache a box
# has available to sacrifice before ever touching anon memory at all.
# Tiny/dire tiers have little of either and must push into zram
# willingly; larger tiers have enough of both to be reluctant. See
# levels.nix's per-tier `swappiness` field and rationale.md [3].
#
# DELIBERATELY NOT SETTING `vm.admin_reserve_kbytes` / `vm.user_reserve_kbytes`
# ANYWHERE, even though elitebook's own real config sets both. Verified
# directly against the kernel's own `__vm_enough_memory` accounting logic
# (mm/util.c): both reserve values are ONLY consulted under
# `overcommit_memory=2` ("never overcommit") -- under `overcommit_memory=1`
# (nixram's own zswap-mode value, see `zswapOvercommitMemory` below) the
# function returns success unconditionally before either reserve is ever
# read. Elitebook's own live 131072/131072 values are therefore currently
# INERT given its own overcommit_memory=1 -- real, harmless dead
# configuration, not a bug, but not something to propagate into nixram as
# a "working" default either. Setting either reserve here would be cargo
# culting a number that does nothing under this project's own overcommit
# stance; nixram has no `overcommit_memory=2` use case anywhere.

{ lib, config, ... }:

with lib;

let
  cfg = config.services.nixram;
  levelsData = import ../levels.nix;
  inherit (levelsData) levelNames levels;

  # See modules/default.nix "EVAL SAFETY".
  activeLevelName = if cfg.level != null then cfg.level else builtins.head levelNames;
  activeLevel = levels.${activeLevelName};

  # zswap's own flat swappiness -- directed, not extrapolated: Julian
  # named 25 directly ("the only zswap box is elitebook"), reversing an
  # earlier reasoned-midpoint value of 120. A zswap cache miss is a REAL
  # disk read, worse than the reluctant zram tiers' worst case, so it
  # should be more reluctant still, not less -- and it's this project's
  # one real production data point: the elitebook runs zswap live and
  # independently converged on 25 for exactly this reason (a mixed
  # LLM+browser workload that needs anon memory to stay resident, not
  # get pushed to a disk-backed cache). See docs/rationale.md [3].
  zswapSwappiness = 25;

  # Disk-medium property, distinct from zram's page-cluster=0: once a
  # zswap cache miss happens, the page is still coming from a real
  # block device, so the readahead-cost logic that justifies 0 for zram
  # doesn't apply. Pop!_OS's own distinction: 2 for SSD swap, kernel
  # default (3, left untouched) for HDD swap.
  zswapPageCluster = if cfg.zswap.diskMedium == "ssd" then 2 else null;

  # directed -- Julian: "for the elitebook at least adapt to what it has
  # now." An earlier version of this profile reused the Pop!_OS-validated
  # flat 125, reasoning the server table's RAM-size taper doesn't apply
  # to a laptop/desktop's shorter-lived, interactive pressure pattern --
  # a plausible argument, but it was never actually checked against this
  # project's own real zswap box. It now is: elitebook runs 50 in
  # production (halved from an earlier 100, after a real incident where
  # 100 amplified a reclaim feedback loop under CPU contention). 50 is
  # this project's own real, incident-tested data point; 125 was a
  # plausible-sounding but unverified substitute. See docs/rationale.md [5].
  zswapWatermarkScaleFactor = 50;

  # directed -- elitebook's real production value (kernel default is 100,
  # the "fair rate with respect to pagecache/swapcache" point). Lower means
  # the kernel prefers to retain dentry/inode caches rather than reclaim
  # them at the same rate as page cache -- elitebook's own reasoning: keep
  # some file cache for warm rereads, let page cache take the reclaim hit
  # slightly first. No zram-mode equivalent: this is the only real
  # production data point this project has for this sysctl at all, so it
  # stays zswap-only rather than guessed at for a server workload with no
  # comparable measurement. See docs/rationale.md [3] for the sibling
  # swappiness reasoning this pairs with.
  zswapVfsCachePressure = 80;

  # directed -- elitebook's real production value (kernel default is 0,
  # "guess" heuristic mode). Verified against the kernel's own
  # `__vm_enough_memory` accounting logic (mm/util.c): OVERCOMMIT_ALWAYS
  # (1) returns success unconditionally, before any reserve accounting
  # runs at all -- meaning this is the one sysctl here that isn't just "a
  # milder version of the default," it disables the kernel's own
  # allocation-rejection heuristic entirely, in favor of nixram's whole
  # reactive stance (PSI/oomd/compression handle pressure after an
  # allocation succeeds, rather than a heuristic guess rejecting it
  # upfront). Genuinely philosophy-aligned with nixram's own thesis, but
  # zswap-only for the same reason as vfsCachePressure above: no
  # comparable real data point exists for a zram-mode server workload, and
  # unlike a desktop, a server rejecting a request up front with a clean
  # ENOMEM may be preferable to letting it succeed and rely entirely on
  # reactive mechanisms to catch the fallout later -- a real open question
  # this project has not measured, not something to silently decide for
  # every zram tier by copying a desktop's value. See docs/faq.md.
  zswapOvercommitMemory = 1;

  # own-measured, real production evidence -- verified live via SSH against
  # three actual fleet boxes running zram (none of them nixram itself, all
  # three via an entirely separate hand-rolled zram-generator config), then
  # cross-checked against their own source repos, not just the live sysctl
  # dump alone (a first pass mischaracterized this exact value as "stale
  # leftover defaults" -- wrong; corrected after reading the actual config
  # history). e2-micro (1G, a real "dire" tier) runs vfs_cache_pressure=200
  # in production -- NOT inherited or accidental: it's "Step 5" of a
  # documented, red-teamed hardening bisection (infra
  # modules/nixos/profiles/base.nix), specifically chosen to evict
  # inode/dentry caches aggressively once memory gets genuinely tight on a
  # box with almost nothing to spare. a real 128G-class server (reluctant) and
  # vultr (512M, dire) both sit at the untouched kernel default
  # (100) for this sysctl -- no comparable real evidence exists for a
  # reluctant-tier server, so this stays scoped to dire tiers only, the one
  # place a real, validated production data point actually exists.
  zramDireVfsCachePressure = 200;

  # extrapolated, HEDGED -- weaker evidence than the vfs_cache_pressure case
  # above, stated plainly rather than overclaimed. A real 128G-class server
  # (reluctant) does run overcommit_memory=1 live, but grepping its own infra
  # repo top to bottom finds NO file that sets it deliberately for that
  # box -- it is plausibly just a k3s/Kubernetes convention (kubelet
  # preflight commonly wants this) riding along for an unrelated reason, not
  # evidence of deliberate zram-tier memory-pressure design the way
  # e2-micro's vfs_cache_pressure clearly is. Neither e2-micro nor
  # vultr set this sysctl at all (both sit at the plain kernel
  # default, 0). The MECHANISM argument still stands on its own regardless
  # of how the 128G-class server got there: reluctant tiers already carry the
  # PSI-gated swappiness relief valve ([17]) specifically to catch overflow
  # reactively, so permissive overcommit (let an allocation succeed, rely on
  # relief-valve/oomd/compression to handle real fallout) fits that same
  # design ethos -- while dire tiers, with almost no slack to begin with,
  # plausibly benefit more from the kernel's own upfront heuristic
  # rejection than from a permissive stance banking entirely on reactive
  # machinery. Reasoned, not proven by the fleet sample it happened to be
  # checked against -- scoped to reluctant tiers only, tagged extrapolated
  # rather than directed for exactly that reason.
  zramReluctantOvercommitMemory = 1;

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
      (mkIf (cfg.mode == "zram") ({
        # swappiness varies by level (see header comment); page-cluster
        # is a flat medium property, identical at every level.
        "vm.swappiness" = mkDefault activeLevel.swappiness; # rationale.md [3]
        "vm.page-cluster" = mkDefault 0; # sourced -- rationale.md [4]
      }
      # Dire tiers only (256M/512M/1G) -- own-measured from e2-micro's real
      # production value, see zramDireVfsCachePressure above. Reluctant
      # tiers stay untouched: no comparable evidence, and the tier already
      # has enough true RAM to not need aggressive dentry/inode eviction.
      // optionalAttrs (!activeLevel.swappinessReliefEnableByDefault) {
        "vm.vfs_cache_pressure" = mkDefault zramDireVfsCachePressure;
      }
      # Reluctant tiers only (2G-128G) -- extrapolated, hedged reasoning,
      # see zramReluctantOvercommitMemory above. Dire tiers stay untouched
      # (kernel default 0): no evidence favors going permissive on a box
      # with almost no slack to begin with.
      // optionalAttrs activeLevel.swappinessReliefEnableByDefault {
        "vm.overcommit_memory" = mkDefault zramReluctantOvercommitMemory;
      }))
      (mkIf (cfg.mode == "zswap") ({
        "vm.swappiness" = mkDefault zswapSwappiness;
        "vm.vfs_cache_pressure" = mkDefault zswapVfsCachePressure;
        "vm.overcommit_memory" = mkDefault zswapOvercommitMemory;
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
