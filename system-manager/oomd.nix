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
#     override mechanism, exactly the pattern the reference laptop's own
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
  cfg = config.nixram;
  levelsData = import ../levels.nix;
  inherit (levelsData) levelNames levels;

  activeLevelName = if cfg.level != null then cfg.level else builtins.head levelNames;
  activeLevel = levels.${activeLevelName};

  # Same override as modules/oomd.nix: zswap's real deployment cuts the
  # duration to 3s (from the shared 30s default), directed from the operator's
  # "adapt to what it has now" instruction -- see rationale.md [10].
  zswapOomdPressureDurationSec = 3;

  pressureSliceConfig = {
    ManagedOOMMemoryPressure = "kill";
    ManagedOOMMemoryPressureLimit = "${toString cfg.oomd.pressureLimitPercent}%";
    ManagedOOMMemoryPressureDurationSec =
      "${toString (if cfg.mode == "zswap" then zswapOomdPressureDurationSec else cfg.oomd.pressureDurationSec)}s";
  };

  # Same defense as modules/oomd.nix's own `sliceCollapseWarning` -- see that file's comment for
  # the mechanism. Ported rather than shared: this backend's `"-".sliceConfig = mkDefault
  # pressureSliceConfig;` (below) is the identical shape, so it is exposed to the identical bug --
  # a NESTED field assignment (`systemd.slices."-".sliceConfig.MemoryMin = "...";`, from a host or
  # a third module) sits at normal priority and silently discards this whole attrset, not just the
  # field it touched, and that is indistinguishable from the DELIBERATE `sliceConfig = { };`
  # wholesale-disarm case this file's own comment, just below, exists to keep working.
  sliceCollapseWarning = name:
    let effective = config.systemd.slices.${name}.sliceConfig or { };
    in optional
      (effective != { }
        && effective != pressureSliceConfig
        && all (k: builtins.hasAttr k pressureSliceConfig) (builtins.attrNames effective))
      ''
        nixram: systemd.slices."${name}".sliceConfig is missing ${
          concatStringsSep ", "
            (subtractLists (builtins.attrNames effective) (builtins.attrNames pressureSliceConfig))
        } of the PSI fields nixram's oomd layer would otherwise arm there. If sliceConfig was set
        to `{ }` deliberately to disarm this slice, or to a fully custom set on purpose, this is
        expected -- ignore it. If it was set by naming ONE nested field directly instead of the
        whole attrset, that partial definition sits at normal priority and silently discarded
        nixram's whole contribution to this slice, not just the field it touched.
      '';

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
    # `optionalAttrs cfg.oomd.enable`, NOT `mkIf` on the sliceConfig -- and the
    # difference is load-bearing on THIS backend specifically, unlike the NixOS
    # one. `mkIf false` empties an attribute's CONTENTS but still creates the
    # ATTRIBUTE, so `systemd.slices."-"` / `."user"` stayed declared with an
    # empty sliceConfig whenever a host set `oomd.enable = false`. NixOS merges
    # every definition of a given slice into one unit alongside nixpkgs' own,
    # so an empty extra definition there is a genuine no-op. system-manager
    # does not merge: it writes one standalone file per declared unit into
    # /etc/systemd/system/, which OUTRANKS the distro's /usr/lib/systemd/system
    # copy. The result was a two-line `[Unit]\n\n[Slice]\n` file shadowing the
    # distro's real user.slice -- silently dropping its Description and, more
    # importantly, its `Before=slices.target` ordering. Caught before it ever
    # activated, on a CachyOS host adopting the sysctl layer with
    # oomd.enable = false (the exact combination the option exists for).
    #
    # mkDefault is kept INSIDE, so a host can still override either slice with
    # a plain assignment when oomd IS enabled -- that escape hatch must not regress.
    systemd.slices = listToAttrs (mapAttrsToList sacrificialSliceEntry cfg.oomd.sacrificialSlices)
      // optionalAttrs cfg.oomd.enable {
        "-".sliceConfig = mkDefault pressureSliceConfig;
        "user".sliceConfig = mkDefault pressureSliceConfig;
      };

    # See `sliceCollapseWarning`'s own comment, above.
    warnings = optionals cfg.oomd.enable
      (sliceCollapseWarning "-" ++ sliceCollapseWarning "user");

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
