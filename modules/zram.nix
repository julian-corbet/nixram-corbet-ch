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

  primaryAlgorithm = if cfg.zram.compressionAlgorithmOverride != null
    then cfg.zram.compressionAlgorithmOverride
    else activeZram.compressionAlgorithm;

  # zram-generator's compression-algorithm syntax: a primary algorithm,
  # optionally followed by one or more secondary algorithms tagged
  # "(type=idle)" for the idle-recompression pass registered at device
  # creation. Only ever assembled here, in one place -- levels.nix only
  # stores the algorithm *choices*, not this syntax.
  compressionAlgorithm =
    if cfg.zram.recompressionTimer.enable && recompressionAlgorithm != null
    then "${primaryAlgorithm} ${recompressionAlgorithm} (type=idle)"
    else primaryAlgorithm;

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

  # The recompression maintenance script: a rolling two-phase design,
  # gated on actual system idleness rather than run unconditionally on a
  # fixed schedule (Julian's explicit correction -- cadence should be
  # "whenever there is idle time", not a fixed calendar interval). The
  # timer fires often (see recompressionTimer.onCalendar's new default);
  # each firing checks CPU PSI first and does nothing at all unless the
  # box is genuinely quiet right now, so a busy box simply defers to
  # whenever it next goes idle instead of forcing this work in daily
  # regardless of load, and a box with frequent idle windows gets MORE
  # chances to mark and recompress, not fewer.
  #
  # Once the idle gate passes, the same rolling two-phase design as
  # before: each run recompresses whatever was idle-marked by the
  # PREVIOUS idle run and has stayed untouched since (the kernel
  # automatically clears a page's idle flag the moment it's written
  # again, so this is a real dwell period, not "mark and recompress in
  # the same breath" -- the latter would recompress the entire device
  # every single run, since everything looks idle the instant after
  # being marked). Only THEN does it mark the current resident set idle
  # again, becoming the input for the NEXT idle run. Guarded on kernel
  # recompression support at runtime: skips silently (with a log line)
  # if /sys/block/zram0/recompress doesn't exist, e.g. pre-6.2 kernels
  # or CONFIG_ZRAM_MULTI_COMP disabled.
  recompressionScript = pkgs.writeShellScript "nixram-zram-recompress" ''
    set -euo pipefail

    dev=/sys/block/zram0

    if [ ! -e "$dev/recompress" ]; then
      echo "nixram: $dev/recompress not present (kernel lacks zram multi-compression support or it's disabled) -- skipping idle recompression this run" >&2
      exit 0
    fi

    # Idle gate: only proceed if the box is genuinely quiet right now.
    # CPU PSI's "some" line (avg10) is the fraction of the last 10s any
    # task spent waiting for CPU -- a low value means little contention,
    # a reasonable proxy for "safe to spend cycles on background work."
    # Missing PSI (CONFIG_PSI=n, or psi=0 on the kernel command line) is
    # not fatal: proceed without the gate rather than never recompress
    # at all on such a kernel.
    psi=/proc/pressure/cpu
    if [ -e "$psi" ]; then
      some_avg10=$(awk '/^some/ {for (i=1;i<=NF;i++) if ($i ~ /^avg10=/) {sub("avg10=","",$i); print $i}}' "$psi")
      is_idle=$(awk -v v="''${some_avg10:-0}" 'BEGIN { print (v < 10.0) ? 1 : 0 }')
      if [ "$is_idle" != "1" ]; then
        echo "nixram: CPU pressure too high (some avg10=''${some_avg10}%) -- not idle, skipping this check (will retry next timer tick)" >&2
        exit 0
      fi
    else
      echo "nixram: $psi not present (kernel lacks PSI) -- proceeding without an idle gate" >&2
    fi

    # Phase 1: recompress pages idle-marked by the previous idle run
    # that have stayed untouched since (their idle flag survived).
    echo "type=idle" > "$dev/recompress"

    # Phase 2: mark the current resident set idle, for the NEXT idle
    # run to act on after a full dwell period.
    echo "all" > "$dev/idle"
  '';

  # PSI-gated swappiness relief valve. Julian's own design intent: hold
  # swappiness LOW at rest (reluctant tiers: only cache eviction, never
  # anon, under normal fluctuation), but let the kernel actually use swap
  # once a real overflow event is underway -- "swap is for overflow when
  # upgrades run or whatever, or for icecold pages," not for routine
  # fullness. Hysteresis, not a single threshold: avg10 (10s average) is
  # fast enough to catch a real spike quickly and enter relief; avg60
  # (60s average) is deliberately the SLOWER signal required to leave
  # relief, so a brief lull mid-spike doesn't bounce swappiness back down
  # before the pressure has actually resolved. State tracked in a small
  # file under /run so a reboot always starts back at the low baseline.
  # See docs/rationale.md [17].
  swappinessReliefScript = pkgs.writeShellScript "nixram-swappiness-relief" ''
    set -euo pipefail

    psi=/proc/pressure/memory
    state_file=/run/nixram-swappiness-relief.state
    baseline=${toString activeLevel.swappiness}
    relief=${toString cfg.zram.swappinessRelief.reliefValue}
    high=${toString cfg.zram.swappinessRelief.pressureHighThreshold}
    low=${toString cfg.zram.swappinessRelief.pressureLowThreshold}

    if [ ! -e "$psi" ]; then
      echo "nixram: $psi not present (kernel lacks PSI) -- relief valve has no signal to act on, leaving swappiness at its boot-time baseline" >&2
      exit 0
    fi

    some_line=$(awk '/^some/ {print; exit}' "$psi")
    avg10=$(echo "$some_line" | awk '{for (i=1;i<=NF;i++) if ($i ~ /^avg10=/) {sub("avg10=","",$i); print $i}}')
    avg60=$(echo "$some_line" | awk '{for (i=1;i<=NF;i++) if ($i ~ /^avg60=/) {sub("avg60=","",$i); print $i}}')

    state=baseline
    [ -e "$state_file" ] && state=$(cat "$state_file")

    if [ "$state" = "baseline" ]; then
      entering=$(awk -v v="''${avg10:-0}" -v h="$high" 'BEGIN { print (v >= h) ? 1 : 0 }')
      if [ "$entering" = "1" ]; then
        echo "$relief" > /proc/sys/vm/swappiness
        echo relief > "$state_file"
        echo "nixram: memory pressure rising (some avg10=''${avg10}% >= ''${high}%) -- entering relief, swappiness -> $relief" >&2
      fi
    else
      leaving=$(awk -v v="''${avg60:-100}" -v l="$low" 'BEGIN { print (v < l) ? 1 : 0 }')
      if [ "$leaving" = "1" ]; then
        echo "$baseline" > /proc/sys/vm/swappiness
        echo baseline > "$state_file"
        echo "nixram: memory pressure resolved (some avg60=''${avg60}% < ''${low}%) -- leaving relief, swappiness -> $baseline" >&2
      fi
    fi
  '';
