# system-manager/oomd.nix
#
# The system-manager equivalent of modules/oomd.nix. `systemd.slices.<name>.sliceConfig`
# is a REAL, fully-supported system-manager option (confirmed by reading
# nix/modules/systemd.nix: it renders through the exact same nixpkgs
# `systemdUtils.lib.sliceToUnit` code NixOS itself uses) -- so the actual PSI
# slice configuration below ports over essentially verbatim from the NixOS
# module. Two things do NOT port over unchanged:
#
#   - Toggling the systemd-oomd DAEMON itself (`systemd.oomd.enable` in the
#     NixOS module) -- no such option exists here. Assumed already running
#     via the distro's own defaults. `oomd.enable` here (default.nix) only
#     gates whether nixram ARMS the slice config below, not the daemon.
#   - `oomd.protectedUnits` -- system-manager cannot merge options into a
#     FOREIGN unit's serviceConfig (sshd.service is pacman-owned here, not
#     declared by this config at all), so the same net effect
#     (OOMScoreAdjust=-900 + ManagedOOMPreference=omit) is achieved via a
#     `<unit>.d/` systemd drop-in file instead -- systemd's own native
#     override mechanism, exactly the pattern elitebook's own
#     `oomd.conf.d/99-ai-workload.conf` already proves works for a different
#     unit under this same tool.
#
# Root-cause note carried over from the NixOS module: DELIBERATELY NOT USING
# SwapUsedLimit / ManagedOOMSwap ANYWHERE -- see modules/oomd.nix's own header
# comment for the full reasoning (PSI stall time has no blind spot the way a
# swap-used/swap-total percentage detector does). Applies identically here.

{ lib, config, pkgs, ... }:

with lib;

let
  cfg = config.services.nixram;
  levelsData = import ../levels.nix;
  inherit (levelsData) levelNames levels;

  activeLevelName = if cfg.level != null then cfg.level else builtins.head levelNames;
  activeLevel = levels.${activeLevelName};

  # Same override as modules/oomd.nix: zswap's real deployment cuts the
  # duration to 3s (from the shared 30s default), directed from Julian's
  # "adapt to what it has now" instruction -- see rationale.md [10].
  zswapOomdPressureDurationSec = 3;

  pressureSliceConfig = {
    ManagedOOMMemoryPressure = "kill";
    ManagedOOMMemoryPressureLimit = "${toString cfg.oomd.pressureLimitPercent}%";
    ManagedOOMMemoryPressureDurationSec =
      "${toString (if cfg.mode == "zswap" then zswapOomdPressureDurationSec else cfg.oomd.pressureDurationSec)}s";
  };

  protectedUnitEtcEntry = unit:
    let
      name = removeSuffix ".service" unit;
    in
    {
      name = "systemd/system/${name}.service.d/nixram-oom-protect.conf";
      value = {
        replaceExisting = true;
        text = ''
          [Service]
          OOMScoreAdjust=-900
          ManagedOOMPreference=omit
        '';
      };
    };

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
    # Unconditional on oomd.enable, same as the NixOS module: OOMScoreAdjust
    # is the kernel-fallback layer, meaningful even with the slice config
    # below turned off (e.g. while adopting nixram's sysctls on a host that
    # keeps its own existing, differently-shaped oomd setup for round one).
    environment.etc = listToAttrs (map protectedUnitEtcEntry cfg.oomd.protectedUnits);

    systemd.slices."-".sliceConfig = mkIf cfg.oomd.enable pressureSliceConfig;
    systemd.slices."user".sliceConfig = mkIf cfg.oomd.enable pressureSliceConfig;

    systemd.services.nixram-pressure-diagnostics = mkIf cfg.oomd.pressureDiagnostics.enable {
      description = "nixram PSI pressure diagnostic snapshot (memory + io, for zswap severity correlation)";
      path = [ pkgs.gawk ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${pressureDiagnosticsScript}";
        Nice = 19;
        CPUWeight = 10;
        IOSchedulingClass = "idle";
      };
    };

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
