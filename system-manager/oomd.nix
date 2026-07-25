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
#   - `oomd.units` -- system-manager cannot merge options into a FOREIGN
#     unit's serviceConfig (sshd.service is pacman-owned here, not declared
#     by this config at all), so every field renders as a line in a
#     `<unit>.d/` systemd drop-in file instead -- systemd's own native
#     override mechanism, exactly the pattern elitebook's own
#     `oomd.conf.d/99-ai-workload.conf` already proves works for a different
#     unit under this same tool.
#
# SwapUsedLimit / ManagedOOMSwap: OFF BY DEFAULT, opt-in via
# `oomd.swapUsedLimitPercent` -- see modules/oomd.nix's own header comment for
# the full blind-spot reasoning (PSI stall time has no blind spot the way a
# swap-used/swap-total percentage detector does). Applies identically here;
# rendered as an `oomd.conf.d/` drop-in below since this backend has no
# `systemd.oomd.*` option surface to set natively. `ManagedOOMSwap=kill` (the
# PER-UNIT equivalent) still has no opt-in anywhere; only the box-wide
# SwapUsedLimit does.

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

  # Same `oomd.units` model as modules/oomd.nix, rendered differently:
  # system-manager cannot merge into a FOREIGN unit's native option tree
  # (sshd.service is pacman-owned here, not declared by this config at
  # all), so every field renders as a line in a `<unit>.d/` systemd
  # drop-in file instead -- systemd's own native override mechanism.
  # Only fields the spec actually set produce a line; the [Unit] section
  # is omitted entirely when restartSec is unset.
  unitDropinEntry = name: spec:
    let
      cleanName = removeSuffix ".service" name;
      serviceLines =
        optional (spec.memoryMin != null) "MemoryMin=${spec.memoryMin}"
        ++ optional (spec.memoryLow != null) "MemoryLow=${spec.memoryLow}"
        ++ optional (spec.memoryHigh != null) "MemoryHigh=${spec.memoryHigh}"
        ++ optional (spec.memoryMax != null) "MemoryMax=${spec.memoryMax}"
        ++ optional (spec.oomScoreAdjust != null) "OOMScoreAdjust=${toString spec.oomScoreAdjust}"
        ++ optional (spec.managedOOMPreference != null) "ManagedOOMPreference=${spec.managedOOMPreference}"
        ++ optional (spec.restartSec != null) "RestartSec=${spec.restartSec}";
      unitLines =
        optionals (spec.restartSec != null) [ "StartLimitBurst=20" "StartLimitIntervalSec=5min" ];
    in
    {
      name = "systemd/system/${cleanName}.service.d/nixram-oom-protect.conf";
      value = {
        replaceExisting = true;
        text =
          (optionalString (unitLines != [ ]) "[Unit]\n${concatStringsSep "\n" unitLines}\n\n")
          + "[Service]\n${concatStringsSep "\n" serviceLines}\n";
      };
    };

  # Same as modules/oomd.nix's sacrificialSliceEntry -- systemd.slices.<name>
  # is a real, supported system-manager option (see file header), so this
  # ports over verbatim.
  sacrificialSliceEntry = name: spec: {
    name = removeSuffix ".slice" name;
    value.sliceConfig = {
      MemoryAccounting = true;
      MemoryHigh = spec.memoryHigh;
      MemoryMax = spec.memoryMax;
      ManagedOOMMemoryPressure = "kill";
      ManagedOOMMemoryPressureLimit = "${toString spec.pressureLimitPercent}%";
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
    # Unconditional on oomd.enable, same as the NixOS module: the kill-priority
    # layer is meaningful even with the slice config below turned off (e.g.
    # while adopting nixram's sysctls on a host that keeps its own existing,
    # differently-shaped oomd setup for round one). SwapUsedLimit -- system-
    # manager has no `systemd.oomd.*` option surface at all, so it renders as
    # its own oomd.conf.d drop-in instead of a native option.
    environment.etc = listToAttrs (mapAttrsToList unitDropinEntry cfg.oomd.units)
      // optionalAttrs (cfg.oomd.swapUsedLimitPercent != null) {
        "systemd/oomd.conf.d/nixram-swap-used-limit.conf" = {
          replaceExisting = true;
          text = ''
            [OOM]
            SwapUsedLimit=${toString cfg.oomd.swapUsedLimitPercent}%
          '';
        };
      };

    # mkDefault on the CONTENTS, not just the mkIf gate -- same fix and same
    # reason as modules/oomd.nix:165-166 (this backend had silently dropped
    # it on the port): a host needs to be able to override "-.slice" or
    # "user.slice" INDEPENDENTLY with a plain assignment, no lib.mkForce
    # needed, per the project's "escape hatch on every layer" stance.
    # Without mkDefault here, a host redefining a shared key at the same
    # priority throws "conflicting definition values"; redefining the whole
    # slice to `{}` silently wins instead of clearing to nixram's default --
    # both worse than the NixOS module's own behavior for the identical
    # option. `//`-merged with the sacrificial slices for the same reason
    # `environment.etc` above is built as one attrset.
    systemd.slices = listToAttrs (mapAttrsToList sacrificialSliceEntry cfg.oomd.sacrificialSlices) // {
      "-".sliceConfig = mkIf cfg.oomd.enable (mkDefault pressureSliceConfig);
      "user".sliceConfig = mkIf cfg.oomd.enable (mkDefault pressureSliceConfig);
    };

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
