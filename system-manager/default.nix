# system-manager/default.nix
#
# The system-manager (numtide) equivalent of modules/default.nix -- the SAME
# services.nixram option surface, rendered for a non-NixOS Linux host (CachyOS
# et al.) that applies its config via system-manager instead of a real NixOS
# rebuild. Reuses the exact same levels.nix as the NixOS modules; only HOW
# each value gets applied to the running system differs.
#
# WHY THIS EXISTS: elitebook (CachyOS) already runs a real, working zswap
# profile matching this project's own defaults, applied through a hand-written
# system-manager module (infra/hosts/elitebook/memory.nix) -- because nixram
# itself had no system-manager target to import instead. This closes that gap
# for `mode = "zswap"` (the profile that box, and this project's other
# CachyOS-family targets, actually run).
#
# WHAT SYSTEM-MANAGER CANNOT DO, CONFIRMED BY READING ITS ACTUAL SOURCE
# (numtide/system-manager, nix/modules/*.nix -- not assumed):
#
#   - `boot.kernelParams` -- there is no `boot` option surface at all.
#     system-manager never touches the bootloader; kernel command-line
#     parameters (zswap.enabled, zswap.max_pool_percent, etc.) are the host's
#     own responsibility, set once, same "detect once, paste once" spirit as
#     `nixram.level` itself. See `zswapBootParamsCheck.nix` -- rather than
#     silently assume they're already correct, activation actively verifies
#     them against `/sys/module/zswap/parameters/*` and fails with the exact
#     values to set if they don't match.
#   - `boot.kernel.sysctl` -- no such option either (it is a NixOS-specific
#     abstraction over a sysctl.d file + systemd-sysctl.service, both of which
#     exist on any systemd distro). Rendered instead as a plain
#     `environment.etc."sysctl.d/*.conf"` file, which IS supported, plus a
#     bridge unit that re-triggers systemd-sysctl.service when the file
#     changes (systemd-sysctl only runs at boot otherwise) -- the exact
#     pattern elitebook's own hand-written memory.nix already proved out.
#   - `services.zram-generator` -- a NixOS-specific systemd-generator
#     integration, not vendored here. `mode = "zram"` is therefore NOT
#     supported under this backend at all (see the assertion below) --
#     use the NixOS module for a zram target.
#   - Toggling whether the `systemd-oomd` DAEMON runs at all
#     (`systemd.oomd.enable` in the NixOS module) -- system-manager has no
#     such option. Assumed already running via the distro's own defaults
#     (true on every CachyOS/Arch box checked so far); this backend only
#     configures the PSI thresholds it reads once armed.
#
# WHAT IT CAN DO, also confirmed directly against the source rather than
# assumed: `systemd.slices.<name>.sliceConfig` renders through the identical
# nixpkgs `systemdUtils` code NixOS itself uses -- so the oomd slice
# configuration (modules/oomd.nix's whole approach) ports over almost
# verbatim. `systemd.tmpfiles.rules` is the exact same option NixOS has (used
# here for the MGLRU min_ttl_ms rule). `environment.etc.<path>.text` +
# `replaceExisting` is how elitebook's memory.nix already writes sysctl.d
# files. `system-manager.preActivationAssertions.<name>.script` is a real,
# supported mechanism for a runtime check that fails activation outright --
# used here for the zswap-boot-params verification above.

{ lib, config, ... }:

with lib;

let
  cfg = config.services.nixram;
  levelsData = import ../levels.nix;
  inherit (levelsData) levelNames levels;

  # See modules/default.nix "EVAL SAFETY" -- the identical null-tolerance
  # pattern applies here for the identical reason.
  activeLevelName = if cfg.level != null then cfg.level else builtins.head levelNames;
  activeLevel = levels.${activeLevelName};
