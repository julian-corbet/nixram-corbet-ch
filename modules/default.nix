# modules/default.nix
#
# nixram's whole public option surface. Small and boring on purpose --
# one enum picks a RAM level, everything else is an override.
#
# EVAL SAFETY: `nixram.level` has no default (see the option below for
# why). That means `cfg.level` can legitimately be `null` while this
# module is still being evaluated -- e.g. while NixOS builds
# `config.system.build.toplevel`, which forces most of `config` in one
# pass, well before/independent of whichever order `assertions` happens
# to be checked in. If any `levels.${cfg.level}` lookup ran directly
# against a null level, it would throw a raw "attribute ... missing" /
# "value is null while a string was expected" Nix error -- exactly the
# kind of cryptic failure this project's whole `nixram.level` design
# exists to prevent (see docs/faq.md).
#
# The fix used throughout every modules/*.nix file: never index `levels`
# with `cfg.level` directly. Always go through `activeLevel` below, which
# falls back to an arbitrary valid level when `cfg.level` is null. The
# fallback value is never seen by a real user, because `mkIf cfg.enable`
# gates all config on `cfg.enable`, and the `assertions` list (which DOES
# fail the build, with the friendly message) fires whenever enable=true
# and level=null. The fallback only exists so that forcing unrelated
# attributes of `config` can never itself crash before that assertion
# gets to speak.

{ lib, config, ... }:

with lib;

let
  cfg = config.services.nixram;
  levelsData = import ../levels.nix;
  inherit (levelsData) levelNames levels;

  # See "EVAL SAFETY" above: this is the one and only place a null level
  # is tolerated. Every other module file imports `activeLevel` from
  # here and never touches `levels` or `cfg.level` directly.
  activeLevelName = if cfg.level != null then cfg.level else builtins.head levelNames;
  activeLevel = levels.${activeLevelName};
