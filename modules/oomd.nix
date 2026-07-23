# modules/oomd.nix
#
# Arms systemd-oomd with PSI (pressure stall information) thresholds
# from the active level, on "-.slice" (the whole system) and
# "user.slice" (the parent of every per-session "user-$UID.slice"
# instance, so the whole user subtree is covered).
#
# NixOS naming note: the attribute names under `systemd.slices` EXCLUDE
# the ".slice" suffix -- `systemd.slices."-"` renders "-.slice",
# exactly as nixpkgs' own systemd-oomd module does it. Writing
# `systemd.slices."-.slice"` would silently render a unit named
# "-.slice.slice" that systemd never consults.
#
# DELIBERATELY NOT USING SwapUsedLimit / ManagedOOMSwap ANYWHERE. This
# is a documented omission, not an oversight -- see docs/faq.md. Reason:
# SwapUsedLimit and the per-unit `ManagedOOMSwap=kill` opt-in are both
# swap-USED-over-swap-TOTAL percentage detectors, and swap-TOTAL here
# means zram's `disksize`. On every level where `zram.sizing = "both"`
# (the default) and disksize is set generously beyond the real
# `residentLimit` safety budget -- which is nixram's whole thesis, see
# levels.nix -- that percentage is measured against a denominator that
# was never meant to be the real ceiling. A swap-percentage detector
# reads that setup as "plenty of headroom" right up until the resident
# limit (the actual wall) is hit, at which point it's already too late
# for a percentage-of-disksize warning to have fired early. PSI-based
# detection has no such blind spot: stall time is medium-agnostic, it
# doesn't care whether the swap medium is zram, zswap, or a disk
# partition, or how large its nominal capacity is. So nixram configures
# ManagedOOMMemoryPressure (PSI) and nothing else, on every tier, and
# never sets SwapUsedLimit or ManagedOOMSwap=kill anywhere. This isn't a
# "keep it as a decorative secondary backstop" compromise -- it's not
# configured at all.
#
# We do not use the built-in `systemd.oomd.enableRootSlice` /
# `enableSystemSlice` / `enableUserSlices` helpers: they hardcode an 80%
# pressure limit with no duration control, which doesn't let nixram
# express its own per-level PSI values. We set the same two slices
# ourselves instead, with our own numbers. (That 80% figure also isn't
# a real systemd-oomd/Fedora number under any name we could find --
# nixram's flat 60%/30s is the actual compiled-in upstream default; see
# docs/rationale.md [10].)
#
# PRESSURE DIAGNOSTICS: a second, independent unit below (gated on
# `oomd.pressureDiagnostics.enable`, on by default only for
# `mode = "zswap"`) periodically logs `memory.pressure` AND
# `io.pressure` together. Purely diagnostic -- see docs/rationale.md
# [10] and [14] for why zram doesn't need this (no disk in its path,
# `io.pressure` would be uninformative) and zswap does (a
# disk-fallthrough miss shows up in both signals at once, so seeing
# them together after the fact tells you whether a given pressure
# episode was CPU-bound or disk-bound).

{ lib, config, pkgs, ... }:

with lib;