in
{
  config = mkIf (cfg.enable && cfg.mode == "zram") {
    # services.zram-generator's own upstream module gates its ENTIRE config
    # (the systemd units, /etc/systemd/zram-generator.conf itself) behind
    # `mkIf cfg.enable` -- setting only `.settings` without this produces a
    # fully-populated but completely inert configuration: no error, no
    # warning, just no zram device at boot. Caught by the runtime VM test
    # (checks/swappiness-relief-vm-test.nix), not by eval-tests, which only
    # inspect `.settings` and have no way to notice the upstream gate was
    # never satisfied.
    services.zram-generator.enable = true;
    services.zram-generator.settings.zram0 = zramGeneratorSettings;

    systemd.services.nixram-zram-recompress = mkIf cfg.zram.recompressionTimer.enable {
      description = "nixram zram idle-page recompression (rolling two-phase pass)";
      # Explicit PATH dependency -- the script uses `awk`, and a systemd
      # service's default PATH is NOT guaranteed to include it just
      # because some package happens to be in environment.systemPackages
      # elsewhere. Caught by the runtime VM test: this was silently
      # absent before, so the script would exit 127 the first time it
      # actually ran on a box that hadn't separately installed gawk.
      path = [ pkgs.gawk ];
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

    systemd.services.nixram-swappiness-relief = mkIf cfg.zram.swappinessRelief.enable {
      description = "nixram PSI-gated swappiness relief valve";
      # See the matching comment on nixram-zram-recompress above -- same
      # missing-PATH bug, caught by the same runtime VM test.
      path = [ pkgs.gawk ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${swappinessReliefScript}";
        # Needs to react quickly to real pressure -- unlike recompression,
        # this is not background maintenance to defer, so no Nice/IOWeight
        # downgrade here.
      };
    };

    systemd.timers.nixram-swappiness-relief = mkIf cfg.zram.swappinessRelief.enable {
      description = "Timer for nixram PSI-gated swappiness relief valve";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "${toString cfg.zram.swappinessRelief.checkIntervalSec}s";
        OnUnitActiveSec = "${toString cfg.zram.swappinessRelief.checkIntervalSec}s";
        # systemd's own default AccuracySec is 1 MINUTE -- it coalesces
        # nearby timer firings for power saving, which silently defeats
        # a check interval shorter than that (caught by the runtime VM
        # test: a 5s test override never actually fired more often than
        # ~15-45s apart). This mechanism exists specifically to react to
        # pressure faster than a coarse, unconditional cadence would --
        # a 1-minute-accuracy default undermines that at ANY
        # checkIntervalSec setting, including the real 30s default.
        AccuracySec = "1s";
      };
    };
  };
}
