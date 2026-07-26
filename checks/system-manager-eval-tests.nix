# checks/system-manager-eval-tests.nix
#
# EVAL-TIME tests for the system-manager backend (system-manager/*.nix).
# Same spirit as checks/default.nix's NixOS eval-tests -- no VM, no build:
# evaluates a real system-manager configuration via system-manager's own
# `lib.makeSystemConfig` (the same function real hosts like elitebook use)
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
        { services.nixram.enable = true; }
        extraConfig
        { nixpkgs.hostPlatform = "x86_64-linux"; }
      ];
    }).config;

  evalFails = extraConfig: !(builtins.tryEval (builtins.deepSeq (evalFor extraConfig) true)).success;

  check = name: ok: detail: { inherit name ok detail; };

  cfg-24G = evalFor { services.nixram.level = "24G"; };
  cfg-mode-none = evalFor { services.nixram.level = "24G"; services.nixram.mode = "none"; };
  cfg-override-max-pool = evalFor {
    services.nixram.level = "24G";
    services.nixram.zswap.maxPoolPercent = 40;
  };
  # A host adopting nixram's sysctls while keeping its OWN existing,
  # differently-shaped oomd setup for now (e.g. elitebook's first rollout).
  cfg-oomd-disabled = evalFor {
    services.nixram.level = "24G";
    services.nixram.oomd.enable = false;
  };

  # Proves the missing-mkDefault regression (found by review 2026-07-24,
  # fixed in system-manager/oomd.nix) stays fixed: a host must be able to
  # override just ONE slice with a plain assignment, no lib.mkForce, the
  # same escape hatch checks/default.nix's NixOS-side equivalent test
  # (override-wins/user-slice-plain-override-no-mkforce-needed) already
  # proves for the NixOS backend.
  cfg-override-user-slice = evalFor {
    services.nixram.level = "24G";
    systemd.slices."user".sliceConfig = { };
  };

  # Proves the zswap-boot-params-check regression (found by review
  # 2026-07-24: only 3 of 6 documented parameters were ever verified,
  # fixed in system-manager/zswap-boot-params-check.nix) stays fixed.
  cfg-override-accept-threshold = evalFor {
    services.nixram.level = "24G";
    services.nixram.zswap.acceptThresholdPercent = 70;
  };

  # The full richer per-unit ladder (memory ladder + restart resilience) +
  # sacrificial slice + swapUsedLimitPercent -- the 2026-07-24 "subsume the
  # whole ladder" redesign, mirrored from checks/default.nix's NixOS-side
  # cfg-override-oomd-ladder.
  cfg-override-oomd-ladder = evalFor {
    services.nixram.level = "24G";
    services.nixram.oomd.units."nixram-test-ladder.service" = {
      memoryMin = "24M";
      memoryLow = "40M";
      memoryHigh = "80M";
      memoryMax = "150M";
      oomScoreAdjust = -700;
      managedOOMPreference = "avoid";
      restartSec = "2s";
    };
    services.nixram.oomd.sacrificialSlices."nixram-test-sacrifice" = {
      memoryHigh = "256M";
      memoryMax = "320M";
      pressureLimitPercent = 60;
    };
    services.nixram.oomd.swapUsedLimitPercent = 90;
  };

  # The fully-degenerate case, mirrored from checks/default.nix's
  # cfg-override-oomd-all-null: every field explicitly opted out, including
  # the two that otherwise default non-null.
  cfg-override-oomd-all-null = evalFor {
    services.nixram.level = "24G";
    services.nixram.oomd.units."nixram-test-all-null.service" = {
      oomScoreAdjust = null;
      managedOOMPreference = null;
    };
  };

  # Proves the "unconditional on oomd.enable" contract for the memory
  # ladder / restartSec branches, mirrored from checks/default.nix's
  # cfg-oomd-disabled-with-ladder-unit.
  cfg-oomd-disabled-with-ladder-unit = evalFor {
    services.nixram.level = "24G";
    services.nixram.oomd.enable = false;
    services.nixram.oomd.units."nixram-test-disabled-ladder.service" = {
      memoryMin = "24M";
      restartSec = "2s";
    };
  };

  # Guards the root/user-slice gating fix from OVER-reaching: gating those two
  # on oomd.enable must not also gate sacrificial slices, which are
  # unconditional by design (same contract as oomd.units).
  cfg-oomd-disabled-with-sacrificial-slice = evalFor {
    services.nixram.level = "24G";
    services.nixram.oomd.enable = false;
    services.nixram.oomd.sacrificialSlices."nixram-test-sacrificial" = {
      memoryHigh = "256M";
      memoryMax = "320M";
    };
  };

  results = [
    # --- level-24G-defaults (mode = zswap) --------------------------------
    (check "sm-24G/sysctl-file-sorts-after-distro-defaults"
      # Regression guard: CachyOS ships its own conflicting sysctl values in
      # /usr/lib/sysctl.d/70-cachyos-settings.conf (confirmed live on
      # elitebook) -- systemd-sysctl's last-file-wins ordering means
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
      (evalFails { services.nixram.level = null; })
      "expected evaluation to fail (level unset) but it succeeded")

    # --- mode-zram-rejected -------------------------------------------------
    (check "sm-mode-zram/eval-fails"
      (evalFails { services.nixram.level = "24G"; services.nixram.mode = "zram"; })
      "expected evaluation to fail (mode = zram unsupported here) but it succeeded")

    # --- reserved-name collisions (2026-07-25 adversarial review) ----------
    # Mirrors checks/default.nix's NixOS-side negative tests -- before the
    # matching assertion in system-manager/default.nix, each of these
    # silently discarded the operator's config via a plain `//` merge in
    # system-manager/oomd.nix, no error at all.
    (check "sm-sacrificial-slice-reserved-name-dash/eval-fails"
      (evalFails {
        services.nixram.level = "24G";
        services.nixram.oomd.sacrificialSlices."-" = { memoryHigh = "1G"; memoryMax = "2G"; };
      })
      "expected evaluation to fail (sacrificialSlices named \"-\" collides with the root slice) but it succeeded")

    (check "sm-sacrificial-slice-reserved-name-user/eval-fails"
      (evalFails {
        services.nixram.level = "24G";
        services.nixram.oomd.sacrificialSlices."user" = { memoryHigh = "1G"; memoryMax = "2G"; };
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

    # --- override-wins (regression tests for the 2026-07-24 review fixes) --
    (check "sm-override-wins/user-slice-plain-override-no-mkforce-needed"
      (cfg-override-user-slice.systemd.slices."user".sliceConfig == { })
      "got: ${builtins.toJSON cfg-override-user-slice.systemd.slices."user".sliceConfig}")

    (check "sm-override-wins/root-slice-keeps-nixram-default-when-only-user-overridden"
      (cfg-override-user-slice.systemd.slices."-".sliceConfig.ManagedOOMMemoryPressureLimit == "60%")
      "got: ${builtins.toJSON (cfg-override-user-slice.systemd.slices."-".sliceConfig.ManagedOOMMemoryPressureLimit or null)}")

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

    # --- oomd-ladder (the 2026-07-24 "subsume the whole ladder" redesign) --
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

    # --- oomd-disabled-with-ladder-unit (2026-07-25 review) -----------------
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