in
{
  imports = [
    ./zram.nix
    ./zswap.nix
    ./oomd.nix
    ./sysctls.nix
  ];

  options.services.nixram = {
    enable = mkEnableOption "coherent memory-pressure tuning (zram/zswap + oomd + sysctls) for a given RAM level";

    level = mkOption {
      type = types.nullOr (types.enum levelNames);
      default = null;
      example = "4G";
      description = ''
        One of the fourteen anchor RAM levels nixram is tuned for:
        ${concatStringsSep ", " levelNames}.

        There is NO default, and there never will be an eval-time
        "auto". Nix evaluation is pure and static: it cannot read a
        target machine's live `/proc/meminfo`, and a config that
        silently guessed one would trade a wrong OOM policy for the
        appearance of convenience. Leaving `level` unset is therefore a
        hard evaluation error (see `assertions` below), not a fallback.

        Instead, nixram ships:

            nix run <flake>#detect-level

        a tiny script that reads `/proc/meminfo` on the machine you run
        it on and prints the matching level plus a ready-to-paste
        `services.nixram.level = "...";` line. Run it once on the
        target machine, paste the result into your config, and commit
        it like any other hardware fact. This is "detect once, paste
        once" -- a manual step you commit, not an automated pipeline;
        see docs/faq.md for why that's an honest description and not a
        claim of parity with tools that materialize and check in a
        generated file automatically.
      '';
    };

    mode = mkOption {
      type = types.enum [ "zram" "zswap" "none" ];
      default = "zram";
      description = ''
        `zram`  : an in-RAM compressed swap device. The default, and the
                  right choice for servers/VMs with no real disk swap.
                  Sized per `zram.sizing` below.
        `zswap` : a compressed CACHE in front of a REAL disk-backed swap
                  device (swapfile or partition). For laptops/desktops
                  that already have `swapDevices`. Requires at least one
                  real swap device to exist -- see `assertions` below;
                  zswap without backing swap is inert.
        `none`  : only the oomd + sysctl layers run (e.g. a huge-RAM box
                  running one large non-swap-shaped workload).

        `zram` and `zswap` are deliberately mutually exclusive (not
        offered as a combination): double-compression, no sourced
        benefit. See docs/faq.md.
      '';
    };

    zram.sizing = mkOption {
      type = types.enum [ "virtual" "physical" "both" ];
      default = "both";
      description = ''
        `virtual`  : only `zram-size` (disksize) is set -- a cheap
                     worst-case ceiling; physical usage stays elastic
                     underneath it.
        `physical` : only `zram-resident-limit` (mem_limit) is set.
        `both`     : (recommended, and the default) -- set the level's
                     disksize as a generous virtual ceiling AND
                     mem_limit as the tight real-RAM budget that
                     actually protects the box. See the central-conflict
                     note at the top of levels.nix for why disksize is
                     allowed to be generous only because mem_limit is
                     the real budget.
      '';
    };

    zram.diskSizeOverride = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "Escape hatch: override the level's computed zram-size expression (zram-generator expression syntax, e.g. \"ram\" or \"min(ram / 2, 8192)\").";
    };

    zram.residentLimitOverride = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "Escape hatch: override the level's computed zram-resident-limit expression. Use \"0\" for unlimited.";
    };

    zram.priorityOverride = mkOption {
      type = types.nullOr (types.ints.between (-1) 32767);
      default = null;
      description = "Escape hatch: override the zram swap device priority (zram-generator's own upstream default, and the level default here, is 100 -- deliberately high so zram always wins over any disk swap present; see docs/faq.md). Range per zram-generator: -1 to 32767.";
    };

    zram.recompressionAlgorithmOverride = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "Escape hatch: override the level's idle-recompression algorithm spec (e.g. \"zstd(level=12)\").";
    };

    zram.compressionAlgorithmOverride = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = ''
        Escape hatch: override the level's primary (synchronous, write-path)
        compression algorithm. Level defaults: `zstd(level=3)` with no
        recompression at all at 256M/512M/1G (Julian's own instruction:
        "everything up to a GB goes to zstd primary and done"); `lz4`
        paired with `zstd(level=3)` recompression from 2G up -- see
        docs/rationale.md [9] for why the split falls at the 1G/2G
        boundary (workload compute-boundedness, not headroom).

        Escape hatches here should be rare: the policy above already
        encodes the reasoning that used to live only in a per-box override
        (an earlier version of this design tried to solve very-CPU-weak
        boxes as an override case; that reasoning is now the 256M/512M/1G
        default instead). Use this only for a genuinely unusual box the
        level-based policy doesn't fit -- state the outcome you want
        directly, same as every other zram override.
      '';
    };

    zram.recompressionTimer.enable = mkOption {
      type = types.bool;
      default = activeLevel.zram.recompressionTimerEnableByDefault;
      description = ''
        Ships a systemd timer that drives zram's idle-page recompression:
        mark the current resident set idle, and on the NEXT run,
        recompress whatever survived untouched since the previous
        marking with a denser algorithm. The kernel does neither of
        these steps automatically -- see docs/rationale.md [11] and
        docs/faq.md. Silently a no-op (with a log line) on kernels
        without zram multi-compression support; see
        `zram.recompressionTimer.onCalendar`.
      '';
    };

    zram.recompressionTimer.onCalendar = mkOption {
      type = types.str;
      default = "*:0/15";
      description = ''
        systemd OnCalendar= expression for how often the recompression
        timer CHECKS whether to act -- not how often it actually
        recompresses. Cadence is idle-gated (Julian's explicit policy:
        "whenever there is idle time", not a fixed schedule): every firing
        reads CPU PSI first and does nothing unless the box is genuinely
        quiet right now, so a busy box simply defers to its next idle
        window instead of being forced to run regardless of load, while a
        box with frequent idle windows gets more chances to mark and
        recompress, not fewer. Default (every 15 minutes) is an
        UNVALIDATED STARTING POINT for the check frequency itself -- see
        experiments/README.md (002) and docs/rationale.md [11]. Tune
        freely; there is no sourced "right" answer yet.
      '';
    };

    zram.swappinessRelief.enable = mkOption {
      type = types.bool;
      default = activeLevel.swappinessReliefEnableByDefault;
      description = ''
        Ships a systemd timer that watches memory PSI and temporarily
        raises `vm.swappiness` above the level's low reluctant baseline
        during genuine, sustained memory pressure -- then lowers it back
        once the pressure has genuinely passed. Julian's own design
        intent: "swap is for overflow when upgrades run or whatever, or
        for icecold pages" -- a low static swappiness serves that on its
        own most of the time, but a real overflow event (a deploy spike,
        a burst of legitimate load) still needs the kernel able to lean
        on swap when it genuinely has to. On by default only on
        RELUCTANT tiers (2G-128G); dire tiers are already eager by design
        and have no low baseline to relieve from. See docs/rationale.md
        [17].
      '';
    };

    zram.swappinessRelief.reliefValue = mkOption {
      type = types.ints.between 0 200;
      default = 60;
      description = ''
        `vm.swappiness` value applied while genuine memory pressure is
        detected (see `pressureHighThreshold`). Defaults to 60 -- the
        plain kernel default, and this project's own former reluctant-
        tier baseline -- as a deliberate anchor: under real pressure, the
        box behaves like an ordinary, un-tuned system would, rather than
        the unusually low value it holds at rest.
      '';
    };

    zram.swappinessRelief.pressureHighThreshold = mkOption {
      type = types.ints.between 1 100;
      default = 10;
      description = ''
        Memory PSI "some" line's avg10 (percent), read every
        `checkIntervalSec`. At or above this, the box enters relief mode
        (swappiness -> `reliefValue`) on the next check. 10 mirrors the
        CPU-PSI idle-gate threshold already used for recompression
        (docs/rationale.md [11]) -- the same number, the opposite
        direction, on a different pressure file.
      '';
    };

    zram.swappinessRelief.pressureLowThreshold = mkOption {
      type = types.ints.between 0 100;
      default = 1;
      description = ''
        Memory PSI "some" line's avg60 (percent). Once already in relief
        mode, the box only returns to the low baseline once avg60 drops
        below this -- deliberately the SLOWER-moving 60-second average,
        not avg10, so a brief lull right after a spike doesn't bounce
        swappiness back down before the pressure has actually resolved.
      '';
    };

    zram.swappinessRelief.checkIntervalSec = mkOption {
      type = types.ints.positive;
      default = 30;
      description = ''
        How often the relief-valve timer checks memory PSI. Pressure can
        build far faster than the 15-minute cadence used for the
        (CPU-idle, not urgency-driven) recompression timer -- this needs
        to react within seconds of real pressure appearing, not wait for
        a slow poll. Unvalidated starting point; tune freely.
      '';
    };

    zswap.maxPoolPercent = mkOption {
      type = types.ints.between 1 100;
      default = 30;
      description = "Percent of total RAM the compressed zswap pool may occupy. The kernel's own upstream default is 20, deliberately not raised on the reasoning that the zswap pool competes with the SAME RAM as running applications, not disk I/O, so a bigger pool has a real opportunity cost -- but this project's own real zswap box (elitebook) runs 30 in production (raised from 25), treating the pool as a hot cache that should churn on bursty activity rather than a conservative reservation. Directed: adapted to match the real deployment rather than the untested upstream default.";
    };

    zswap.acceptThresholdPercent = mkOption {
      type = types.ints.between 1 100;
      default = 90;
      description = "Once the pool fills to maxPoolPercent and stops accepting new pages, it must drain back to this percentage of that ceiling before it resumes accepting compressed pages. Upstream default hysteresis band, prevents thrash right at the boundary.";
    };

    zswap.shrinkerEnabled = mkOption {
      type = types.bool;
      default = true;
      description = "Proactively write back cold zswap pages to the real disk swap under pressure rather than waiting for the pool to hit its ceiling and block. Off by default upstream (kernel >=6.8); nixram turns it on.";
    };

    zswap.diskMedium = mkOption {
      type = types.enum [ "ssd" "hdd" ];
      default = "ssd";
      description = "The backing disk-swap medium behind zswap. Drives vm.page-cluster (2 for ssd, kernel default 3 for hdd) -- a disk-medium property, distinct from zram's page-cluster=0.";
    };

    oomd.enable = mkOption {
      type = types.bool;
      default = activeLevel.oomd.enable;
      description = "Arm systemd-oomd with PSI-based thresholds from the active level. Off only at the 256M level by default (unmeasured tradeoff, not a sourced number -- see docs/rationale.md [8]); override freely either direction.";
    };

    oomd.pressureDiagnostics.enable = mkOption {
      type = types.bool;
      default = cfg.mode == "zswap";
      description = ''
        Log a periodic PSI snapshot -- both `memory.pressure` and
        `io.pressure`, "full" lines -- to the journal. Diagnostic only,
        never wired into any kill decision (systemd-oomd has no way to
        AND two pressure signals together). Exists because an identical
        `memory.pressure` reading means different real severity
        depending on swap backend: zswap misses fall through to a real,
        possibly slow disk, so `io.pressure` rises right alongside it;
        zram never touches a disk at all, so `io.pressure` would tell
        you nothing zram-specific. See docs/rationale.md [10] and [14].
        Defaults on only for `mode = "zswap"`.
      '';
    };

    oomd.pressureDiagnostics.onCalendar = mkOption {
      type = types.str;
      default = "minutely";
      description = "systemd OnCalendar= expression for the pressure-diagnostics timer. Diagnostic logging only -- a coarse interval is fine; tune freely.";
    };

    oomd.protectedUnits = mkOption {
      type = types.listOf types.str;
      default = [ "sshd.service" ];
      description = ''
        systemd SERVICES set to `ManagedOOMPreference = "omit"`
        (systemd-oomd's userspace layer, applied at every level
        regardless of `oomd.enable`) AND `OOMScoreAdjust = -900` (the
        kernel OOM killer's own last-resort fallback layer, always
        applied). Two independent protection layers, deliberately
        redundant: the second one is what still protects these units
        even if systemd-oomd itself is disabled, absent, or too slow to
        react. Name existing services only (a name that matches no real
        service would materialize a skeleton unit); the `.service`
        suffix is accepted and normalized away.
      '';
    };

    sysctls.enable = mkOption {
      type = types.bool;
      default = true;
      description = "Escape hatch: set to false to disable nixram's sysctl layer entirely (swappiness, page-cluster, watermark_*, MGLRU min_ttl_ms) while still getting the zram/zswap device and oomd wiring.";
    };

    minFreeKbytesOverride = mkOption {
      type = types.nullOr types.ints.positive;
      default = null;
      description = ''
        Escape hatch only. No level in this module overrides
        `vm.min_free_kbytes` by default -- no sourced universal per-GB
        formula exists anywhere in the kernel docs or any distro this
        project researched; the kernel's own computed value is kept
        everywhere. See docs/rationale.md [6].
      '';
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.level != null;
        message = ''
          services.nixram.level must be set explicitly -- there is no
          eval-time auto-detection by design (Nix evaluation is pure
          and static; it cannot read a target machine's live
          /proc/meminfo). Run `nix run <flake>#detect-level` on the
          target machine once, then paste the printed
          `services.nixram.level = "...";` line into your
          configuration.
        '';
      }
      {
        assertion = cfg.mode == "zswap" -> config.swapDevices != [ ];
        message = ''
          services.nixram.mode = "zswap" requires at least one real
          swapDevices entry -- zswap is a compressed CACHE in front of
          disk-backed swap, not a swap device itself. Without a backing
          swap device, zswap.enabled=1 is a no-op.
        '';
      }
    ];
  };
}
