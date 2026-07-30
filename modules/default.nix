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
  cfg = config.nixram;
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
    ./zram-drift.nix
    ./zswap.nix
    ./oomd.nix
    ./sysctls.nix
  ];

  options.nixram = {
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
        `nixram.level = "...";` line. Run it once on the
        target machine, paste the result into your config, and commit
        it like any other hardware fact. This is "detect once, paste
        once" -- a manual step you commit, not an automated pipeline;
        see docs/faq.md for why that's an honest description and not a
        claim of parity with tools that materialize and check in a
        generated file automatically.
      '';
    };

    # ── hardware.totalMiB: a FACT, not a policy input ───────────────────
    #
    # Everything above and below this option is POLICY: `level` is a
    # discrete bucket the operator chooses, and every zram/zswap/oomd/
    # sysctl value in levels.nix is keyed off that choice, never off a
    # literal RAM number. Before this option existed, nixram had NO
    # eval-time notion of a host's actual installed RAM at all -- the one
    # thing that looks like one, `levels.<name>.ramMiB` in levels.nix, is
    # bucket METADATA: the upper boundary flake.nix's `detect-level` app
    # prints as a rounded-UP anchor, consumed by nothing in modules/*.nix
    # (grep it -- the only reader is the boundary table generator in
    # flake.nix). So there is nothing to reconcile here, only a genuinely
    # new fact to add: this option, and this option alone, is nixram's
    # answer to "how much RAM does this box actually have", kept
    # deliberately separate from `level` so that answer can never quietly
    # become a tuning input by accident. If a future change ever makes
    # modules/*.nix read `cfg.hardware.totalMiB` to compute a policy
    # value, that is the moment this option has stopped being a fact and
    # this comment must be rewritten to say so.
    #
    # Unit is MiB, not GiB/bytes/the `levelNames` GiB-ish label strings:
    # this matches every other RAM quantity zram-generator itself works
    # in (its own `ram` variable and every `*Expr` string in levels.nix
    # are MiB), and it matches the one place outside this repo that is
    # expected to mirror this fact -- a namespace-root host module reading
    # it as `config.nixram.hardware.totalMiB or null` needs the exact same
    # unit its own RAM-ceiling field already uses, or every read site
    # would need a silent, easy-to-forget conversion.
    #
    # `null` default, deliberately NOT required: nixram's own tuning is
    # driven entirely by `level`, a manually-pasted bucket (see that
    # option's own "detect once, paste once" description above) -- a host
    # that only wants zram/oomd/sysctl policy from nixram has no reason to
    # ALSO state its exact installed RAM, and forcing it to would just be
    # a second manual fact to keep in sync with `level` for no benefit
    # nixram itself needs. Optionality here is what lets a defensive
    # mirror elsewhere resolve to `null` cleanly on a host that never sets
    # this -- whether THAT read site is allowed to tolerate `null` or must
    # assert it resolved is entirely that read site's own call, not
    # something this option can or should decide on its behalf.
    hardware.totalMiB = mkOption {
      type = types.nullOr types.ints.positive;
      default = null;
      example = 8192;
      description = ''
        RAM actually installed on this host, in MiB -- a FACT, recorded
        here only so it exists at exactly one address for anything that
        needs to read it (this module's own cross-check below, or a
        namespace-root host module mirroring it elsewhere). It is NOT
        consulted by any zram/zswap/oomd/sysctl tuning in this project:
        every one of those derives from `nixram.level`, the operator's
        own bucket choice, never from this number. `null` (the default)
        is correct for a host that has picked a `level` and wants nothing
        more from nixram -- there is no assertion anywhere in this module
        that requires this to be set.
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

        That exclusivity is ENFORCED, not merely documented: `zram` mode
        actively turns zswap OFF (`zswap.enabled=0` on the kernel command
        line, plus a switch-time runtime write). This matters because a
        kernel built with CONFIG_ZSWAP_DEFAULT_ON=y arms zswap before
        userspace exists, with no cmdline parameter and nothing in any
        config file to point at -- so on those kernels "don't configure
        both" was never enough to prevent both from RUNNING. `none` does
        not touch zswap either way: it means "no swap-medium opinion".
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
        recompression at all at 256M/512M/1G (the operator's own instruction:
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
        recompresses. Cadence is idle-gated (the operator's explicit policy:
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
        once the pressure has genuinely passed. the operator's own design
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
      description = "Percent of total RAM the compressed zswap pool may occupy. The kernel's own upstream default is 20, deliberately not raised on the reasoning that the zswap pool competes with the SAME RAM as running applications, not disk I/O, so a bigger pool has a real opportunity cost -- but this project's own real zswap box (the reference laptop) runs 30 in production (raised from 25), treating the pool as a hot cache that should churn on bursty activity rather than a conservative reservation. Directed: adapted to match the real deployment rather than the untested upstream default.";
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

    oomd.units = mkOption {
      type = types.attrsOf (types.submodule {
        options = {
          memoryMin = mkOption {
            type = types.nullOr types.str;
            default = null;
            description = "systemd MemoryMin= for this unit -- a hard reservation the kernel can NEVER reclaim.";
          };
          memoryLow = mkOption {
            type = types.nullOr types.str;
            default = null;
            description = "systemd MemoryLow= for this unit -- a soft floor, reclaimed only when nothing else is.";
          };
          memoryHigh = mkOption {
            type = types.nullOr types.str;
            default = null;
            description = "systemd MemoryHigh= for this unit -- a throttle threshold.";
          };
          memoryMax = mkOption {
            type = types.nullOr types.str;
            default = null;
            description = "systemd MemoryMax= for this unit -- a hard wall (the cgroup OOM-kills inside itself first).";
          };
          oomScoreAdjust = mkOption {
            type = types.nullOr (types.ints.between (-1000) 1000);
            default = -900;
            description = "The kernel OOM killer's own last-resort fallback layer -- protects this unit even if systemd-oomd is disabled, absent, or too slow to react. Set null to leave unset for this unit.";
          };
          managedOOMPreference = mkOption {
            type = types.nullOr (types.enum [ "omit" "avoid" "auto" ]);
            default = "omit";
            description = ''"omit" never a kill candidate, "avoid" merely de-prioritised, only meaningful while systemd-oomd actually runs. Set null to leave unset for this unit.'';
          };
          restartSec = mkOption {
            type = types.nullOr types.str;
            default = null;
            description = ''
              Escape hatch: RestartSec= for this unit, paired with a
              generous StartLimitBurst/IntervalSec so a brief oomd/kernel
              OOM kill self-heals instead of latching the unit "failed".
              Off (null) by default -- most units don't need this; it
              exists for data services worth restarting fast after a
              memory-pressure kill.
            '';
          };
        };
      });
      default = { "sshd.service" = { }; };
      description = ''
        Per-unit memory-pressure protection, keyed by systemd unit name
        (the `.service` suffix is accepted and normalized away; a name
        matching no real service materializes a skeleton unit). Two
        independent kinds of protection, both optional per unit: the
        MemoryMin/Low/High/Max resource ladder (cgroup memory
        accounting), and the oomScoreAdjust + managedOOMPreference
        kill-priority pair (kernel fallback + systemd-oomd's own
        preference, deliberately redundant -- the kernel layer is what
        still protects a unit even if systemd-oomd itself is disabled,
        absent, or too slow to react). The default protects only sshd at
        the kill-priority layer with no resource ladder -- the historical
        `protectedUnits` behavior, preserved as this option's default so
        an existing config that never touched it sees no change.
      '';
    };

    oomd.sacrificialSlices = mkOption {
      type = types.attrsOf (types.submodule {
        options = {
          memoryHigh = mkOption {
            type = types.str;
            description = "systemd MemoryHigh= for this slice (throttle threshold).";
          };
          memoryMax = mkOption {
            type = types.str;
            description = "systemd MemoryMax= for this slice (hard wall).";
          };
          pressureLimitPercent = mkOption {
            type = types.ints.between 1 100;
            default = 60;
            description = "PSI ManagedOOMMemoryPressureLimit for this slice -- deliberately NOT tied to the level's own oomd.pressureLimitPercent, since a sacrificial slice usually wants to trip well before the box-wide limit.";
          };
        };
      });
      default = { };
      description = ''
        Named systemd slices deliberately given NO oomd avoid/omit
        weighting, so they are the FIRST thing systemd-oomd reclaims
        under pressure -- e.g. a lower-priority container workload
        sharing the box with the protected units above. Unlike
        `oomd.units` (which protects), this is a structural blast-radius
        cap: a hard MemoryMax wall plus its own PSI kill limit, one slice
        per attribute name (rendered as "<name>.slice"). Empty by default
        -- most boxes have nothing to sacrifice.
      '';
    };

    sysctls.reapplyBridge.enable = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Re-apply sysctl.d after systemd-sysctl, as insurance against a systemd-sysctl regression
        that exits 0 while applying NOTHING.

        WHY THIS EXISTS. systemd 260.1 shipped a systemd-sysctl that silently no-ops: exit 0, no
        warning, sysctls simply not applied. Fixed in 261, but the failure mode is the dangerous
        kind -- a box reports a clean activation and runs kernel defaults, and nothing surfaces
        the difference until something else goes wrong. Migrated into this module from a real
        host that hit it and carried a hand-written workaround since.

        Two details are load-bearing, both learned the hard way:

          Every ExecStart is `-` prefixed. Best-effort re-application must NEVER fail the unit --
          a failed unit makes switch-to-configuration exit non-zero, which deploy-rs autoRollback
          reads as a failed deploy and reverts the ENTIRE closure. On a live mail host that turns
          a cosmetic sysctl problem into an outage.

          systemd's own shipped defaults are applied first, explicitly. `sysctl --system` reads
          /etc, /run and /usr/lib only; on NixOS systemd's 50-default.conf lives in the store,
          outside all three, so a plain `--system` would silently drop fs.protected_*,
          kernel.kptr_restrict and friends.

        Off by default: it is insurance against a version-specific bug, and on a fixed systemd it
        is a harmless idempotent no-op rather than something every host should carry unasked.
      '';
    };

    oomd.monitorSystemSlice = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Also arm `system.slice` with this level's PSI values, alongside the root and user slices
        this module already configures.

        OFF by default because on a general-purpose box `-.slice` already covers system.slice as a
        descendant, and arming both means two cgroups competing to kill the same victim. It earns
        its keep on a SERVICE box -- one where every workload that matters is a systemd unit and
        there is no interactive load -- because scoping the kill decision to system.slice picks the
        worst SERVICE rather than the worst cgroup anywhere on the machine.

        Deliberately not `systemd.oomd.enableSystemSlice`: that helper hardcodes an 80% pressure
        limit with no duration control, which cannot express this module's per-level PSI values.
        Same reasoning as the root/user slices above.
      '';
    };

    oomd.defaultMemoryPressureLimitPercent = mkOption {
      type = types.nullOr (types.ints.between 1 100);
      default = null;
      description = ''
        Daemon-wide `DefaultMemoryPressureLimit` in oomd.conf's [OOM] section, or null to leave
        systemd's own compiled-in default alone.

        This is the fallback for any cgroup that does NOT carry an explicit
        `ManagedOOMMemoryPressureLimit` of its own -- distinct from the per-slice values this
        module sets, which always win where they apply. Setting it is how a host expresses "and
        everything I have not spoken about specifically should behave like this too".
      '';
    };

    oomd.defaultMemoryPressureDurationSec = mkOption {
      type = types.nullOr types.ints.positive;
      default = null;
      description = ''
        Daemon-wide `DefaultMemoryPressureDurationSec`, or null for systemd's own default.

        Pairs with `defaultMemoryPressureLimitPercent`: a limit without a duration reacts to
        instantaneous spikes, which on a small box is mostly noise. Set both or neither.
      '';
    };

    oomd.swapUsedLimitPercent = mkOption {
      type = types.nullOr (types.ints.between 1 100);
      default = null;
      description = ''
        Escape hatch: also arm systemd-oomd's global SwapUsedLimit
        (percent of zram's DISKSIZE, not physical usage) alongside the
        PSI-based per-slice kill this module already configures. OFF by
        default: under `zram.sizing = "both"` (nixram's own default),
        disksize is deliberately generous relative to the real
        `zram-resident-limit` budget, so a swap-used-of-disksize
        percentage reads "plenty of headroom" right up until the
        resident limit -- the actual wall -- is hit, too late to act as
        an early warning (see docs/faq.md, "Why aren't SwapUsedLimit /
        ManagedOOMSwap configured anywhere?"). Set this only if you
        understand that blind spot and want it anyway as a redundant,
        defense-in-depth signal alongside PSI -- e.g. matching an
        existing incident-tuned host config that already relies on it.
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

  config = mkIf cfg.enable (let
    # ── hardware.totalMiB cross-check ─────────────────────────────────
    #
    # `zram.diskSizeOverride`/`zram.residentLimitOverride` are, in the
    # common case, zram-generator EXPRESSION strings evaluated against
    # its own runtime `ram` variable at boot ("ram * 75 / 100",
    # "min(ram/2,8192)") -- opaque to Nix, and there is no sound way to
    # eval-time-check an expression Nix cannot itself evaluate. But
    # zram-generator's syntax also accepts a BARE integer as a literal
    # absolute MiB size, with no `ram` term anywhere in it -- and that
    # one shape IS checkable: an absolute ceiling above what is
    # physically installed can never be reached, on any kernel, ever.
    # That is not a tuning trade-off this project should stay quiet
    # about, it is the same class of "real, catchable bug" the arch/
    # microarch and reserved-name assertions elsewhere in this file
    # exist for -- so it earns an assertion, gated (like all of them)
    # on the fact actually being known: `hardware.totalMiB` is
    # optional (see its own description above), and an override cannot
    # be checked against a total nobody stated.
    #
    # Deliberately NOT extended to a `level` vs. `hardware.totalMiB`
    # bucket-consistency check (i.e. "does the chosen level match the
    # anchor `detect-level` would have picked for this total"): the
    # override options above exist precisely so an operator can steer
    # away from a level's own computed formula on purpose, and a host
    # that states its real RAM for record-keeping while intentionally
    # running a smaller level's tighter budget (a deliberate safety
    # margin, not a mistake) is a legitimate configuration this module
    # has no business failing. Physical impossibility is checkable and
    # sound; "did you mean a different level" is a question only the
    # operator can answer.
    literalOverrideMiB = str:
      if str != null && builtins.match "[0-9]+" str != null
      then lib.toInt str
      else null;

    oversizedZramOverrides = filter
      (o: o.miB != null && cfg.hardware.totalMiB != null && o.miB > cfg.hardware.totalMiB)
      [
        { option = "zram.diskSizeOverride"; miB = literalOverrideMiB cfg.zram.diskSizeOverride; }
        { option = "zram.residentLimitOverride"; miB = literalOverrideMiB cfg.zram.residentLimitOverride; }
      ];
  in {
    assertions = [
      {
        assertion = cfg.level != null;
        message = ''
          nixram.level must be set explicitly -- there is no
          eval-time auto-detection by design (Nix evaluation is pure
          and static; it cannot read a target machine's live
          /proc/meminfo). Run `nix run <flake>#detect-level` on the
          target machine once, then paste the printed
          `nixram.level = "...";` line into your
          configuration.
        '';
      }
      {
        assertion = cfg.mode == "zswap" -> config.swapDevices != [ ];
        message = ''
          nixram.mode = "zswap" requires at least one real
          swapDevices entry -- zswap is a compressed CACHE in front of
          disk-backed swap, not a swap device itself. Without a backing
          swap device, zswap.enabled=1 is a no-op.
        '';
      }
      {
        assertion = (cfg.mode == "zram" && cfg.zram.recompressionTimer.enable) -> (
          cfg.zram.recompressionAlgorithmOverride != null
          || activeLevel.zram.recompressionAlgorithm != null
        );
        message = ''
          nixram.zram.recompressionTimer.enable = true has no
          effect at level "${activeLevelName}": its recompressionAlgorithm
          is null (the 256M/512M/1G default -- primary-only compression,
          no secondary idle-pass algorithm is ever registered on the
          device), so the timer would arm a service that writes
          "type=idle" to zram's recompress attribute with nothing for it
          to do. Set zram.recompressionAlgorithmOverride (e.g.
          "zstd(level=12)") alongside recompressionTimer.enable at this
          level, or leave the timer off.
        '';
      }
      {
        assertion = cfg.mode == "zram" || (
          cfg.zram.diskSizeOverride == null
          && cfg.zram.residentLimitOverride == null
          && cfg.zram.priorityOverride == null
          && cfg.zram.recompressionAlgorithmOverride == null
          && cfg.zram.compressionAlgorithmOverride == null
        );
        message = ''
          nixram.zram.* override option(s) are set but
          nixram.mode is "${cfg.mode}", not "zram" -- these
          options are silently inert outside zram mode (modules/zram.nix's
          whole config block is gated on mode == "zram"). Either set
          mode = "zram", or remove the zram.* override(s), so a leftover
          override from a prior mode migration can't look active when it
          isn't.
        '';
      }
      {
        # modules/oomd.nix builds `systemd.slices` as
        # `listToAttrs (map sacrificialSliceEntry ...) // { "-" = ...; "user" = ...; }`
        # -- a plain, shallow Nix `//`, not a module-system merge. A
        # sacrificialSlices entry keyed "-"/"-.slice"/"user"/"user.slice"
        # would be silently and completely discarded by that merge (the
        # hardcoded literal on the right always wins the whole key), losing
        # its MemoryHigh/MemoryMax containment with no build error at all.
        # Caught adversarially; see the finding this assertion closes.
        assertion = !(cfg.oomd.sacrificialSlices ? "-")
          && !(cfg.oomd.sacrificialSlices ? "-.slice")
          && !(cfg.oomd.sacrificialSlices ? "user")
          && !(cfg.oomd.sacrificialSlices ? "user.slice");
        message = ''
          nixram.oomd.sacrificialSlices must not use the reserved
          names "-" / "-.slice" or "user" / "user.slice" -- those are the
          two slices this module itself already manages (the box-wide PSI
          root and user slices). A sacrificialSlices entry with either name
          would be silently discarded by an internal merge, losing its
          MemoryHigh/MemoryMax containment with no error. Pick a different
          slice name for whatever workload you're sacrificing.
        '';
      }
      {
        # Same shallow-`//` hazard as above, for `systemd.services` this
        # time: modules/oomd.nix merges `oomd.units` entries with its own
        # hardcoded `nixram-pressure-diagnostics` service literal. A unit
        # named exactly that would have its whole protection config
        # (memory ladder, oomScoreAdjust, restartSec) silently discarded.
        assertion = !(cfg.oomd.units ? "nixram-pressure-diagnostics")
          && !(cfg.oomd.units ? "nixram-pressure-diagnostics.service");
        message = ''
          nixram.oomd.units must not use the reserved name
          "nixram-pressure-diagnostics" (with or without the ".service"
          suffix) -- that is this module's own internal PSI diagnostics
          service name. A unit entry with that name would be silently
          discarded by an internal merge, losing its protection config
          with no error.
        '';
      }
    ] ++ map
      (o: {
        assertion = false;
        message = ''
          nixram.${o.option} is set to the literal absolute value
          "${toString o.miB}" (MiB) -- ${toString o.miB} MiB exceeds
          nixram.hardware.totalMiB (${toString cfg.hardware.totalMiB}
          MiB), the RAM actually installed on this host. An absolute
          zram-generator size above physically installed RAM can never
          be reached regardless of compression ratio, so this is a
          fixed value, not a formula -- almost certainly a typo'd digit
          or a value copy-pasted from a differently-sized host. Lower
          the override, correct `hardware.totalMiB` if THAT is what's
          actually wrong, or express the override as a zram-generator
          formula against its own `ram` variable (e.g. "ram * 75 / 100")
          instead of a bare number if an absolute-vs-percentage mix was
          never the intent.
        '';
      })
      oversizedZramOverrides;
  });
}
