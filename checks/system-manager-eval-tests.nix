# checks/system-manager-eval-tests.nix
#
# EVAL-TIME tests for the system-manager backend (system-manager/*.nix).
# Same spirit as checks/default.nix's NixOS eval-tests -- no VM, no build:
# evaluates a real system-manager configuration via system-manager's own
# `lib.makeSystemConfig` (the same function real hosts like the reference laptop use)
# and inspects what it RENDERS into `config`/`options`. These confirm the
# module renders the right `environment.etc`/`systemd.slices`/etc entries;
# they say nothing about runtime behavior on a real activated host.

{ pkgs, systemManagerModule, systemManagerLib }:

let
  lib = pkgs.lib;

  # system-manager's own `makeSystemConfig` gates its ENTIRE return value on
  # `system.assertions` passing (`returnIfNoAssertions`, called unconditionally
  # while building `toplevel`) -- unlike NixOS's `eval-config.nix`, `.config`
  # itself is unreachable when any assertion fails; the whole call throws
  # first. This is actually a faithful match for reality (a real host's
  # `nix build .#systemConfigs.<host>` throws the same way), so the two
  # deliberately-failing configs below (level unset, mode=zram) are checked
  # via `builtins.tryEval` confirming the throw happens, not by inspecting an
  # assertions list post-hoc the way the NixOS eval-tests do.
  evalFor = extraConfig:
    (systemManagerLib.makeSystemConfig {
      modules = [
        systemManagerModule
        { nixram.enable = true; }
        extraConfig
        { nixpkgs.hostPlatform = "x86_64-linux"; }
      ];
    }).config;

  evalFails = extraConfig: !(builtins.tryEval (builtins.deepSeq (evalFor extraConfig) true)).success;

  check = name: ok: detail: { inherit name ok detail; };

  cfg-24G = evalFor { nixram.level = "24G"; };
  cfg-mode-none = evalFor { nixram.level = "24G"; nixram.mode = "none"; };
  cfg-override-max-pool = evalFor {
    nixram.level = "24G";
    nixram.zswap.maxPoolPercent = 40;
  };
  # A host adopting nixram's sysctls while keeping its OWN existing,
  # differently-shaped oomd setup for now (e.g. the reference laptop's first rollout).
  cfg-oomd-disabled = evalFor {
    nixram.level = "24G";
    nixram.oomd.enable = false;
  };

  # A host must be able to override just ONE slice with a plain assignment, no lib.mkForce --
  # the missing-mkDefault regression guard (system-manager/oomd.nix), the same escape hatch
  # checks/default.nix's NixOS-side equivalent test
  # (override-wins/user-slice-plain-override-no-mkforce-needed) already proves for that backend.
  cfg-override-user-slice = evalFor {
    nixram.level = "24G";
    systemd.slices."user".sliceConfig = { };
  };

  # This backend's equivalent of checks/default.nix's `cfg-nested-slice-field-collapse` -- see
  # that fixture's own comment for the mechanism (system-manager/oomd.nix's `"-".sliceConfig =
  # mkDefault pressureSliceConfig;` is the identical shape, so it is exposed to the identical bug).
  cfg-nested-slice-field-collapse = evalFor {
    nixram.level = "24G";
    systemd.slices."-".sliceConfig.ManagedOOMMemoryPressureLimit = "80%";
  };

  # Regression guard: every one of the six documented zswap boot params must actually be
  # verified (system-manager/zswap-boot-params-check.nix), not just a subset of them.
  cfg-override-accept-threshold = evalFor {
    nixram.level = "24G";
    nixram.zswap.acceptThresholdPercent = 70;
  };

  # The full per-unit ladder (memory ladder + restart resilience) + sacrificial slice +
  # swapUsedLimitPercent, mirrored from checks/default.nix's NixOS-side cfg-override-oomd-ladder.
  cfg-override-oomd-ladder = evalFor {
    nixram.level = "24G";
    nixram.oomd.units."nixram-test-ladder.service" = {
      memoryMin = "24M";
      memoryLow = "40M";
      memoryHigh = "80M";
      memoryMax = "150M";
      oomScoreAdjust = -700;
      managedOOMPreference = "avoid";
      restartSec = "2s";
    };
    nixram.oomd.sacrificialSlices."nixram-test-sacrifice" = {
      memoryHigh = "256M";
      memoryMax = "320M";
      pressureLimitPercent = 60;
    };
    nixram.oomd.swapUsedLimitPercent = 90;
  };

  # The fully-degenerate case, mirrored from checks/default.nix's
  # cfg-override-oomd-all-null: every field explicitly opted out, including
  # the two that otherwise default non-null.
  cfg-override-oomd-all-null = evalFor {
    nixram.level = "24G";
    nixram.oomd.units."nixram-test-all-null.service" = {
      oomScoreAdjust = null;
      managedOOMPreference = null;
    };
  };

  # Proves the "unconditional on oomd.enable" contract for the memory
  # ladder / restartSec branches, mirrored from checks/default.nix's
  # cfg-oomd-disabled-with-ladder-unit.
  cfg-oomd-disabled-with-ladder-unit = evalFor {
    nixram.level = "24G";
    nixram.oomd.enable = false;
    nixram.oomd.units."nixram-test-disabled-ladder.service" = {
      memoryMin = "24M";
      restartSec = "2s";
    };
  };

  # Guards the root/user-slice gating fix from OVER-reaching: gating those two
  # on oomd.enable must not also gate sacrificial slices, which are
  # unconditional by design (same contract as oomd.units).
  cfg-oomd-disabled-with-sacrificial-slice = evalFor {
    nixram.level = "24G";
    nixram.oomd.enable = false;
    nixram.oomd.sacrificialSlices."nixram-test-sacrificial" = {
      memoryHigh = "256M";
      memoryMax = "320M";
    };
  };

  cfg-user-memory = evalFor {
    nixram.profileSync.package.enable = true;
    nixram.dmemcg = {
      package.enable = true;
      booster.state = "disabled";
    };
  };

  cfg-dmemcg-enabled = evalFor {
    nixram.dmemcg = {
      package.enable = true;
      booster = {
        state = "enabled";
        command = "/usr/bin/dmemcg-booster --use-system-bus";
      };
    };
  };

  dmemcgEnabledWithoutCommandFails = evalFails {
    nixram.dmemcg = {
      package.enable = true;
      booster.state = "enabled";
    };
  };

  results = [
    # --- user-memory package and daemon policy ------------------------------
    (check "sm-user-memory/publishes-arch-packages"
      (cfg-user-memory.nixram.archPackages == [ "profile-sync-daemon" "dmemcg-booster" ])
      "got: ${builtins.toJSON cfg-user-memory.nixram.archPackages}")

    (check "sm-user-memory/disabled-booster-masks-foreign-unit"
      (lib.elem "dmemcg-booster-system.service" cfg-user-memory.systemd.maskedUnits)
      "got: ${builtins.toJSON cfg-user-memory.systemd.maskedUnits}")

    (check "sm-user-memory/enabled-booster-renders-service"
      (cfg-dmemcg-enabled.systemd.services.dmemcg-booster-system.serviceConfig.ExecStart
        == "/usr/bin/dmemcg-booster --use-system-bus")
      "got: ${builtins.toJSON cfg-dmemcg-enabled.systemd.services.dmemcg-booster-system}")

    (check "sm-user-memory/enabled-booster-preflights-dmem-capacity"
      (lib.hasInfix "/sys/fs/cgroup/dmem.capacity"
        cfg-dmemcg-enabled.system-manager.preActivationAssertions.dmemcg-booster-capacity.script)
      "script: ${cfg-dmemcg-enabled.system-manager.preActivationAssertions.dmemcg-booster-capacity.script}")

    (check "sm-user-memory/enabled-booster-requires-backend-command"
      dmemcgEnabledWithoutCommandFails
      "an enabled dmemcg-booster must not assume a distro binary path")

    # --- level-24G-defaults (mode = zswap) --------------------------------
    (check "sm-24G/sysctl-file-sorts-after-distro-defaults"
      # Regression guard: CachyOS ships its own conflicting sysctl values in
      # /usr/lib/sysctl.d/70-cachyos-settings.conf (confirmed live on
      # the reference laptop) -- systemd-sysctl's last-file-wins ordering means
      # anything sorting before "70" would be silently overridden. "90" is
      # not a magic number to preserve for its own sake; the REAL
      # requirement is "later than 70".
      (cfg-24G.environment.etc ? "sysctl.d/90-nixram.conf")
      "environment.etc keys: ${builtins.toJSON (builtins.attrNames cfg-24G.environment.etc)}")

    (check "sm-24G/sysctl-file-replaceExisting"
      (cfg-24G.environment.etc."sysctl.d/90-nixram.conf".replaceExisting == true)
      "got: ${builtins.toJSON (cfg-24G.environment.etc."sysctl.d/90-nixram.conf".replaceExisting or null)}")

    (check "sm-24G/sysctl-file-contains-swappiness"
      (lib.hasInfix "vm.swappiness = 25" cfg-24G.environment.etc."sysctl.d/90-nixram.conf".text)
      "text: ${cfg-24G.environment.etc."sysctl.d/90-nixram.conf".text}")

    (check "sm-24G/sysctl-file-contains-watermark"
      (lib.hasInfix "vm.watermark_scale_factor = 50" cfg-24G.environment.etc."sysctl.d/90-nixram.conf".text)
      "text: ${cfg-24G.environment.etc."sysctl.d/90-nixram.conf".text}")

    (check "sm-24G/sysctl-file-contains-page-cluster"
      (lib.hasInfix "vm.page-cluster = 2" cfg-24G.environment.etc."sysctl.d/90-nixram.conf".text)
      "text: ${cfg-24G.environment.etc."sysctl.d/90-nixram.conf".text}")

    (check "sm-24G/sysctl-file-contains-vfs-cache-pressure"
      (lib.hasInfix "vm.vfs_cache_pressure = 80" cfg-24G.environment.etc."sysctl.d/90-nixram.conf".text)
      "text: ${cfg-24G.environment.etc."sysctl.d/90-nixram.conf".text}")

    (check "sm-24G/sysctl-file-contains-overcommit-memory"
      (lib.hasInfix "vm.overcommit_memory = 1" cfg-24G.environment.etc."sysctl.d/90-nixram.conf".text)
      "text: ${cfg-24G.environment.etc."sysctl.d/90-nixram.conf".text}")

    (check "sm-24G/sysctl-file-no-admin-reserve-kbytes"
      (!(lib.hasInfix "admin_reserve_kbytes" cfg-24G.environment.etc."sysctl.d/90-nixram.conf".text))
      "text: ${cfg-24G.environment.etc."sysctl.d/90-nixram.conf".text}")

    (check "sm-24G/sysctl-file-no-user-reserve-kbytes"
      (!(lib.hasInfix "user_reserve_kbytes" cfg-24G.environment.etc."sysctl.d/90-nixram.conf".text))
      "text: ${cfg-24G.environment.etc."sysctl.d/90-nixram.conf".text}")

    (check "sm-24G/sysctl-reapply-bridge-exists"
      (cfg-24G.systemd.services ? "nixram-sysctl-reapply")
      "systemd.services keys: ${builtins.toJSON (builtins.attrNames cfg-24G.systemd.services)}")

    (check "sm-24G/tmpfiles-min-ttl-ms"
      (lib.any (r: lib.hasInfix "min_ttl_ms" r && lib.hasInfix "1000" r) cfg-24G.systemd.tmpfiles.rules)
      "rules: ${builtins.toJSON cfg-24G.systemd.tmpfiles.rules}")

    (check "sm-24G/root-slice-pressure-limit"
      (cfg-24G.systemd.slices."-".sliceConfig.ManagedOOMMemoryPressureLimit == "60%")
      "got: ${builtins.toJSON (cfg-24G.systemd.slices."-".sliceConfig.ManagedOOMMemoryPressureLimit or null)}")

    (check "sm-24G/root-slice-pressure-duration-is-zswap-3s"
      (cfg-24G.systemd.slices."-".sliceConfig.ManagedOOMMemoryPressureDurationSec == "3s")
      "got: ${builtins.toJSON (cfg-24G.systemd.slices."-".sliceConfig.ManagedOOMMemoryPressureDurationSec or null)}")

    (check "sm-24G/user-slice-pressure-limit"
      (cfg-24G.systemd.slices."user".sliceConfig.ManagedOOMMemoryPressureLimit == "60%")
      "got: ${builtins.toJSON (cfg-24G.systemd.slices."user".sliceConfig.ManagedOOMMemoryPressureLimit or null)}")

    (check "sm-24G/protected-unit-dropin-rendered"
      (cfg-24G.environment.etc ? "systemd/system/sshd.service.d/nixram-oom-protect.conf")
      "environment.etc keys: ${builtins.toJSON (builtins.attrNames cfg-24G.environment.etc)}")

    (check "sm-24G/protected-unit-dropin-content"
      (lib.hasInfix "OOMScoreAdjust=-900"
        cfg-24G.environment.etc."systemd/system/sshd.service.d/nixram-oom-protect.conf".text)
      "text: ${cfg-24G.environment.etc."systemd/system/sshd.service.d/nixram-oom-protect.conf".text}")

    (check "sm-24G/pressure-diagnostics-on-for-zswap"
      (cfg-24G.systemd.timers ? "nixram-pressure-diagnostics")
      "systemd.timers keys: ${builtins.toJSON (builtins.attrNames cfg-24G.systemd.timers)}")

    (check "sm-24G/zswap-preactivation-assertion-present"
      (cfg-24G.system-manager.preActivationAssertions ? "nixram-zswap-active"
        && cfg-24G.system-manager.preActivationAssertions.nixram-zswap-active.enable)
      "preActivationAssertions keys: ${builtins.toJSON (builtins.attrNames cfg-24G.system-manager.preActivationAssertions)}")

    # --- level-unset-assertion ---------------------------------------------
    # See the `evalFails` comment above -- makeSystemConfig throws outright
    # rather than leaving an inspectable assertions list.
    (check "sm-level-unset/eval-fails"
      (evalFails { nixram.level = null; })
      "expected evaluation to fail (level unset) but it succeeded")

    # --- mode-zram-rejected -------------------------------------------------
    (check "sm-mode-zram/eval-fails"
      (evalFails { nixram.level = "24G"; nixram.mode = "zram"; })
      "expected evaluation to fail (mode = zram unsupported here) but it succeeded")

    # --- reserved-name collisions --------------------------------------------
    # Mirrors checks/default.nix's NixOS-side negative tests: without the assertion in
    # system-manager/default.nix, a plain `//` merge in system-manager/oomd.nix would
    # silently discard the operator's config for a reserved-name slice, with no error at all.
    (check "sm-sacrificial-slice-reserved-name-dash/eval-fails"
      (evalFails {
        nixram.level = "24G";
        nixram.oomd.sacrificialSlices."-" = { memoryHigh = "1G"; memoryMax = "2G"; };
      })
      "expected evaluation to fail (sacrificialSlices named \"-\" collides with the root slice) but it succeeded")

    (check "sm-sacrificial-slice-reserved-name-user/eval-fails"
      (evalFails {
        nixram.level = "24G";
        nixram.oomd.sacrificialSlices."user" = { memoryHigh = "1G"; memoryMax = "2G"; };
      })
      "expected evaluation to fail (sacrificialSlices named \"user\" collides with the user slice) but it succeeded")

    # --- mode-none -----------------------------------------------------------
    (check "sm-mode-none/no-zswap-preactivation-assertion"
      (!(cfg-mode-none.system-manager.preActivationAssertions ? "nixram-zswap-active"
        && cfg-mode-none.system-manager.preActivationAssertions.nixram-zswap-active.enable))
      "got enable: ${builtins.toJSON (cfg-mode-none.system-manager.preActivationAssertions.nixram-zswap-active.enable or null)}")

    (check "sm-mode-none/no-swappiness-in-sysctl-file"
      (!(lib.hasInfix "vm.swappiness" cfg-mode-none.environment.etc."sysctl.d/90-nixram.conf".text))
      "text: ${cfg-mode-none.environment.etc."sysctl.d/90-nixram.conf".text}")

    (check "sm-mode-none/no-vfs-cache-pressure-in-sysctl-file"
      (!(lib.hasInfix "vfs_cache_pressure" cfg-mode-none.environment.etc."sysctl.d/90-nixram.conf".text))
      "text: ${cfg-mode-none.environment.etc."sysctl.d/90-nixram.conf".text}")

    (check "sm-mode-none/no-overcommit-memory-in-sysctl-file"
      (!(lib.hasInfix "overcommit_memory" cfg-mode-none.environment.etc."sysctl.d/90-nixram.conf".text))
      "text: ${cfg-mode-none.environment.etc."sysctl.d/90-nixram.conf".text}")

    # --- override-wins -----------------------------------------------------
    (check "sm-override-wins/max-pool-percent-in-preactivation-script"
      (lib.hasInfix "max_pool_percent 40"
        cfg-override-max-pool.system-manager.preActivationAssertions.nixram-zswap-active.script)
      "script: ${cfg-override-max-pool.system-manager.preActivationAssertions.nixram-zswap-active.script}")

    # --- oomd.enable = false (adopt sysctls, keep an existing oomd setup) ---
    # NOT DECLARED AT ALL, not merely declared-with-empty-config. On this
    # backend a declared unit becomes a standalone /etc/systemd/system/ file
    # that outranks the distro's own copy, so an "empty" -.slice / user.slice
    # silently shadowed the distro's real one (losing user.slice's
    # Before=slices.target). `? "-"` is the assertion that actually catches it;
    # the previous `sliceConfig == { }` form was satisfied BY the bug.
    (check "sm-oomd-disabled/root-slice-not-declared"
      (!(cfg-oomd-disabled.systemd.slices ? "-"))
      "slices: ${builtins.toJSON (builtins.attrNames cfg-oomd-disabled.systemd.slices)}")

    (check "sm-oomd-disabled/user-slice-not-declared"
      (!(cfg-oomd-disabled.systemd.slices ? "user"))
      "slices: ${builtins.toJSON (builtins.attrNames cfg-oomd-disabled.systemd.slices)}")

    (check "sm-oomd-disabled/sysctls-still-applied"
      (lib.hasInfix "vm.swappiness = 25" cfg-oomd-disabled.environment.etc."sysctl.d/90-nixram.conf".text)
      "text: ${cfg-oomd-disabled.environment.etc."sysctl.d/90-nixram.conf".text}")

    (check "sm-oomd-disabled/protected-units-still-applied"
      (cfg-oomd-disabled.environment.etc ? "systemd/system/sshd.service.d/nixram-oom-protect.conf")
      "environment.etc keys: ${builtins.toJSON (builtins.attrNames cfg-oomd-disabled.environment.etc)}")

    # --- override-wins (per-slice/per-param override regression guards) ----
    (check "sm-override-wins/user-slice-plain-override-no-mkforce-needed"
      (cfg-override-user-slice.systemd.slices."user".sliceConfig == { })
      "got: ${builtins.toJSON cfg-override-user-slice.systemd.slices."user".sliceConfig}")

    (check "sm-override-wins/root-slice-keeps-nixram-default-when-only-user-overridden"
      (cfg-override-user-slice.systemd.slices."-".sliceConfig.ManagedOOMMemoryPressureLimit == "60%")
      "got: ${builtins.toJSON (cfg-override-user-slice.systemd.slices."-".sliceConfig.ManagedOOMMemoryPressureLimit or null)}")

    (check "sm-override-wins/wholesale-disarm-raises-no-collapse-warning"
      (cfg-override-user-slice.warnings == [ ])
      "got: ${builtins.toJSON cfg-override-user-slice.warnings}")

    (check "sm-nested-slice-field-collapse/other-psi-fields-silently-dropped"
      (cfg-nested-slice-field-collapse.systemd.slices."-".sliceConfig
        == { ManagedOOMMemoryPressureLimit = "80%"; })
      "got: ${builtins.toJSON cfg-nested-slice-field-collapse.systemd.slices."-".sliceConfig}")

    (check "sm-nested-slice-field-collapse/is-no-longer-silent"
      (let w = cfg-nested-slice-field-collapse.warnings;
       in builtins.length w == 1
         && lib.hasInfix "ManagedOOMMemoryPressure" (builtins.head w)
         && lib.hasInfix "ManagedOOMMemoryPressureDurationSec" (builtins.head w))
      "got: ${builtins.toJSON cfg-nested-slice-field-collapse.warnings}")

    (check "sm-override-wins/accept-threshold-percent-in-preactivation-script"
      (lib.hasInfix "check_param accept_threshold_percent 70"
        cfg-override-accept-threshold.system-manager.preActivationAssertions.nixram-zswap-active.script)
      "script: ${cfg-override-accept-threshold.system-manager.preActivationAssertions.nixram-zswap-active.script}")

    # --- zswap-check-completeness ------------------------------------------
    (check "sm-zswap-check/verifies-compressor"
      (lib.hasInfix "check_param compressor zstd"
        cfg-24G.system-manager.preActivationAssertions.nixram-zswap-active.script)
      "script: ${cfg-24G.system-manager.preActivationAssertions.nixram-zswap-active.script}")

    # zpool must be checked OPTIONALLY, never with the hard `check_param`.
    # Linux 6.13 removed zbud/z3fold and the `zpool` parameter with them, so a
    # required check makes mode="zswap" unactivatable on every current kernel
    # (caught on a live 7.1-cachyos box: no /sys/module/zswap/parameters/zpool).
    (check "sm-zswap-check/verifies-zpool-optionally"
      (lib.hasInfix "check_param_optional zpool zsmalloc"
        cfg-24G.system-manager.preActivationAssertions.nixram-zswap-active.script)
      "script: ${cfg-24G.system-manager.preActivationAssertions.nixram-zswap-active.script}")

    (check "sm-zswap-check/zpool-is-not-a-hard-check"
      (!lib.hasInfix "\n    check_param zpool"
        cfg-24G.system-manager.preActivationAssertions.nixram-zswap-active.script)
      "script: ${cfg-24G.system-manager.preActivationAssertions.nixram-zswap-active.script}")

    (check "sm-zswap-check/missing-module-dir-is-its-own-error"
      (lib.hasInfix "zswap is not compiled into this kernel"
        cfg-24G.system-manager.preActivationAssertions.nixram-zswap-active.script)
      "script: ${cfg-24G.system-manager.preActivationAssertions.nixram-zswap-active.script}")

    (check "sm-zswap-check/verifies-accept-threshold-percent-default"
      (lib.hasInfix "check_param accept_threshold_percent 90"
        cfg-24G.system-manager.preActivationAssertions.nixram-zswap-active.script)
      "script: ${cfg-24G.system-manager.preActivationAssertions.nixram-zswap-active.script}")

    # --- oomd-ladder (the full per-unit memory ladder + restart resilience) --
    (check "sm-oomd-ladder/unit-dropin-service-section"
      (lib.hasInfix "MemoryMin=24M"
        cfg-override-oomd-ladder.environment.etc."systemd/system/nixram-test-ladder.service.d/nixram-oom-protect.conf".text
        && lib.hasInfix "MemoryMax=150M"
          cfg-override-oomd-ladder.environment.etc."systemd/system/nixram-test-ladder.service.d/nixram-oom-protect.conf".text
        && lib.hasInfix "OOMScoreAdjust=-700"
          cfg-override-oomd-ladder.environment.etc."systemd/system/nixram-test-ladder.service.d/nixram-oom-protect.conf".text
        && lib.hasInfix "ManagedOOMPreference=avoid"
          cfg-override-oomd-ladder.environment.etc."systemd/system/nixram-test-ladder.service.d/nixram-oom-protect.conf".text)
      "text: ${cfg-override-oomd-ladder.environment.etc."systemd/system/nixram-test-ladder.service.d/nixram-oom-protect.conf".text}")

    (check "sm-oomd-ladder/unit-dropin-memory-low-and-high"
      (lib.hasInfix "MemoryLow=40M"
        cfg-override-oomd-ladder.environment.etc."systemd/system/nixram-test-ladder.service.d/nixram-oom-protect.conf".text
        && lib.hasInfix "MemoryHigh=80M"
          cfg-override-oomd-ladder.environment.etc."systemd/system/nixram-test-ladder.service.d/nixram-oom-protect.conf".text)
      "text: ${cfg-override-oomd-ladder.environment.etc."systemd/system/nixram-test-ladder.service.d/nixram-oom-protect.conf".text}")

    (check "sm-oomd-ladder/unit-dropin-unit-section-for-restart"
      (lib.hasInfix "[Unit]"
        cfg-override-oomd-ladder.environment.etc."systemd/system/nixram-test-ladder.service.d/nixram-oom-protect.conf".text
        && lib.hasInfix "StartLimitBurst=20"
          cfg-override-oomd-ladder.environment.etc."systemd/system/nixram-test-ladder.service.d/nixram-oom-protect.conf".text
        && lib.hasInfix "StartLimitIntervalSec=5min"
          cfg-override-oomd-ladder.environment.etc."systemd/system/nixram-test-ladder.service.d/nixram-oom-protect.conf".text
        && lib.hasInfix "RestartSec=2s"
          cfg-override-oomd-ladder.environment.etc."systemd/system/nixram-test-ladder.service.d/nixram-oom-protect.conf".text)
      "text: ${cfg-override-oomd-ladder.environment.etc."systemd/system/nixram-test-ladder.service.d/nixram-oom-protect.conf".text}")

    (check "sm-oomd-ladder/sacrificial-slice-rendered"
      (cfg-override-oomd-ladder.systemd.slices."nixram-test-sacrifice".sliceConfig.MemoryMax == "320M"
        && cfg-override-oomd-ladder.systemd.slices."nixram-test-sacrifice".sliceConfig.MemoryHigh == "256M")
      "got: ${builtins.toJSON cfg-override-oomd-ladder.systemd.slices."nixram-test-sacrifice".sliceConfig}")

    (check "sm-oomd-ladder/root-slice-unaffected-by-sacrificial-slice"
      (cfg-override-oomd-ladder.systemd.slices."-".sliceConfig.ManagedOOMMemoryPressureLimit == "60%")
      "got: ${builtins.toJSON (cfg-override-oomd-ladder.systemd.slices."-".sliceConfig.ManagedOOMMemoryPressureLimit or null)}")

    # The check above alone can't discriminate a real root-slice config from
    # a same-named-collision clobber (both read "60%" -- see the identical
    # comment in checks/default.nix). ManagedOOMMemoryPressureDurationSec is
    # a field sacrificialSliceEntry never sets, so it actually distinguishes.
    (check "sm-oomd-ladder/root-slice-keeps-its-own-duration-field"
      (cfg-override-oomd-ladder.systemd.slices."-".sliceConfig.ManagedOOMMemoryPressureDurationSec == "3s")
      "got: ${builtins.toJSON (cfg-override-oomd-ladder.systemd.slices."-".sliceConfig.ManagedOOMMemoryPressureDurationSec or null)}")

    (check "sm-oomd-ladder/swap-used-limit-dropin"
      (cfg-override-oomd-ladder.environment.etc ? "systemd/oomd.conf.d/nixram-swap-used-limit.conf"
        && lib.hasInfix "SwapUsedLimit=90%"
          cfg-override-oomd-ladder.environment.etc."systemd/oomd.conf.d/nixram-swap-used-limit.conf".text)
      "environment.etc keys: ${builtins.toJSON (builtins.attrNames cfg-override-oomd-ladder.environment.etc)}")

    (check "sm-oomd-ladder/swap-used-limit-off-by-default"
      (!(cfg-24G.environment.etc ? "systemd/oomd.conf.d/nixram-swap-used-limit.conf"))
      "environment.etc keys: ${builtins.toJSON (builtins.attrNames cfg-24G.environment.etc)}")

    # --- oomd-unit-all-null (fully-degenerate case) -------------------------
    (check "sm-oomd-unit-all-null/dropin-is-service-section-only"
      (cfg-override-oomd-all-null.environment.etc."systemd/system/nixram-test-all-null.service.d/nixram-oom-protect.conf".text == "[Service]\n\n")
      "text: ${builtins.toJSON (cfg-override-oomd-all-null.environment.etc."systemd/system/nixram-test-all-null.service.d/nixram-oom-protect.conf".text or null)}")

    # --- oomd-disabled-with-ladder-unit --------------------------------------
    (check "sm-oomd-disabled/ladder-fields-still-unconditional"
      (lib.hasInfix "MemoryMin=24M"
        cfg-oomd-disabled-with-ladder-unit.environment.etc."systemd/system/nixram-test-disabled-ladder.service.d/nixram-oom-protect.conf".text
        && lib.hasInfix "RestartSec=2s"
          cfg-oomd-disabled-with-ladder-unit.environment.etc."systemd/system/nixram-test-disabled-ladder.service.d/nixram-oom-protect.conf".text
        && lib.hasInfix "StartLimitIntervalSec=5min"
          cfg-oomd-disabled-with-ladder-unit.environment.etc."systemd/system/nixram-test-disabled-ladder.service.d/nixram-oom-protect.conf".text)
      "text: ${cfg-oomd-disabled-with-ladder-unit.environment.etc."systemd/system/nixram-test-disabled-ladder.service.d/nixram-oom-protect.conf".text}")

    (check "sm-oomd-disabled/root-slice-not-declared-with-ladder-unit-present"
      (!(cfg-oomd-disabled-with-ladder-unit.systemd.slices ? "-"))
      "slices: ${builtins.toJSON (builtins.attrNames cfg-oomd-disabled-with-ladder-unit.systemd.slices)}")

    # --- sacrificial slices stay unconditional (gating-fix over-reach guard) -
    (check "sm-oomd-disabled/sacrificial-slice-still-declared"
      (cfg-oomd-disabled-with-sacrificial-slice.systemd.slices."nixram-test-sacrificial".sliceConfig.MemoryMax == "320M"
        && cfg-oomd-disabled-with-sacrificial-slice.systemd.slices."nixram-test-sacrificial".sliceConfig.ManagedOOMMemoryPressure == "kill")
      "slices: ${builtins.toJSON (builtins.attrNames cfg-oomd-disabled-with-sacrificial-slice.systemd.slices)}")

    (check "sm-oomd-disabled/sacrificial-slice-does-not-resurrect-root-slice"
      (!(cfg-oomd-disabled-with-sacrificial-slice.systemd.slices ? "-")
        && !(cfg-oomd-disabled-with-sacrificial-slice.systemd.slices ? "user"))
      "slices: ${builtins.toJSON (builtins.attrNames cfg-oomd-disabled-with-sacrificial-slice.systemd.slices)}")
  ];

  failed = builtins.filter (r: !r.ok) results;

  report = lib.concatMapStringsSep "\n"
    (r: "  - ${r.name}: ${r.detail}")
    failed;
in
if failed != [ ]
then throw ''
  nixram system-manager eval-tests FAILED (${toString (builtins.length failed)}/${toString (builtins.length results)}):
  ${report}
''
else
  pkgs.runCommand "nixram-system-manager-eval-tests"
    { passedCount = toString (builtins.length results); }
    ''
      echo "all $passedCount nixram system-manager eval tests passed"
      touch $out
    ''
