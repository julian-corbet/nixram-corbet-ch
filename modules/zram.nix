# modules/zram.nix
#
# Wires services.zram-generator.settings -- deliberately NOT the legacy
# NixOS `zramSwap` module, which only ever controls virtual disksize
# (via memoryPercent/memoryMax) and has no notion of a physical
# resident-limit at all; nixpkgs itself documents zram-generator as the
# intended replacement. See docs/rationale.md and studies/README.md.

{ lib, config, pkgs, ... }:

with lib;

let
  cfg = config.services.nixram;
  levelsData = import ../levels.nix;
  inherit (levelsData) levelNames levels;

  # See modules/default.nix "EVAL SAFETY" -- never index `levels` with
  # `cfg.level` directly.
  activeLevelName = if cfg.level != null then cfg.level else builtins.head levelNames;
  activeLevel = levels.${activeLevelName};
  activeZram = activeLevel.zram;

  diskSizeExpr = if cfg.zram.diskSizeOverride != null
    then cfg.zram.diskSizeOverride
    else activeZram.diskSizeExpr;

  residentLimitExpr = if cfg.zram.residentLimitOverride != null
    then cfg.zram.residentLimitOverride
    else activeZram.residentLimitExpr;

  priority = if cfg.zram.priorityOverride != null
    then cfg.zram.priorityOverride
    else activeZram.priority;

  recompressionAlgorithm = if cfg.zram.recompressionAlgorithmOverride != null
    then cfg.zram.recompressionAlgorithmOverride
    else activeZram.recompressionAlgorithm;

  # zram-generator's compression-algorithm syntax: a primary algorithm,
  # optionally followed by one or more secondary algorithms tagged
  # "(type=idle)" for the idle-recompression pass registered at device
  # creation. Only ever assembled here, in one place -- levels.nix only
  # stores the algorithm *choices*, not this syntax.
  compressionAlgorithm =
    if cfg.zram.recompressionTimer.enable && recompressionAlgorithm != null
    then "${activeZram.compressionAlgorithm} ${recompressionAlgorithm} (type=idle)"
    else activeZram.compressionAlgorithm;

  # sizing = "virtual"  -> only zram-size;
  # sizing = "physical" -> only zram-resident-limit (zram-size stays at
  #                        zram-generator's own upstream default,
  #                        min(ram / 2, 4096) -- only the physical
  #                        budget is nixram's opinion in this mode);
  # sizing = "both"     -> both keys.
  zramGeneratorSettings = {
    compression-algorithm = compressionAlgorithm;
    swap-priority = priority;
  } // optionalAttrs (cfg.zram.sizing != "physical") {
    zram-size = diskSizeExpr;
  } // optionalAttrs (cfg.zram.sizing != "virtual" && residentLimitExpr != null) {
    zram-resident-limit = residentLimitExpr;
  };

  # The recompression maintenance script: a rolling two-phase design.
  # Each run recompresses whatever was idle-marked by the PREVIOUS run
  # and has stayed untouched since (the kernel automatically clears a
  # page's idle flag the moment it's written again, so this is a real
  # dwell period, not "mark and recompress in the same breath" -- the
  # latter would recompress the entire device every single run, since
  # everything looks idle the instant after being marked). Only THEN
  # does it mark the current resident set idle again, becoming the
  # input for the NEXT run. Guarded on kernel recompression support at
  # runtime: skips silently (with a log line) if
  # /sys/block/zram0/recompress doesn't exist, e.g. pre-6.2 kernels or
  # CONFIG_ZRAM_MULTI_COMP disabled.
  recompressionScript = pkgs.writeShellScript "nixram-zram-recompress" ''
    set -euo pipefail

    dev=/sys/block/zram0

    if [ ! -e "$dev/recompress" ]; then
      echo "nixram: $dev/recompress not present (kernel lacks zram multi-compression support or it's disabled) -- skipping idle recompression this run" >&2
      exit 0
    fi

    # Phase 1: recompress pages idle-marked by the previous run that
    # have stayed untouched since (their idle flag survived).
    echo "type=idle" > "$dev/recompress"

    # Phase 2: mark the current resident set idle, for the NEXT run to
    # act on after a full dwell period (one timer interval).
    echo "all" > "$dev/idle"
  '';
in
{
  config = mkIf (cfg.enable && cfg.mode == "zram") {
    services.zram-generator.settings.zram0 = zramGeneratorSettings;

    systemd.services.nixram-zram-recompress = mkIf cfg.zram.recompressionTimer.enable {
      description = "nixram zram idle-page recompression (rolling two-phase pass)";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${recompressionScript}";
        # This is maintenance work fighting the exact symptom (memory
        # pressure / stalls) it exists to prevent -- keep it out of the
        # way of anything PSI is watching.
        Nice = 19;
        CPUWeight = 10;
        IOSchedulingClass = "idle";
      };
    };

    systemd.timers.nixram-zram-recompress = mkIf cfg.zram.recompressionTimer.enable {
      description = "Timer for nixram zram idle-page recompression";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = cfg.zram.recompressionTimer.onCalendar;
        Persistent = true;
      };
    };
  };
}
