# levels.nix
#
# Pure data: the fourteen RAM-size anchor levels nixram is tuned for, and
# the exact values it applies at each one. This file contains no branching
# logic beyond the attribute set itself -- modules/*.nix read these values,
# they never decide anything from RAM size themselves.
#
# HONESTY TAXONOMY -- every tunable below carries one of three tags. The
# full citation for every "sourced" tag and the reasoning behind every
# "extrapolated" tag lives in docs/rationale.md (numbered notes); the
# reader-facing table with the same tags is docs/levels.md.
#
#   sourced      a real upstream distro/kernel-doc default or bound,
#                applied as-is, or a formula whose ENDPOINTS are sourced
#                (the endpoints, not necessarily the taper between them).
#   extrapolated nixram's own curve, cap, or judgement call standing on
#                or between sourced anchors. Reasoned, not measured.
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
# RAM. Every disksize expression below exceeds that range -- up to 2x RAM
# on the smallest tiers. This is deliberate, not an oversight. Under
# nixram's resident-limit model, disksize is only the VIRTUAL ceiling;
# the REAL physical budget is `zram.residentLimitExpr` (zram-resident-
# limit), which stays inside a conservative fraction of RAM at every
# tier. Once a resident limit is doing the actual safety job, a generous
# disksize costs nothing but a bit of virtual address space and lets
# compression stretch the same physical spend further before the medium
# hits a hard wall. This is nixram's central thesis; the counterargument
# (upstream's own 0.1-0.5 guidance exists for a reason: on a host running
# `sizing = "virtual"` alone, disksize IS the only ceiling, and a
# generous one really can let compression overhead balloon) is real and
# is why `zram.sizing` defaults to `"both"`, never `"virtual"` alone.