let
  cfg = config.services.nixram;
  levelsData = import ../levels.nix;
  inherit (levelsData) levelNames levels;

  # See modules/default.nix "EVAL SAFETY".
  activeLevelName = if cfg.level != null then cfg.level else builtins.head levelNames;
  activeLevel = levels.${activeLevelName};

  # directed -- Julian: "for the elitebook at least adapt to what it has
  # now." zswap's real deployment cut the duration to 3s (from the 30s
  # shared default) system-wide, specifically to react faster under a
  # bursty compute (LLM-load) workload -- this is the one place nixram's
  # "zram/zswap share the number" stance (rationale.md [10]) turned out
  # not to hold up against the real fleet data point it's supposed to be
  # grounded in. The limit percentage (60%) is unchanged; only the
  # duration was shortened. Flagged as possibly workload-specific rather
  # than a general zswap-laptop fact (the real config ties it to a
  # heavy-compute use case) -- adapted here rather than left unverified.
  zswapOomdPressureDurationSec = 3;

  pressureSliceConfig = {
    ManagedOOMMemoryPressure = "kill";
    ManagedOOMMemoryPressureLimit = "${toString activeLevel.oomd.pressureLimitPercent}%";
    ManagedOOMMemoryPressureDurationSec =
      "${toString (if cfg.mode == "zswap" then zswapOomdPressureDurationSec else activeLevel.oomd.pressureDurationSec)}s";
  };

  # One serviceConfig per protected unit, merging both protection
  # layers: OOMScoreAdjust (kernel-fallback layer -- this is what still
  # protects the unit even if systemd-oomd is disabled, absent, or too
  # slow to react) and ManagedOOMPreference (systemd-oomd's own
  # userspace layer, only meaningful while the daemon actually runs,
  # harmless to set regardless). Both are unconditional on
  # `oomd.enable`, per the option's documented contract.
  #
  # `systemd.services` attribute names also exclude the ".service"
  # suffix (same naming rule as slices above), so accept either form in
  # `protectedUnits` and normalize here.
  protectedUnitEntry = unit: {
    name = removeSuffix ".service" unit;
    value.serviceConfig = {
      OOMScoreAdjust = mkDefault (-900);
      ManagedOOMPreference = mkDefault "omit";
    };
  };

  # Diagnostic only -- reads two /proc/pressure files and logs one line.
  # Guarded the same way recompression's kernel-support check in
  # modules/zram.nix is: skip silently (with a log line) rather than
  # fail, since PSI (CONFIG_PSI, or `psi=0` on the kernel command line)
  # isn't guaranteed present everywhere nixram runs.
  pressureDiagnosticsScript = pkgs.writeShellScript "nixram-pressure-diagnostics" ''
    set -euo pipefail

    if [ ! -e /proc/pressure/memory ] || [ ! -e /proc/pressure/io ]; then
      echo "nixram: /proc/pressure/{memory,io} not present (kernel lacks PSI, CONFIG_PSI=n, or psi=0 on the command line) -- skipping pressure diagnostics this run" >&2
      exit 0
    fi

    mem_full=$(awk '/^full / {print; exit}' /proc/pressure/memory)
    io_full=$(awk '/^full / {print; exit}' /proc/pressure/io)

    echo "nixram pressure snapshot: memory $mem_full | io $io_full"
  '';
in
{
  config = mkIf cfg.enable {
    # `//`-merged, not two separate `systemd.services.*` attribute paths --
    # Nix's own attrset-literal rule rejects defining `systemd.services`
    # both directly (a set) and via a dotted sub-path in the same literal
    # ("attribute already defined"), independent of NixOS module merging.
    systemd.services = listToAttrs (map protectedUnitEntry cfg.oomd.protectedUnits) // {
      nixram-pressure-diagnostics = mkIf cfg.oomd.pressureDiagnostics.enable {
        description = "nixram PSI pressure diagnostic snapshot (memory + io, for zswap severity correlation)";
        # Explicit PATH dependency for `awk` -- same missing-dependency
        # bug found by the runtime VM test on the zram-side PSI scripts
        # (modules/zram.nix); a systemd service's default PATH is not
        # guaranteed to include it otherwise.
        path = [ pkgs.gawk ];
        serviceConfig = {
          Type = "oneshot";
          ExecStart = "${pressureDiagnosticsScript}";
          Nice = 19;
          CPUWeight = 10;
          IOSchedulingClass = "idle";
        };
      };
    };

    # When the oomd layer is off (the 256M default), actively default
    # the daemon itself off too -- nixpkgs ships systemd-oomd enabled by
    # default, and on the one tier where nixram disarms it, its idle RSS
    # is the entire reason for disarming (rationale.md [8]). mkDefault
    # both ways: a host config can still force either direction.
    systemd.oomd.enable = mkDefault cfg.oomd.enable;

    # mkDefault on the CONTENTS, not just the mkIf gate: a host needs to be
    # able to override "-.slice" and "user.slice" INDEPENDENTLY (e.g. arm
    # the root slice at a different percentage than the level default while
    # leaving user.slice alone entirely) with a plain assignment, the same
    # "escape hatch on every layer, no mkForce needed" promise
    # modules/sysctls.nix already keeps. Before this, a host's own plain
    # `systemd.slices."user".sliceConfig = {};` would have collided with
    # this module's own definition instead of winning -- found adversarially
    # while working out how a real fleet host (e2-micro) could preserve its
    # own incident-tuned oomd config (root slice at 80%, user slice
    # deliberately left unarmed) on top of nixram.
    systemd.slices."-".sliceConfig = mkIf cfg.oomd.enable (mkDefault pressureSliceConfig);
    systemd.slices."user".sliceConfig = mkIf cfg.oomd.enable (mkDefault pressureSliceConfig);

    systemd.timers.nixram-pressure-diagnostics = mkIf cfg.oomd.pressureDiagnostics.enable {
      description = "Timer for nixram PSI pressure diagnostic snapshot";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = cfg.oomd.pressureDiagnostics.onCalendar;
        Persistent = true;
      };
    };
  };
}
