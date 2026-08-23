# levels.nix
#
# Pure data: the fourteen RAM-size anchor levels nixram is tuned for, and
# the exact values it applies at each one. This file contains no branching
# logic beyond the attribute set itself -- modules/*.nix read these values,
# they never decide anything from RAM size themselves.
#
# HONESTY TAXONOMY -- every tunable below carries one of four tags. The
# full citation for every "sourced" tag and the reasoning behind every
# "directed"/"extrapolated" tag lives in docs/rationale.md (numbered notes);
# the reader-facing table with the same tags is docs/levels.md.
#
#   sourced      a real upstream distro/kernel-doc default or bound,
#                applied as-is, or a formula whose ENDPOINTS are sourced
#                (the endpoints, not necessarily the taper between them).
#   directed     a literal value the operator specified (quoted or closely
#                paraphrased in rationale.md), applied as-is. Not this project's
#                inference -- the number itself is his.
#   extrapolated this project's own curve, cap, boundary placement, or causal
#                story standing on or between sourced/directed anchors.
#                Reasoned, not measured, and NOT something the operator said --
#                see rationale.md for exactly where the directed data
#                point(s) end and the extrapolation begins.
#   default      the kernel's own computed value, deliberately left
#                untouched. Not a nixram opinion at all.
#
# `ram` inside the diskSizeExpr strings below is zram-generator's own
# variable for total detected RAM in MiB -- evaluated by the generator
# against the machine's real /proc/meminfo at boot, not by Nix at eval
# time. This is why the same expr string appears on several levels: the
# FORMULA is what's tiered, not a number baked in per level.
#
# SIZING SAFETY, STATED PLAINLY (see docs/rationale.md [1]-[2]): disksize
# is zram's logical capacity and does not preallocate RAM. It is also the
# only safe capacity ceiling available to a swap device. The kernel's
# `mem_limit` is a hard block-write failure boundary: once allocated pool
# pages cross it, zram frees the new object and returns -ENOMEM. nixram
# therefore never sets zram-resident-limit and rejects a downstream module
# that tries to add a nonzero one. Physical use remains elastic beneath
# disksize; the normal reclaim/OOM machinery handles genuine RAM pressure.
#
# The diskSizeExpr curve remains `ram` for the dire 256M-1G tiers and
# `ram * 75 / 100` from 2G upward. Those are explicit logical-capacity
# policy values checked against the project's worked examples (not a
# promise of a separate physical budget): up to 1 GiB on the small end,
# and 96 GiB on a 128 GiB-class host.

