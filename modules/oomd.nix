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
# ourselves instead, with our own numbers.

{ lib, config, ... }:

with lib;

let
  cfg = config.services.nixram;
  levelsData = import ../levels.nix;
  inherit (levelsData) levelNames levels;

  # See modules/default.nix "EVAL SAFETY".
  activeLevelName = if cfg.level != null then cfg.level else builtins.head levelNames;
  activeLevel = levels.${activeLevelName};

  pressureSliceConfig = {
    ManagedOOMMemoryPressure = "kill";
    ManagedOOMMemoryPressureLimit = "${toString activeLevel.oomd.pressureLimitPercent}%";
    ManagedOOMMemoryPressureDurationSec = "${toString activeLevel.oomd.pressureDurationSec}s";
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
      OOMScoreAdjust = -900;
      ManagedOOMPreference = "omit";
    };
  };
in
{
  config = mkIf cfg.enable {
    systemd.services = listToAttrs (map protectedUnitEntry cfg.oomd.protectedUnits);

    # When the oomd layer is off (the 256M default), actively default
    # the daemon itself off too -- nixpkgs ships systemd-oomd enabled by
    # default, and on the one tier where nixram disarms it, its idle RSS
    # is the entire reason for disarming (rationale.md [8]). mkDefault
    # both ways: a host config can still force either direction.
    systemd.oomd.enable = mkDefault cfg.oomd.enable;

    systemd.slices."-".sliceConfig = mkIf cfg.oomd.enable pressureSliceConfig;
    systemd.slices."user".sliceConfig = mkIf cfg.oomd.enable pressureSliceConfig;
  };
}
