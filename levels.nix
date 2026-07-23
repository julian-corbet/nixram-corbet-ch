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
#   directed     a literal value Julian himself stated (quoted or closely
#                paraphrased in rationale.md), applied as-is. Not Claude's
#                inference -- the number itself is his.
#   extrapolated Claude's own curve, cap, boundary placement, or causal
#                story standing on or between sourced/directed anchors.
#                Reasoned, not measured, and NOT something Julian said --
#                see rationale.md for exactly where the directed data
#                point(s) end and the extrapolation begins.
#   default      the kernel's own computed value, deliberately left
#                untouched. Not a nixram opinion at all.
#
# `ram` inside the *Expr strings below is zram-generator's own variable
# for total detected RAM in MiB (systemd/zram-generator, zram-size /
# zram-resident-limit expression syntax) -- evaluated by the generator
# against the machine's real /proc/meminfo at boot, not by Nix at eval
# time. This is why the same expr string appears on several levels: the
# FORMULA is what's tiered, not a number baked in per level.
#
# THE CENTRAL CONFLICT, STATED PLAINLY (see docs/rationale.md [1] and
# docs/faq.md for the long version): zram-generator's own upstream
# documentation recommends zram-size fractions "in the range 0.1-0.5" of
# RAM. Every tier here exceeds that range: `diskSizeExpr` is the tier's own
# `residentLimitExpr` budget, multiplied by `pi()`, rounded to the nearest
# "RAM-buyable" size -- Julian's own formula: "take the physical ram,
# multiply by pi and take the nearest base 2ish value." Concretely, that
# means the nearest 3-smooth number (OEIS A003586, only 2 and 3 as prime
# factors -- the sizes RAM/VPS tiers actually ship in: 256M, 384M, 512M,
# 768M, 1G, 1.5G, 2G, 3G...). Because the resident budget is always a FIXED
# percentage of `ram` within a tier group (30%, 25%, or 20%), and the
# 3-smooth grid is geometrically (multiplicatively) spaced, the nearest
# grid point works out to the SAME simple fraction for every tier in a
# group -- 30% x pi = 0.9425 of RAM, nearest 3-smooth fraction 1.0 (so the
# formula collapses to plain `ram`); 25% x pi = 0.7854 and 20% x pi =
# 0.6283 both round to 0.75. So `diskSizeExpr` is just `ram` (256M-1G) or
# `ram * 75 / 100` (2G-128G) -- simple flat fractions, not the round()/
# log()/pi() machinery that would be needed to compute this live for an
# arbitrary, non-fixed ratio. This lands well above upstream's 0.5-of-RAM
# ceiling at every tier (256 MiB at 256M, up to 96 GiB at 128G) --
# deliberate, not an oversight, and it produces round, human-legible
# numbers that also land inside or right at the edge of Julian's own
# hand-calculated examples (e.g. 1G: 1 GiB ceiling vs. his own "almost a
# GB"; ~128G: 96 GiB, exactly his own correction).
# Under nixram's resident-limit model, disksize is only the VIRTUAL
# ceiling; the REAL physical budget is `zram.residentLimitExpr` (zram-
# resident-limit), which stays inside a conservative fraction of RAM at
# every tier. Once a resident limit is doing the actual safety job, a
# generous disksize costs nothing but a bit of virtual address space and
# lets compression stretch the same physical spend further before the
# medium hits a hard wall. This is nixram's central thesis; the
# counterargument (upstream's own 0.1-0.5 guidance exists for a reason: on
# a host running `sizing = "virtual"` alone, disksize IS the only ceiling,
# and a generous one really can let compression overhead balloon) is real
# and is why `zram.sizing` defaults to `"both"`, never `"virtual"` alone.

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
        # extrapolated -- ceiling = resident-limit budget (30%) x pi(),
        # rounded to the nearest "RAM-buyable" size (Julian's own formula:
        # "take the physical ram, multiply by pi and take the nearest base
        # 2ish value" -- a 3-smooth number, OEIS A003586: only 2 and 3 as
        # prime factors, the sizes RAM/VPS tiers actually ship in: 256M,
        # 384M, 512M, 768M, 1G, 1.5G, 2G...). 30% x pi = 0.9425 of RAM,
        # which rounds to the nearest 3-smooth fraction of exactly 1.0 --
        # so the formula collapses to plain `ram`, not a coincidence, a
        # provable consequence of the ratio being fixed within this tier
        # group (see docs/rationale.md [1] for the derivation and the
        # check against all four of Julian's worked examples).
        residentLimitExpr = "ram * 30 / 100";
        # directed -- 30% is Julian's own stated figure at this tier
        # ("Taking off 75MB for ZRAM" at 256M is ~30%; matched at 512M's
        # "we take 30% for virtual RAM"), NOT the memory-safety headroom
        # argument the old ram/2 (50%) value was reasoned from. Same
        # 20-30% band as zswap.maxPoolPercent -- the two modes share this
        # leg; only what sits behind it differs. The zram-resident-limit
        # PRIMITIVE is sourced (systemd/zram-generator upstream); this
        # fraction is Julian's own choice. See docs/rationale.md [2].
        compressionAlgorithm = "zstd(level=3)";
        # directed -- Julian's explicit instruction: "make sure that
        # everything up to a GB goes to zstd primary and done." An
        # earlier version of this file wrongly gave 256M/512M a
        # lz4+recompress architecture instead, over-applying his separate,
        # much narrower "weakest of weak" exception ("even then I am not
        # sure") to the whole dire band -- that was a real implementation
        # mistake, not a design choice, caught and reverted. 256M-1G share
        # one shape: zstd(level=3) primary, no recompression at all.
        # rationale.md [9].
        recompressionAlgorithm = null;
        recompressionTimerEnableByDefault = false;
        priority = 100;
        # sourced -- zram-generator's own upstream default ships a
        # higher-than-normal swap priority so zram always wins over disk
        # swap when both exist. rationale.md [12] / faq.md.
      };

      swappiness = 120;
      # directed -- Julian revised this down from 130 (itself already
      # adversarially revised down from an initial 180). The EAGER value:
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
      mglruMinTtlMs = 1000;         # sourced, flagged -- rationale.md [7]

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
        diskSizeExpr = "ram";  # extrapolated -- [1], 30% budget x pi ~= 0.94, nearest 3-smooth fraction = 1.0 (ram itself)
        residentLimitExpr = "ram * 30 / 100";  # directed -- [2], Julian's own 30% figure ("we take 30% for virtual RAM")
        compressionAlgorithm = "zstd(level=3)"; # directed, Julian: "everything up to a GB goes to zstd primary and done" -- [9]
        recompressionAlgorithm = null;
        recompressionTimerEnableByDefault = false;
        # 256M-1G all share this shape now -- see the 256M block above for
        # the correction history. rationale.md [9].
        priority = 100;                              # sourced -- [12]
      };
      swappiness = 120;             # directed -- [3] (dire/eager, same as 256M)
      swappinessReliefEnableByDefault = false; # extrapolated -- [3], no relief valve needed, dire tiers already eager
      watermarkScaleFactor = 200;   # extrapolated -- [5]
      watermarkBoostFactor = 0;     # sourced -- [5]
      minFreeKbytesOverride = null; # default -- [6]
      mglruMinTtlMs = 1000;         # sourced, flagged -- [7]
      oomd = {
        enable = true;              # extrapolated -- [8] (on above 256M)
        pressureLimitPercent = 60;  # sourced -- [10]
        pressureDurationSec = 30;   # sourced -- [10]
      };
    };

    "1G" = {
      ramMiB = 1024;
      zram = {
        diskSizeExpr = "ram";  # extrapolated -- [1], 30% budget x pi ~= 0.94, nearest 3-smooth fraction = 1.0 (ram itself)
        residentLimitExpr = "ram * 30 / 100";  # directed -- [2], Julian's own 30% figure (e2-micro walkthrough)
        compressionAlgorithm = "zstd(level=3)"; # directed -- [9], Julian: "we go for zstd directly"
        recompressionAlgorithm = null;
        recompressionTimerEnableByDefault = false;
        # zstd-primary/no-recompression -- 256M-1G all share this shape
        # now (see 256M's block for the correction history: an earlier
        # version wrongly split 256M/512M off onto a lz4+recompress
        # architecture). rationale.md [9], [11].
        priority = 100;                              # sourced -- [12]
      };
      swappiness = 120;
      # directed -- EAGER, unified with 256M/512M (previously
      # 10/reluctant, revised after Julian's own compute-boundedness
      # explanation: "with 1GB RAM, you need to get whatever you can"
      # describes urgency, not comfort -- the same "light usage,
      # RAM-desperate" story that justifies 256M/512M's eager value applies
      # here too, not the "enough true RAM to wait" story the reluctant
      # value was reasoned from. Reluctant (10) now starts at 2G, not 1G.
      # 120 is Julian's own revision down from 130. rationale.md [3].
      swappinessReliefEnableByDefault = false;
      # extrapolated -- [3], no relief valve needed, dire tiers already eager
      watermarkScaleFactor = 200;   # extrapolated -- [5]
      watermarkBoostFactor = 0;     # sourced -- [5]
      minFreeKbytesOverride = null; # default -- [6]
      mglruMinTtlMs = 1000;         # sourced, flagged -- [7]
      oomd = {
        enable = true;              # extrapolated -- [8]
        pressureLimitPercent = 60;  # sourced -- [10]
        pressureDurationSec = 30;   # sourced -- [10]
      };
    };

    "2G" = {
      ramMiB = 2048;
      zram = {
        diskSizeExpr = "ram * 75 / 100";  # extrapolated -- [1], 25% budget x pi, nearest 3-smooth fraction = 0.75
        # extrapolated, own-measured -- [1]. 25% resident budget x pi(),
        # rounded to the nearest 3-smooth "RAM-buyable" fraction (Julian's
        # own formula -- collapses to a flat 0.75, see the file header). No
        # longer Fedora's plain "ram" default -- that formula was
        # disconnected from the actual resident budget. rationale.md [1].
        residentLimitExpr = "ram * 25 / 100";  # extrapolated -- [2]
        compressionAlgorithm = "lz4";
        # extrapolated, own-measured -- [9]. Same cheap-primary +
        # recompression shape as 256M/512M/1G used to have (that
        # shape now belongs to 2G+ only, for a workload compute-
        # boundedness reason rather than the small tiers' necessity --
        # see rationale.md [9]).
        recompressionAlgorithm = "zstd(level=3)"; # extrapolated, policy call -- [11]
        recompressionTimerEnableByDefault = true;   # extrapolated -- [11]
        priority = 100;                              # sourced -- [12]
      };
      swappiness = 10;              # directed -- [3], Julian's own real historical data point (the old Unraid server ran 10)
      swappinessReliefEnableByDefault = true; # extrapolated -- [3], PSI-gated relief valve, reluctant tiers only
      watermarkScaleFactor = 150;   # extrapolated -- [5]
      watermarkBoostFactor = 0;     # sourced -- [5]
      minFreeKbytesOverride = null; # default -- [6]
      mglruMinTtlMs = 1000;         # sourced, flagged -- [7]
      oomd = {
        enable = true;              # extrapolated -- [8]
        pressureLimitPercent = 60;  # sourced -- [10]
        pressureDurationSec = 30;   # sourced -- [10]
      };
    };

    "4G" = {
      ramMiB = 4096;
      zram = {
        diskSizeExpr = "ram * 75 / 100";  # extrapolated -- [1], 25% budget x pi, nearest 3-smooth fraction = 0.75
        residentLimitExpr = "ram * 25 / 100";  # extrapolated -- [2]
        compressionAlgorithm = "lz4";           # extrapolated, own-measured -- [9]
        recompressionAlgorithm = "zstd(level=3)"; # extrapolated, policy call -- [11]
        recompressionTimerEnableByDefault = true;   # extrapolated -- [11]
        priority = 100;                              # sourced -- [12]
      };
      swappiness = 10;              # directed -- [3], Julian's own real historical data point (the old Unraid server ran 10)
      swappinessReliefEnableByDefault = true; # extrapolated -- [3], PSI-gated relief valve, reluctant tiers only
      watermarkScaleFactor = 150;   # extrapolated -- [5]
      watermarkBoostFactor = 0;     # sourced -- [5]
      minFreeKbytesOverride = null; # default -- [6]
      mglruMinTtlMs = 1000;         # sourced, flagged -- [7]
      oomd = {
        enable = true;              # extrapolated -- [8]
        pressureLimitPercent = 60;  # sourced -- [10]
        pressureDurationSec = 30;   # sourced -- [10]
      };
    };

    "6G" = {
      ramMiB = 6144;
      zram = {
        diskSizeExpr = "ram * 75 / 100";  # extrapolated -- [1], 25% budget x pi, nearest 3-smooth fraction = 0.75
        residentLimitExpr = "ram * 25 / 100";  # extrapolated -- [2]
        compressionAlgorithm = "lz4";           # extrapolated, own-measured -- [9]
        recompressionAlgorithm = "zstd(level=3)"; # extrapolated, policy call -- [11]
        recompressionTimerEnableByDefault = true;   # extrapolated -- [11]
        priority = 100;                              # sourced -- [12]
      };
      swappiness = 10;              # directed -- [3], Julian's own real historical data point (the old Unraid server ran 10)
      swappinessReliefEnableByDefault = true; # extrapolated -- [3], PSI-gated relief valve, reluctant tiers only
      watermarkScaleFactor = 150;   # extrapolated -- [5]
      watermarkBoostFactor = 0;     # sourced -- [5]
      minFreeKbytesOverride = null; # default -- [6]
      mglruMinTtlMs = 1000;         # sourced, flagged -- [7]
      oomd = {
        enable = true;              # extrapolated -- [8]
        pressureLimitPercent = 60;  # sourced -- [10]
        pressureDurationSec = 30;   # sourced -- [10]
      };
    };

    "8G" = {
      ramMiB = 8192;
      zram = {
        diskSizeExpr = "ram * 75 / 100";  # extrapolated -- [1], 25% budget x pi, nearest 3-smooth fraction = 0.75
        residentLimitExpr = "ram * 25 / 100";  # extrapolated -- [2]
        compressionAlgorithm = "lz4";           # extrapolated, own-measured -- [9]
        recompressionAlgorithm = "zstd(level=3)"; # extrapolated, policy call -- [11]
        recompressionTimerEnableByDefault = true;   # extrapolated -- [11]
        priority = 100;                              # sourced -- [12]
      };
      swappiness = 10;              # directed -- [3], Julian's own real historical data point (the old Unraid server ran 10)
      swappinessReliefEnableByDefault = true; # extrapolated -- [3], PSI-gated relief valve, reluctant tiers only
      watermarkScaleFactor = 150;   # extrapolated -- [5]
      watermarkBoostFactor = 0;     # sourced -- [5]
      minFreeKbytesOverride = null; # default -- [6]
      mglruMinTtlMs = 1000;         # sourced, flagged -- [7]
      oomd = {
        enable = true;              # extrapolated -- [8]
        pressureLimitPercent = 60;  # sourced -- [10]
        pressureDurationSec = 30;   # sourced -- [10]
      };
    };

    "10G" = {
      ramMiB = 10240;
      zram = {
        diskSizeExpr = "ram * 75 / 100";  # extrapolated -- [1], 25% budget x pi, nearest 3-smooth fraction = 0.75
        residentLimitExpr = "ram * 25 / 100";  # extrapolated -- [2]
        compressionAlgorithm = "lz4";           # extrapolated, own-measured -- [9]
        recompressionAlgorithm = "zstd(level=3)"; # extrapolated, policy call -- [11]
        recompressionTimerEnableByDefault = true;   # extrapolated -- [11]
        priority = 100;                              # sourced -- [12]
      };
      swappiness = 10;              # directed -- [3], Julian's own real historical data point (the old Unraid server ran 10)
      swappinessReliefEnableByDefault = true; # extrapolated -- [3], PSI-gated relief valve, reluctant tiers only
      watermarkScaleFactor = 125;
      # sourced -- the one flat value Pop!_OS actually validated.
      # rationale.md [5].
      watermarkBoostFactor = 0;     # sourced -- [5]
      minFreeKbytesOverride = null; # default -- [6]
      mglruMinTtlMs = 1000;         # sourced, flagged -- [7]
      oomd = {
        enable = true;              # extrapolated -- [8]
        pressureLimitPercent = 60;  # sourced -- [10]
        pressureDurationSec = 30;   # sourced -- [10]
      };
    };

    "12G" = {
      ramMiB = 12288;
      zram = {
        diskSizeExpr = "ram * 75 / 100";  # extrapolated -- [1], 25% budget x pi, nearest 3-smooth fraction = 0.75
        residentLimitExpr = "ram * 25 / 100";  # extrapolated -- [2]
        compressionAlgorithm = "lz4";           # extrapolated, own-measured -- [9]
        recompressionAlgorithm = "zstd(level=3)"; # extrapolated, policy call -- [11]
        recompressionTimerEnableByDefault = true;   # extrapolated -- [11]
        priority = 100;                              # sourced -- [12]
      };
      swappiness = 10;              # directed -- [3], Julian's own real historical data point (the old Unraid server ran 10)
      swappinessReliefEnableByDefault = true; # extrapolated -- [3], PSI-gated relief valve, reluctant tiers only
      watermarkScaleFactor = 125;   # sourced -- [5]
      watermarkBoostFactor = 0;     # sourced -- [5]
      minFreeKbytesOverride = null; # default -- [6]
      mglruMinTtlMs = 1000;         # sourced, flagged -- [7]
      oomd = {
        enable = true;              # extrapolated -- [8]
        pressureLimitPercent = 60;  # sourced -- [10]
        pressureDurationSec = 30;   # sourced -- [10]
      };
    };

    "16G" = {
      ramMiB = 16384;
      zram = {
        diskSizeExpr = "ram * 75 / 100";  # extrapolated -- [1], 25% budget x pi, nearest 3-smooth fraction = 0.75
        residentLimitExpr = "ram * 25 / 100";  # extrapolated -- [2]
        compressionAlgorithm = "lz4";           # extrapolated, own-measured -- [9]
        recompressionAlgorithm = "zstd(level=3)"; # extrapolated, policy call -- [11]
        recompressionTimerEnableByDefault = true;   # extrapolated -- [11]
        priority = 100;                              # sourced -- [12]
      };
      swappiness = 10;              # directed -- [3], Julian's own real historical data point (the old Unraid server ran 10)
      swappinessReliefEnableByDefault = true; # extrapolated -- [3], PSI-gated relief valve, reluctant tiers only
      watermarkScaleFactor = 125;   # sourced -- [5]
      watermarkBoostFactor = 0;     # sourced -- [5]
      minFreeKbytesOverride = null; # default -- [6]
      mglruMinTtlMs = 1000;         # sourced, flagged -- [7]
      oomd = {
        enable = true;              # extrapolated -- [8]
        pressureLimitPercent = 60;  # sourced -- [10]
        pressureDurationSec = 30;   # sourced -- [10]
      };
    };

    "24G" = {
      ramMiB = 24576;
      zram = {
        diskSizeExpr = "ram * 75 / 100";  # extrapolated -- [1], 20% budget x pi, nearest 3-smooth fraction = 0.75
        residentLimitExpr = "ram * 20 / 100";
        # extrapolated -- [2]. The 20% VALUE is Julian's stated figure
        # (given for ~128G); WHERE the 25%->20% step begins (24G, not
        # 32G or 64G) is Claude's own placement, not something Julian
        # specified -- flagged as unconfirmed, not "his correction."
        compressionAlgorithm = "lz4";           # extrapolated, own-measured -- [9]
        recompressionAlgorithm = "zstd(level=3)"; # extrapolated, policy call -- [11]
        recompressionTimerEnableByDefault = true;   # extrapolated -- [11]
        priority = 100;                              # sourced -- [12]
      };
      swappiness = 10;              # directed -- [3], Julian's own real historical data point (the old Unraid server ran 10)
      swappinessReliefEnableByDefault = true; # extrapolated -- [3], PSI-gated relief valve, reluctant tiers only
      watermarkScaleFactor = 125;   # sourced -- [5]
      watermarkBoostFactor = 0;     # sourced -- [5]
      minFreeKbytesOverride = null; # default -- [6]
      mglruMinTtlMs = 1000;         # sourced, flagged -- [7]
      oomd = {
        enable = true;              # extrapolated -- [8]
        pressureLimitPercent = 60;  # sourced -- [10]
        pressureDurationSec = 30;   # sourced -- [10]
      };
    };

    "32G" = {
      ramMiB = 32768;
      zram = {
        diskSizeExpr = "ram * 75 / 100";  # extrapolated -- [1], 20% budget x pi, nearest 3-smooth fraction = 0.75
        residentLimitExpr = "ram * 20 / 100";  # extrapolated -- [2], 20% is Julian's figure; the 24G start is Claude's placement
        compressionAlgorithm = "lz4";           # extrapolated, own-measured -- [9]
        recompressionAlgorithm = "zstd(level=3)"; # extrapolated, policy call -- [11]
        recompressionTimerEnableByDefault = true;   # extrapolated -- [11]
        priority = 100;                              # sourced -- [12]
      };
      swappiness = 10;              # directed -- [3], Julian's own real historical data point (the old Unraid server ran 10)
      swappinessReliefEnableByDefault = true; # extrapolated -- [3], PSI-gated relief valve, reluctant tiers only
      watermarkScaleFactor = 125;   # sourced -- [5]
      watermarkBoostFactor = 0;     # sourced -- [5]
      minFreeKbytesOverride = null; # default -- [6]
      mglruMinTtlMs = 1000;         # sourced, flagged -- [7]
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
        # extrapolated, own-measured -- [1]. 20% resident budget x pi(),
        # rounded to the nearest 3-smooth "RAM-buyable" fraction (0.75 --
        # same fraction as 24G/32G/128G, since the ratio is fixed within
        # this tier group). Replaces an earlier `min(ram/2, 16384)`
        # formula: Pop!_OS's borrowed 16GiB cap made no sense once nixram
        # switched to a resident-limit-first safety model. Evaluates to
        # 48 GiB at this tier. See docs/rationale.md [1].
        residentLimitExpr = "ram * 20 / 100";
        # extrapolated -- closes what was an open question (previously
        # unset/unlimited here). 20% is Julian's stated figure for this
        # tier. The "CPU-tax budget, not memory-safety backstop" framing
        # is Claude's own explanation for why it applies here too --
        # 20% here is Julian's own explicit figure ("taking a 20% slice
        # of system RAM here is about 25GB"), same as 24G/32G, not a
        # further taper. See docs/rationale.md [2].
        compressionAlgorithm = "lz4";           # extrapolated, own-measured -- [9]
        recompressionAlgorithm = "zstd(level=3)";
        recompressionTimerEnableByDefault = true;
        # extrapolated, low marginal value at this tier -- left on by
        # default for consistency; documented alternative is
        # `nixram.mode = "none"` for single-big-workload boxes.
        # rationale.md [13].
        priority = 100;                              # sourced -- [12]
      };
      swappiness = 10;              # directed -- [3], Julian's own real historical data point (the old Unraid server ran 10)
      swappinessReliefEnableByDefault = true; # extrapolated -- [3], PSI-gated relief valve, reluctant tiers only
      watermarkScaleFactor = 100;   # extrapolated -- [5]
      watermarkBoostFactor = 0;     # sourced -- [5]
      minFreeKbytesOverride = null; # default -- [6]
      mglruMinTtlMs = 1000;         # sourced, flagged -- [7]
      oomd = {
        enable = true;              # extrapolated -- [8]
        pressureLimitPercent = 60;  # sourced -- [10]
        pressureDurationSec = 30;   # sourced -- [10]
      };
    };

    "128G" = {
      ramMiB = 131072;
      zram = {
        diskSizeExpr = "ram * 75 / 100";  # extrapolated -- [1], 20% budget x pi rounds to the 0.75 3-smooth fraction -- 96 GiB here, Julian's own directed correction (was 64 GiB under plain power-of-two rounding)
        residentLimitExpr = "ram * 20 / 100";  # directed -- [2], Julian's own figure ("a 20% slice... about 25GB")
        compressionAlgorithm = "lz4";           # directed, Julian: "we should use lz4 and then zstd" -- [9]
        recompressionAlgorithm = "zstd(level=3)";
        recompressionTimerEnableByDefault = true;  # extrapolated, low value -- [13]
        priority = 100;                              # sourced -- [12]
      };
      swappiness = 10;              # directed -- [3], Julian's own real historical data point (the old Unraid server ran 10)
      swappinessReliefEnableByDefault = true; # extrapolated -- [3], PSI-gated relief valve, reluctant tiers only
      watermarkScaleFactor = 100;   # extrapolated -- [5]
      watermarkBoostFactor = 0;     # sourced -- [5]
      minFreeKbytesOverride = null; # default -- [6]
      mglruMinTtlMs = 1000;         # sourced, flagged -- [7]
      oomd = {
        enable = true;              # extrapolated -- [8]
        pressureLimitPercent = 60;  # sourced -- [10]
        pressureDurationSec = 30;   # sourced -- [10]
      };
    };
  };
}