{
  levelNames = [
    "256M" "512M" "1G" "2G" "4G" "6G" "8G"
    "10G" "12G" "16G" "24G" "32G" "64G" "128G"
  ];

  levels = {
    "256M" = {
      ramMiB = 256;

      zram = {
        diskSizeExpr = "ram * 2";
        # extrapolated -- exceeds even Fedora's 100%-of-RAM default; see
        # the central-conflict note above and docs/rationale.md [1].
        residentLimitExpr = "ram / 2";
        # extrapolated -- nixram's own safety-budget model. The
        # zram-resident-limit PRIMITIVE is sourced (systemd/zram-
        # generator upstream); this fraction is nixram's own choice.
        # See docs/rationale.md [2].
        compressionAlgorithm = "zstd(level=1)";
        # extrapolated -- fastest zstd mode, a reasoned CPU-cost
        # tradeoff for the most CPU-constrained tier. rationale.md [9].
        recompressionAlgorithm = null;
        recompressionTimerEnableByDefault = false;
        # extrapolated, deliberate -- the whole compressed pool tops out
        # around ~512M here; a denser idle pass doesn't pay for itself.
        # rationale.md [9].
        priority = 100;
        # sourced -- Fedora's own zram default ships a higher-than-
        # normal swap priority so zram always wins over disk swap when
        # both exist. rationale.md [12] / faq.md.
      };

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
        diskSizeExpr = "ram * 2";              # extrapolated -- [1]
        residentLimitExpr = "ram / 2";         # extrapolated -- [2]
        compressionAlgorithm = "zstd";         # sourced -- [9]
        recompressionAlgorithm = "zstd(level=12)";
        # extrapolated -- a denser idle-only pass; no source recommends
        # a specific level, this is nixram's own reasoned choice,
        # tunable via zram.recompressionAlgorithmOverride. rationale.md [11].
        recompressionTimerEnableByDefault = true;   # extrapolated -- [11]
        priority = 100;                              # sourced -- [12]
      };
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
        diskSizeExpr = "ram * 2";              # extrapolated -- [1]
        residentLimitExpr = "ram / 2";         # extrapolated -- [2]
        compressionAlgorithm = "zstd";         # sourced -- [9]
        recompressionAlgorithm = "zstd(level=12)"; # extrapolated -- [11]
        recompressionTimerEnableByDefault = true;   # extrapolated -- [11]
        priority = 100;                              # sourced -- [12]
      };
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
        diskSizeExpr = "ram";                  # sourced -- Fedora F34+
        # "Scale ZRAM to full memory size", 100% of RAM. rationale.md [1].
        residentLimitExpr = "ram * 35 / 100";  # extrapolated -- [2]
        compressionAlgorithm = "zstd";         # sourced -- [9]
        recompressionAlgorithm = "zstd(level=12)"; # extrapolated -- [11]
        recompressionTimerEnableByDefault = true;   # extrapolated -- [11]
        priority = 100;                              # sourced -- [12]
      };
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
        diskSizeExpr = "ram";                  # sourced -- [1]
        residentLimitExpr = "ram * 35 / 100";  # extrapolated -- [2]
        compressionAlgorithm = "zstd";         # sourced -- [9]
        recompressionAlgorithm = "zstd(level=12)"; # extrapolated -- [11]
        recompressionTimerEnableByDefault = true;   # extrapolated -- [11]
        priority = 100;                              # sourced -- [12]
      };
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
        diskSizeExpr = "ram";                  # sourced -- [1]
        residentLimitExpr = "ram * 35 / 100";  # extrapolated -- [2]
        compressionAlgorithm = "zstd";         # sourced -- [9]
        recompressionAlgorithm = "zstd(level=12)"; # extrapolated -- [11]
        recompressionTimerEnableByDefault = true;   # extrapolated -- [11]
        priority = 100;                              # sourced -- [12]
      };
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
        diskSizeExpr = "ram";                  # sourced -- [1]
        residentLimitExpr = "ram * 35 / 100";  # extrapolated -- [2]
        compressionAlgorithm = "zstd";         # sourced -- [9]
        recompressionAlgorithm = "zstd(level=12)"; # extrapolated -- [11]
        recompressionTimerEnableByDefault = true;   # extrapolated -- [11]
        priority = 100;                              # sourced -- [12]
      };
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
        diskSizeExpr = "min(ram / 2, 16384)";
        # extrapolated formula -- the /2 taper is nixram's own; the
        # 16384 MiB (16GiB) cap is sourced (Pop!_OS's validated ceiling
        # across 4-64GiB machines). rationale.md [1].
        residentLimitExpr = "ram * 35 / 100";  # extrapolated -- [2]
        compressionAlgorithm = "zstd";         # sourced -- [9]
        recompressionAlgorithm = "zstd(level=12)"; # extrapolated -- [11]
        recompressionTimerEnableByDefault = true;   # extrapolated -- [11]
        priority = 100;                              # sourced -- [12]
      };
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
        diskSizeExpr = "min(ram / 2, 16384)";  # extrapolated / sourced cap -- [1]
        residentLimitExpr = "ram * 35 / 100";  # extrapolated -- [2]
        compressionAlgorithm = "zstd";         # sourced -- [9]
        recompressionAlgorithm = "zstd(level=12)"; # extrapolated -- [11]
        recompressionTimerEnableByDefault = true;   # extrapolated -- [11]
        priority = 100;                              # sourced -- [12]
      };
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
        diskSizeExpr = "min(ram / 2, 16384)";  # extrapolated / sourced cap -- [1]
        residentLimitExpr = "ram * 35 / 100";  # extrapolated -- [2]
        compressionAlgorithm = "zstd";         # sourced -- [9]
        recompressionAlgorithm = "zstd(level=12)"; # extrapolated -- [11]
        recompressionTimerEnableByDefault = true;   # extrapolated -- [11]
        priority = 100;                              # sourced -- [12]
      };
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
        diskSizeExpr = "min(ram / 2, 16384)";  # extrapolated / sourced cap -- [1]
        residentLimitExpr = "ram * 35 / 100";  # extrapolated -- [2]
        compressionAlgorithm = "zstd";         # sourced -- [9]
        recompressionAlgorithm = "zstd(level=12)"; # extrapolated -- [11]
        recompressionTimerEnableByDefault = true;   # extrapolated -- [11]
        priority = 100;                              # sourced -- [12]
      };
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
        diskSizeExpr = "min(ram / 2, 16384)";
        # extrapolated formula, sourced cap -- at exactly 32GiB the /2
        # taper and the 16GiB cap meet (32/2=16). rationale.md [1].
        residentLimitExpr = "ram * 35 / 100";  # extrapolated -- [2]
        compressionAlgorithm = "zstd";         # sourced -- [9]
        recompressionAlgorithm = "zstd(level=12)"; # extrapolated -- [11]
        recompressionTimerEnableByDefault = true;   # extrapolated -- [11]
        priority = 100;                              # sourced -- [12]
      };
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
        diskSizeExpr = "min(ram / 2, 16384)";
        # extrapolated formula, sourced cap -- the cap is now the only
        # thing that matters (64/2=32, capped to 16). rationale.md [1].
        residentLimitExpr = null;
        # extrapolated, OPEN QUESTION -- deliberately unset/unlimited:
        # disksize is already <=25% of RAM by the formula above, an
        # extra physical cap was judged redundant. Not independently
        # measured; see docs/rationale.md [2] and experiments/README.md.
        compressionAlgorithm = "zstd";         # sourced -- [9]
        recompressionAlgorithm = "zstd(level=12)";
        recompressionTimerEnableByDefault = true;
        # extrapolated, low marginal value at this tier -- left on by
        # default for consistency; documented alternative is
        # `nixram.mode = "none"` for single-big-workload boxes.
        # rationale.md [13].
        priority = 100;                              # sourced -- [12]
      };
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
        diskSizeExpr = "min(ram / 2, 16384)";  # extrapolated / sourced cap -- [1]
        residentLimitExpr = null;              # extrapolated, open question -- [2]
        compressionAlgorithm = "zstd";         # sourced -- [9]
        recompressionAlgorithm = "zstd(level=12)";
        recompressionTimerEnableByDefault = true;  # extrapolated, low value -- [13]
        priority = 100;                              # sourced -- [12]
      };
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