in
{
  imports = [
    ./sysctls.nix
    ./oomd.nix
    ./zswap-boot-params-check.nix
  ];

  options.services.nixram = {
    enable = mkEnableOption "coherent memory-pressure tuning (zswap + oomd + sysctls) for a given RAM level, on a system-manager-managed non-NixOS host";

    level = mkOption {
      type = types.nullOr (types.enum levelNames);
      default = null;
      example = "elitebook's real level, e.g. \"24G\" or \"32G\"";
      description = ''
        Same option, same fourteen anchor levels, same "no eval-time auto"
        stance as the NixOS module (`modules/default.nix`) -- see that
        module's option for the full reasoning. Run
        `nix run <nixram flake>#detect-level` on the target machine once and
        paste the result here, same as on a NixOS host.
      '';
    };

    mode = mkOption {
      type = types.enum [ "zram" "zswap" "none" ];
      default = "zswap";
      description = ''
        Same three modes as the NixOS module, but `zram` is NOT SUPPORTED
        under system-manager (see the file header) -- selecting it is a hard
        evaluation error with a message pointing at the NixOS module instead.
        Default here is `zswap`, not `zram`: every currently-known
        system-manager target (CachyOS laptops/desktops with real disk swap)
        is a zswap box, not a zram-only server.
      '';
    };

    zswap = {
      maxPoolPercent = mkOption {
        type = types.ints.between 1 100;
        default = 30;
        description = "Same option and same default as the NixOS module's `zswap.maxPoolPercent` -- see modules/default.nix for the full reasoning (elitebook's real production value, raised from the kernel's own 20).";
      };

      acceptThresholdPercent = mkOption {
        type = types.ints.between 1 100;
        default = 90;
        description = "Same option as the NixOS module -- upstream default hysteresis band.";
      };

      shrinkerEnabled = mkOption {
        type = types.bool;
        default = true;
        description = "Same option as the NixOS module -- off by default upstream (kernel >=6.8), nixram turns it on.";
      };

      diskMedium = mkOption {
        type = types.enum [ "ssd" "hdd" ];
        default = "ssd";
        description = "Same option as the NixOS module -- drives vm.page-cluster (2 for ssd, kernel default 3 for hdd).";
      };
    };

    oomd = {
      pressureLimitPercent = mkOption {
        type = types.ints.between 1 100;
        default = activeLevel.oomd.pressureLimitPercent;
        description = "Same option as the NixOS module's `oomd.enable`-gated slice config -- see modules/default.nix.";
      };

      pressureDurationSec = mkOption {
        type = types.ints.positive;
        default = activeLevel.oomd.pressureDurationSec;
        description = "Same option as the NixOS module. Overridden to a shorter duration for `mode = \"zswap\"` the same way, and for the same reason, as the NixOS module -- see modules/oomd.nix.";
      };

      protectedUnits = mkOption {
        type = types.listOf types.str;
        default = [ "sshd.service" ];
        description = ''
          Same intent as the NixOS module's `oomd.protectedUnits`, rendered
          differently: system-manager cannot set options on a FOREIGN unit
          (one it did not itself declare, e.g. a pacman-shipped sshd.service),
          so this writes a `<unit>.d/` systemd drop-in file instead of merging
          into the unit's own option tree. Same net effect
          (`OOMScoreAdjust=-900` + `ManagedOOMPreference=omit`), different
          mechanism. Name existing services only.
        '';
      };

      pressureDiagnostics.enable = mkOption {
        type = types.bool;
        default = cfg.mode == "zswap";
        description = "Same diagnostic timer as the NixOS module's `oomd.pressureDiagnostics` -- see modules/default.nix.";
      };

      pressureDiagnostics.onCalendar = mkOption {
        type = types.str;
        default = "minutely";
        description = "Same option as the NixOS module.";
      };
    };

    sysctls.enable = mkOption {
      type = types.bool;
      default = true;
      description = "Same escape hatch as the NixOS module.";
    };

    minFreeKbytesOverride = mkOption {
      type = types.nullOr types.ints.positive;
      default = null;
      description = "Same escape hatch as the NixOS module -- no level overrides this by default.";
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.level != null;
        message = ''
          services.nixram.level must be set explicitly -- same reasoning as
          the NixOS module (nix evaluation cannot read a target machine's
          live /proc/meminfo). Run `nix run <nixram flake>#detect-level` on
          the target machine once, then paste the printed
          `services.nixram.level = "...";` line into this configuration.
        '';
      }
      {
        assertion = cfg.mode != "zram";
        message = ''
          services.nixram.mode = "zram" is not supported under the
          system-manager backend: it needs `services.zram-generator`, a
          NixOS-specific systemd-generator integration system-manager does
          not vendor (confirmed by reading its actual module list -- there is
          no zram-generator module at all). Use the NixOS module
          (`nixosModules.nixram`) for a real zram target, or `mode = "zswap"`
          / `mode = "none"` here.
        '';
      }
    ];
  };
}