{
  levelNames = [
    "256M" "512M" "1G" "2G" "4G" "6G" "8G"
    "10G" "12G" "16G" "24G" "32G" "64G" "128G"
  ];

  levels = {
    "256M" = {
      ramMiB = 256;

      zram = {
        diskSizeExpr = "ram";
        # extrapolated -- [1], a full-RAM logical capacity for the dire
        # tiers; this allocates nothing until pages are actually swapped.
        compressionAlgorithm = "zstd(level=3)";
        # directed -- the operator's explicit instruction: "make sure that
        # everything up to a GB goes to zstd primary and done." 256M-1G
        # share one shape: zstd(level=3) primary, no recompression at all.
        # rationale.md [9].
        recompressionAlgorithm = null;
        recompressionTimerEnableByDefault = false;
        priority = 100;
        # sourced -- zram-generator's own upstream default ships a
        # higher-than-normal swap priority so zram always wins over disk
        # swap when both exist. rationale.md [12] / faq.md.
      };

      swappiness = 120;
      # directed -- the operator's own figure, revised down from 130. The EAGER value:
      # once file cache is genuinely near-empty (true here), the anon:file
      # scan-target math collapses toward anon regardless of the exact
      # ratio, so most of the distance up toward 200's ceiling buys almost
      # nothing on WHICH pool gets picked. What high swappiness actually
      # changes is WHEN reclaim triggers at all (measured behavior: ~85%
      # mem-used trigger at swappiness=200 vs ~95% at swappiness=10) --
      # pure extra compress/decompress cycles, landing on the one tier
      # least able to spare CPU (fractional-vCPU class). 120 keeps the
      # directional eagerness (still well above the reluctant tiers' 10)
      # at a lower cost than 130 for no measured loss in pool-selection
      # benefit. rationale.md [3].
      swappinessReliefEnableByDefault = false;
      # extrapolated -- [3]. The PSI-gated relief valve exists for
      # RELUCTANT tiers, which deliberately hold swappiness low until
      # genuine pressure argues otherwise. Dire tiers are already eager by
      # design (lean into zram willingly, no low baseline to relieve from
      # in the first place), so there's nothing for a relief valve to do.
      watermarkScaleFactor = 200;   # extrapolated -- rationale.md [5]
      watermarkBoostFactor = 0;     # sourced -- rationale.md [5]
      minFreeKbytesOverride = null; # default -- rationale.md [6]
      mglruMinTtlMs = 0;            # own-measured -- rationale.md [7]

      oomd = {
        enable = false;
        # extrapolated, DELIBERATE -- a reasoned tradeoff, not a
        # measured number. oomd's idle RSS on a 256M box is UNMEASURED;
        # that measurement is experiments/001. rationale.md [8].
        pressureLimitPercent = 60;  # sourced (dormant while disabled)
        pressureDurationSec = 30;   # sourced (dormant while disabled)
      };
    };

    "512M" = {
      ramMiB = 512;
      zram = {
        diskSizeExpr = "ram";  # extrapolated -- [1], full-RAM logical capacity
        compressionAlgorithm = "zstd(level=3)"; # directed, the operator: "everything up to a GB goes to zstd primary and done" -- [9]
        recompressionAlgorithm = null;
        recompressionTimerEnableByDefault = false;
        # 256M-1G all share this shape -- see the 256M block above. rationale.md [9].
        priority = 100;                              # sourced -- [12]
      };
      swappiness = 120;             # directed -- [3] (dire/eager, same as 256M)
      swappinessReliefEnableByDefault = false; # extrapolated -- [3], no relief valve needed, dire tiers already eager
      watermarkScaleFactor = 200;   # extrapolated -- [5]
      watermarkBoostFactor = 0;     # sourced -- [5]
      minFreeKbytesOverride = null; # default -- [6]
      mglruMinTtlMs = 0;            # own-measured -- [7]
      oomd = {
        enable = true;              # extrapolated -- [8] (on above 256M)
        pressureLimitPercent = 60;  # sourced -- [10]
        pressureDurationSec = 30;   # sourced -- [10]
      };
    };

    "1G" = {
      ramMiB = 1024;
      zram = {
        diskSizeExpr = "ram";  # extrapolated -- [1], full-RAM logical capacity
        compressionAlgorithm = "zstd(level=3)"; # directed -- [9], the operator: "we go for zstd directly"
        recompressionAlgorithm = null;
        recompressionTimerEnableByDefault = false;
        # zstd-primary/no-recompression -- 256M-1G all share this shape. rationale.md [9], [11].
        priority = 100;                              # sourced -- [12]
      };
      swappiness = 120;
      # directed -- EAGER, unified with 256M/512M: "with 1GB RAM, you need to get whatever you
      # can" describes urgency, not comfort -- the same "light usage, RAM-desperate" story that
      # justifies 256M/512M's eager value applies here too, not the "enough true RAM to wait"
      # story reluctant tiers (2G+) are reasoned from. rationale.md [3].
      swappinessReliefEnableByDefault = false;
      # extrapolated -- [3], no relief valve needed, dire tiers already eager
      watermarkScaleFactor = 200;   # extrapolated -- [5]
      watermarkBoostFactor = 0;     # sourced -- [5]
      minFreeKbytesOverride = null; # default -- [6]
      mglruMinTtlMs = 0;            # own-measured -- [7]
      oomd = {
        enable = true;              # extrapolated -- [8]
        pressureLimitPercent = 60;  # sourced -- [10]
        pressureDurationSec = 30;   # sourced -- [10]
      };
    };

    "2G" = {
      ramMiB = 2048;
      zram = {
        diskSizeExpr = "ram * 75 / 100";  # extrapolated -- [1], logical capacity
        compressionAlgorithm = "lz4";
        # extrapolated, own-measured -- [9]. Cheap-primary + recompression, for a workload
        # compute-boundedness reason (see rationale.md [9]) -- this shape belongs to 2G+ only.
        #
        # THE CANONICAL SITE for why every recompression algorithm below is a BARE
        # algorithm name. The other ten tiers point back here.
        #
        # Plain "zstd", never "zstd(level=3)": zram-generator cannot deliver a level
        # to a RECOMPRESSION algorithm at all, so the parameterised form is not
        # merely redundant here, it is undeliverable. The two priorities take
        # different code paths in zram-generator's setup.rs (run_device_setup, the
        # `if prio == 0` fork):
        #
        #   prio 0 (primary)    params -> /sys/block/zramN/algorithm_params
        #                       as "algo=zstd level=3". That IS the kernel's
        #                       per-algorithm parameter interface (zram_drv.c
        #                       algorithm_params_store -> comp_params_store, which
        #                       parses priority/level/algo/dict and needs no
        #                       initialised device), so it works -- which is why the
        #                       256M/512M/1G primaries above keep their "(level=3)"
        #                       and must NOT be stripped.
        #   prio >= 1 (recomp)  params -> /sys/block/zramN/recompress
        #                       as "level=3 priority=1". Wrong file: `recompress` is
        #                       the pass TRIGGER, not a parameter store. Its parser
        #                       (zram_drv.c recompress_store) recognises exactly
        #                       type / max_pages / threshold / algo / priority and
        #                       SILENTLY SKIPS every other key, "level" included --
        #                       it does not reject it, it drops it on the floor. So
        #                       even a write that succeeds sets no level; it just
        #                       kicks off a recompression pass at whatever level the
        #                       priority already has. There is no zram-generator code
        #                       path that ever sends a level for prio >= 1.
        #
        # On top of that the write does not even succeed at boot, for a reason
        # unrelated to the key: setup.rs writes the algorithms FIRST and `disksize`
        # only afterwards, so at that moment the device is still uninitialised and
        # recompress_store bails on `if (!init_done(zram)) ret = -EINVAL`.
        # zram-generator degrades that to a warning, which it then misreports -- it
        # prints the recomp_algorithm string that DID get written, not the rejected
        # payload:
        #
        #   zram_generator::setup: Warning: algorithm "zstd" supplemental data
        #   "algo=zstd priority=1" not written: Invalid argument (os error 22)
        #
        # Measured on a live 128 GiB host: /sys/block/zram0/recomp_algorithm read
        # back "#1: lzo-rle lzo lz4 lz4hc [zstd] deflate 842" -- zstd registered at
        # priority 1 with no level applied, running at the built-in default for the
        # whole 12-day uptime. The declaration claimed a level the device never had.
        #
        # Dropping the parameter costs nothing, because the built-in default IS 3:
        # ZSTD_CLEVEL_DEFAULT is 3, and zram's backend substitutes it whenever no
        # level was supplied (backend_zstd.c -- `if (params->level ==
        # ZCOMP_PARAM_NO_LEVEL) params->level = zstd_default_clevel();`). So plain
        # "zstd" is bit-for-bit the same compression that was already running; the
        # only thing that changes is that the declaration is now honest.
        #
        # This is also the wall experiments/004 runs into. Its recommendation to
        # take idle-tier recompression from level 3 toward level 12 CANNOT be
        # expressed in this file while zram-generator routes secondary parameters to
        # `recompress`; writing "zstd(level=12)" here would be silently discarded
        # exactly as level=3 was. Acting on that recommendation needs an upstream
        # change first (secondary params to algorithm_params as "priority=N
        # level=M"), not a levels.nix edit.
        recompressionAlgorithm = "zstd"; # extrapolated, policy call -- [11]
        recompressionTimerEnableByDefault = true;   # extrapolated -- [11]
        priority = 100;                              # sourced -- [12]
      };
      swappiness = 10;              # directed -- [3], the operator's own real historical data point (a long-running NAS-class server ran 10)
      swappinessReliefEnableByDefault = true; # extrapolated -- [3], PSI-gated relief valve, reluctant tiers only
      watermarkScaleFactor = 150;   # extrapolated -- [5]
      watermarkBoostFactor = 0;     # sourced -- [5]
      minFreeKbytesOverride = null; # default -- [6]
      mglruMinTtlMs = 0;            # own-measured -- [7]
      oomd = {
        enable = true;              # extrapolated -- [8]
        pressureLimitPercent = 60;  # sourced -- [10]
        pressureDurationSec = 30;   # sourced -- [10]
      };
    };

    "4G" = {
      ramMiB = 4096;
      zram = {
        diskSizeExpr = "ram * 75 / 100";  # extrapolated -- [1], logical capacity
        compressionAlgorithm = "lz4";           # extrapolated, own-measured -- [9]
        recompressionAlgorithm = "zstd"; # extrapolated, policy call -- [11]; bare on purpose, see 2G
        recompressionTimerEnableByDefault = true;   # extrapolated -- [11]
        priority = 100;                              # sourced -- [12]
      };
      swappiness = 10;              # directed -- [3], the operator's own real historical data point (a long-running NAS-class server ran 10)
      swappinessReliefEnableByDefault = true; # extrapolated -- [3], PSI-gated relief valve, reluctant tiers only
      watermarkScaleFactor = 150;   # extrapolated -- [5]
      watermarkBoostFactor = 0;     # sourced -- [5]
      minFreeKbytesOverride = null; # default -- [6]
      mglruMinTtlMs = 0;            # own-measured -- [7]
      oomd = {
        enable = true;              # extrapolated -- [8]
        pressureLimitPercent = 60;  # sourced -- [10]
        pressureDurationSec = 30;   # sourced -- [10]
      };
    };

    "6G" = {
      ramMiB = 6144;
      zram = {
        diskSizeExpr = "ram * 75 / 100";  # extrapolated -- [1], logical capacity
        compressionAlgorithm = "lz4";           # extrapolated, own-measured -- [9]
        recompressionAlgorithm = "zstd"; # extrapolated, policy call -- [11]; bare on purpose, see 2G
        recompressionTimerEnableByDefault = true;   # extrapolated -- [11]
        priority = 100;                              # sourced -- [12]
      };
      swappiness = 10;              # directed -- [3], the operator's own real historical data point (a long-running NAS-class server ran 10)
      swappinessReliefEnableByDefault = true; # extrapolated -- [3], PSI-gated relief valve, reluctant tiers only
      watermarkScaleFactor = 150;   # extrapolated -- [5]
      watermarkBoostFactor = 0;     # sourced -- [5]
      minFreeKbytesOverride = null; # default -- [6]
      mglruMinTtlMs = 0;            # own-measured -- [7]
      oomd = {
        enable = true;              # extrapolated -- [8]
        pressureLimitPercent = 60;  # sourced -- [10]
        pressureDurationSec = 30;   # sourced -- [10]
      };
    };

    "8G" = {
      ramMiB = 8192;
      zram = {
        diskSizeExpr = "ram * 75 / 100";  # extrapolated -- [1], logical capacity
        compressionAlgorithm = "lz4";           # extrapolated, own-measured -- [9]
        recompressionAlgorithm = "zstd"; # extrapolated, policy call -- [11]; bare on purpose, see 2G
        recompressionTimerEnableByDefault = true;   # extrapolated -- [11]
        priority = 100;                              # sourced -- [12]
      };
      swappiness = 10;              # directed -- [3], the operator's own real historical data point (a long-running NAS-class server ran 10)
      swappinessReliefEnableByDefault = true; # extrapolated -- [3], PSI-gated relief valve, reluctant tiers only
      watermarkScaleFactor = 150;   # extrapolated -- [5]
      watermarkBoostFactor = 0;     # sourced -- [5]
      minFreeKbytesOverride = null; # default -- [6]
      mglruMinTtlMs = 0;            # own-measured -- [7]
      oomd = {
        enable = true;              # extrapolated -- [8]
        pressureLimitPercent = 60;  # sourced -- [10]
        pressureDurationSec = 30;   # sourced -- [10]
      };
    };

    "10G" = {
      ramMiB = 10240;
      zram = {
        diskSizeExpr = "ram * 75 / 100";  # extrapolated -- [1], logical capacity
        compressionAlgorithm = "lz4";           # extrapolated, own-measured -- [9]
        recompressionAlgorithm = "zstd"; # extrapolated, policy call -- [11]; bare on purpose, see 2G
        recompressionTimerEnableByDefault = true;   # extrapolated -- [11]
        priority = 100;                              # sourced -- [12]
      };
      swappiness = 10;              # directed -- [3], the operator's own real historical data point (a long-running NAS-class server ran 10)
      swappinessReliefEnableByDefault = true; # extrapolated -- [3], PSI-gated relief valve, reluctant tiers only
      watermarkScaleFactor = 125;
      # sourced -- the one flat value Pop!_OS actually validated.
      # rationale.md [5].
      watermarkBoostFactor = 0;     # sourced -- [5]
      minFreeKbytesOverride = null; # default -- [6]
      mglruMinTtlMs = 0;            # own-measured -- [7]
      oomd = {
        enable = true;              # extrapolated -- [8]
        pressureLimitPercent = 60;  # sourced -- [10]
        pressureDurationSec = 30;   # sourced -- [10]
      };
    };

    "12G" = {
      ramMiB = 12288;
      zram = {
        diskSizeExpr = "ram * 75 / 100";  # extrapolated -- [1], logical capacity
        compressionAlgorithm = "lz4";           # extrapolated, own-measured -- [9]
        recompressionAlgorithm = "zstd"; # extrapolated, policy call -- [11]; bare on purpose, see 2G
        recompressionTimerEnableByDefault = true;   # extrapolated -- [11]
        priority = 100;                              # sourced -- [12]
      };
      swappiness = 10;              # directed -- [3], the operator's own real historical data point (a long-running NAS-class server ran 10)
      swappinessReliefEnableByDefault = true; # extrapolated -- [3], PSI-gated relief valve, reluctant tiers only
      watermarkScaleFactor = 125;   # sourced -- [5]
      watermarkBoostFactor = 0;     # sourced -- [5]
      minFreeKbytesOverride = null; # default -- [6]
      mglruMinTtlMs = 0;            # own-measured -- [7]
      oomd = {
        enable = true;              # extrapolated -- [8]
        pressureLimitPercent = 60;  # sourced -- [10]
        pressureDurationSec = 30;   # sourced -- [10]
      };
    };

    "16G" = {
      ramMiB = 16384;
      zram = {
        diskSizeExpr = "ram * 75 / 100";  # extrapolated -- [1], logical capacity
        compressionAlgorithm = "lz4";           # extrapolated, own-measured -- [9]
        recompressionAlgorithm = "zstd"; # extrapolated, policy call -- [11]; bare on purpose, see 2G
        recompressionTimerEnableByDefault = true;   # extrapolated -- [11]
        priority = 100;                              # sourced -- [12]
      };
      swappiness = 10;              # directed -- [3], the operator's own real historical data point (a long-running NAS-class server ran 10)
      swappinessReliefEnableByDefault = true; # extrapolated -- [3], PSI-gated relief valve, reluctant tiers only
      watermarkScaleFactor = 125;   # sourced -- [5]
      watermarkBoostFactor = 0;     # sourced -- [5]
      minFreeKbytesOverride = null; # default -- [6]
      mglruMinTtlMs = 0;            # own-measured -- [7]
      oomd = {
        enable = true;              # extrapolated -- [8]
        pressureLimitPercent = 60;  # sourced -- [10]
        pressureDurationSec = 30;   # sourced -- [10]
      };
    };

    "24G" = {
      ramMiB = 24576;
      zram = {
        diskSizeExpr = "ram * 75 / 100";  # extrapolated -- [1], logical capacity
        compressionAlgorithm = "lz4";           # extrapolated, own-measured -- [9]
        recompressionAlgorithm = "zstd"; # extrapolated, policy call -- [11]; bare on purpose, see 2G
        recompressionTimerEnableByDefault = true;   # extrapolated -- [11]
        priority = 100;                              # sourced -- [12]
      };
      swappiness = 10;              # directed -- [3], the operator's own real historical data point (a long-running NAS-class server ran 10)
      swappinessReliefEnableByDefault = true; # extrapolated -- [3], PSI-gated relief valve, reluctant tiers only
      watermarkScaleFactor = 125;   # sourced -- [5]
      watermarkBoostFactor = 0;     # sourced -- [5]
      minFreeKbytesOverride = null; # default -- [6]
      mglruMinTtlMs = 0;            # own-measured -- [7]
      oomd = {
        enable = true;              # extrapolated -- [8]
        pressureLimitPercent = 60;  # sourced -- [10]
        pressureDurationSec = 30;   # sourced -- [10]
      };
    };

    "32G" = {
      ramMiB = 32768;
      zram = {
        diskSizeExpr = "ram * 75 / 100";  # extrapolated -- [1], logical capacity
        compressionAlgorithm = "lz4";           # extrapolated, own-measured -- [9]
        recompressionAlgorithm = "zstd"; # extrapolated, policy call -- [11]; bare on purpose, see 2G
        recompressionTimerEnableByDefault = true;   # extrapolated -- [11]
        priority = 100;                              # sourced -- [12]
      };
      swappiness = 10;              # directed -- [3], the operator's own real historical data point (a long-running NAS-class server ran 10)
      swappinessReliefEnableByDefault = true; # extrapolated -- [3], PSI-gated relief valve, reluctant tiers only
      watermarkScaleFactor = 125;   # sourced -- [5]
      watermarkBoostFactor = 0;     # sourced -- [5]
      minFreeKbytesOverride = null; # default -- [6]
      mglruMinTtlMs = 0;            # own-measured -- [7]
      oomd = {
        enable = true;              # extrapolated -- [8]
        pressureLimitPercent = 60;  # sourced -- [10]
        pressureDurationSec = 30;   # sourced -- [10]
      };
    };

    "64G" = {
      ramMiB = 65536;
      zram = {
        diskSizeExpr = "ram * 75 / 100";
        # extrapolated -- [1], logical capacity; 48 GiB at this tier.
        compressionAlgorithm = "lz4";           # extrapolated, own-measured -- [9]
        recompressionAlgorithm = "zstd";        # bare on purpose, see 2G
        recompressionTimerEnableByDefault = true;
        # extrapolated, low marginal value at this tier -- left on by
        # default for consistency; documented alternative is
        # `nixram.mode = "none"` for single-big-workload boxes.
        # rationale.md [13].
        priority = 100;                              # sourced -- [12]
      };
      swappiness = 10;              # directed -- [3], the operator's own real historical data point (a long-running NAS-class server ran 10)
      swappinessReliefEnableByDefault = true; # extrapolated -- [3], PSI-gated relief valve, reluctant tiers only
      watermarkScaleFactor = 100;   # extrapolated -- [5]
      watermarkBoostFactor = 0;     # sourced -- [5]
      minFreeKbytesOverride = null; # default -- [6]
      mglruMinTtlMs = 0;            # own-measured -- [7]
      oomd = {
        enable = true;              # extrapolated -- [8]
        pressureLimitPercent = 60;  # sourced -- [10]
        pressureDurationSec = 30;   # sourced -- [10]
      };
    };

    "128G" = {
      ramMiB = 131072;
      zram = {
        diskSizeExpr = "ram * 75 / 100";  # extrapolated -- [1], 96 GiB here, the operator's own directed correction (was 64 GiB)
        compressionAlgorithm = "lz4";           # directed, the operator: "we should use lz4 and then zstd" -- [9]
        # This is the tier corbet-server actually runs, and the one the EINVAL
        # documented at 2G was measured on. Bare on purpose -- see 2G.
        recompressionAlgorithm = "zstd";
        recompressionTimerEnableByDefault = true;  # extrapolated, low value -- [13]
        priority = 100;                              # sourced -- [12]
      };
      swappiness = 10;              # directed -- [3], the operator's own real historical data point (a long-running NAS-class server ran 10)
      swappinessReliefEnableByDefault = true; # extrapolated -- [3], PSI-gated relief valve, reluctant tiers only
      watermarkScaleFactor = 100;   # extrapolated -- [5]
      watermarkBoostFactor = 0;     # sourced -- [5]
      minFreeKbytesOverride = null; # default -- [6]
      mglruMinTtlMs = 0;            # own-measured -- [7]
      oomd = {
        enable = true;              # extrapolated -- [8]
        pressureLimitPercent = 60;  # sourced -- [10]
        pressureDurationSec = 30;   # sourced -- [10]
      };
    };
  };
}
