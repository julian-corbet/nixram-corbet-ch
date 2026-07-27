# checks/default.nix
#
# EVAL-TIME tests for the nixram NixOS module. No VM, no build: every
# test evaluates a full NixOS configuration (nixram needs the real
# NixOS option tree -- services.zram-generator, systemd.*, boot.* --
# not a bare `evalModules` over nixram's own options alone) and then
# inspects what the module RENDERS into `config`. These check the
# module's output values, never runtime behavior on a booted machine.

{ pkgs, nixpkgs, nixramModule, systemManagerModule, systemManagerLib }:

let
  lib = pkgs.lib;
  levelsData = import ../levels.nix;

  # Evaluate nixram (always enabled) plus whatever `extraConfig` a test
  # needs, against a minimal-but-complete NixOS configuration. Only the
  # specific attributes each test inspects get forced below -- never
  # `config.system.build.toplevel`, EXCEPT in `evalFailsBuild`, which
  # exists specifically to force it.
  evalFor = extraConfig:
    (import (nixpkgs + "/nixos/lib/eval-config.nix") {
      system = "x86_64-linux";
      modules = [
        nixramModule
        { services.nixram.enable = true; }
        extraConfig
        {
          boot.loader.grub.enable = false;
          fileSystems."/" = { device = "none"; fsType = "tmpfs"; };
          system.stateVersion = "25.05";
        }
      ];
    }).config;

  # `system.build.toplevel` is where NixOS's real assertion enforcement
  # lives (`lib.asserts.checkAssertWarn` wraps it: `if <any assertion
  # failed> then throw ... else <the real derivation>`) -- reading
  # `config.assertions` itself never throws, it's a passive list. `seq`
  # (shallow, WHNF only) is enough to hit that top-level `if`/`throw`
  # without deep-forcing the entire system closure the way `deepSeq` would.
  evalFailsBuild = extraConfig:
    !(builtins.tryEval (builtins.seq (evalFor extraConfig).system.build.toplevel true)).success;

  # One test result. `detail` is only read when `ok == false` (in the
  # failure report below), but it's always a plain string here so
  # forcing it is never a surprise.
  check = name: ok: detail: { inherit name ok detail; };

  cfg-4G = evalFor { services.nixram.level = "4G"; };
  cfg-256M = evalFor { services.nixram.level = "256M"; };
  cfg-1G = evalFor { services.nixram.level = "1G"; };
  cfg-128G = evalFor { services.nixram.level = "128G"; };
  cfg-sizing-virtual = evalFor {
    services.nixram.level = "4G";
    services.nixram.zram.sizing = "virtual";
  };
  cfg-sizing-physical = evalFor {
    services.nixram.level = "4G";
    services.nixram.zram.sizing = "physical";
  };
  cfg-mode-zswap = evalFor {
    services.nixram.level = "16G";
    services.nixram.mode = "zswap";
    swapDevices = [ { device = "/dev/disk/by-label/swap"; } ];
  };
  cfg-level-unset = evalFor { services.nixram.level = null; };
  cfg-mode-none = evalFor {
    services.nixram.level = "64G";
    services.nixram.mode = "none";
  };
  cfg-override = evalFor {
    services.nixram.level = "4G";
    services.nixram.zram.diskSizeOverride = "ram / 4";
  };
  # Proves the mkDefault fix on "-.slice"/"user.slice" actually works: a
  # host can override just ONE slice with a plain assignment (no
  # lib.mkForce) while the other keeps nixram's own default -- exactly the
  # pattern a real fleet host (e2-micro) needs to preserve its own
  # incident-tuned oomd config (root slice at a custom percentage, user
  # slice deliberately left unarmed) on top of nixram.
  cfg-override-user-slice = evalFor {
    services.nixram.level = "4G";
    systemd.slices."user".sliceConfig = { };
  };

  # The remaining zram escape hatches -- diskSizeOverride is covered by
  # cfg-override above, these four were never exercised by any check.
  cfg-override-resident-limit = evalFor {
    services.nixram.level = "4G";
    services.nixram.zram.residentLimitOverride = "ram / 8";
  };
  cfg-override-priority = evalFor {
    services.nixram.level = "4G";
    services.nixram.zram.priorityOverride = 50;
  };
  cfg-override-recompression-algorithm = evalFor {
    services.nixram.level = "4G";
    services.nixram.zram.recompressionAlgorithmOverride = "zstd(level=12)";
  };
  cfg-override-compression-algorithm = evalFor {
    services.nixram.level = "4G";
    services.nixram.zram.compressionAlgorithmOverride = "lzo-rle";
  };

  # zswap's own overrides (acceptThresholdPercent/shrinkerEnabled/diskMedium)
  # and oomd's (units/minFreeKbytesOverride/pressureDiagnostics) -- none of
  # these were ever set away from their defaults by any check.
  cfg-override-zswap = evalFor {
    services.nixram.level = "16G";
    services.nixram.mode = "zswap";
    swapDevices = [ { device = "/dev/disk/by-label/swap"; } ];
    services.nixram.zswap.acceptThresholdPercent = 70;
    services.nixram.zswap.shrinkerEnabled = false;
    services.nixram.zswap.diskMedium = "hdd";
  };
  cfg-override-oomd = evalFor {
    services.nixram.level = "4G";
    services.nixram.oomd.units."nixram-test-example.service" = { };
    services.nixram.oomd.pressureDiagnostics.enable = true;
    services.nixram.minFreeKbytesOverride = 65536;
  };

  # The full richer per-unit ladder (memory ladder + restart resilience) --
  # nothing exercises a non-default oomd.units entry, or sacrificialSlices,
  # or swapUsedLimitPercent, without this.
  cfg-override-oomd-ladder = evalFor {
    services.nixram.level = "4G";
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

  # The fully-degenerate case: every field explicitly opted out, including
  # the two that otherwise default non-null (oomScoreAdjust,
  # managedOOMPreference). Nothing else exercises this -- the other two
  # oomd.units fixtures either rely on the submodule's own non-null
  # defaults (cfg-override-oomd, the implicit sshd default) or set every
  # field to a non-null value (cfg-override-oomd-ladder).
  cfg-override-oomd-all-null = evalFor {
    services.nixram.level = "4G";
    services.nixram.oomd.units."nixram-test-all-null.service" = {
      oomScoreAdjust = null;
      managedOOMPreference = null;
    };
  };

  # Proves the "unconditional on oomd.enable" contract (unitEntry's own doc
  # comment) for the memory ladder / restartSec branches specifically, not
  # just the trivial score/preference-only default unit every other
  # oomd.enable=false fixture exercises.
  cfg-oomd-disabled-with-ladder-unit = evalFor {
    services.nixram.level = "4G";
    services.nixram.oomd.enable = false;
    services.nixram.oomd.units."nixram-test-disabled-ladder.service" = {
      memoryMin = "24M";
      restartSec = "2s";
    };
  };

  # --- level-matrix ---------------------------------------------------------
  # Every one of the 14 levels, evaluated once (mode = zram, the default)
  # and cross-checked against levels.nix's own raw table. Closes a real gap
  # found by review 2026-07-24: only 8/14 levels were ever touched by any
  # eval-test in any mode/backend (a copy-paste slip in the other 6 -- 512M,
  # 6G, 8G, 10G, 12G, 32G -- could have shipped silently), only 3/14 had
  # systemd.oomd.enable asserted at all, and the 24G residentLimitExpr/
  # diskSizeExpr 25%->20% step (flagged in levels.nix's own comment as
  # "unconfirmed") had zero coverage under this backend. This is the ONE
  # place that gives every level, including any added later, coverage by
  # construction rather than by remembering to add another cfg-<level>.
  cfg-by-level = builtins.listToAttrs (map
    (name: { inherit name; value = evalFor { services.nixram.level = name; }; })
    levelsData.levelNames);

  levelMatrixChecks = lib.concatMap
    (name:
      let
        lvl = levelsData.levels.${name};
        cfg = cfg-by-level.${name};
        zram0 = cfg.services.zram-generator.settings.zram0;
        expectedCompression =
          if lvl.zram.recompressionTimerEnableByDefault && lvl.zram.recompressionAlgorithm != null
          then "${lvl.zram.compressionAlgorithm} ${lvl.zram.recompressionAlgorithm} (type=idle)"
          else lvl.zram.compressionAlgorithm;
      in
      [
        (check "level-matrix/${name}/zram-size"
          (zram0.zram-size == lvl.zram.diskSizeExpr)
          "got: ${builtins.toJSON (zram0.zram-size or null)}, expected: ${lvl.zram.diskSizeExpr}")

        (check "level-matrix/${name}/zram-resident-limit"
          ((zram0."zram-resident-limit" or null) == lvl.zram.residentLimitExpr)
          "got: ${builtins.toJSON (zram0."zram-resident-limit" or null)}, expected: ${builtins.toJSON lvl.zram.residentLimitExpr}")

        (check "level-matrix/${name}/compression-algorithm"
          (zram0.compression-algorithm == expectedCompression)
          "got: ${builtins.toJSON zram0.compression-algorithm}, expected: ${expectedCompression}")

        (check "level-matrix/${name}/swap-priority"
          (zram0.swap-priority == lvl.zram.priority)
          "got: ${builtins.toJSON zram0.swap-priority}, expected: ${builtins.toJSON lvl.zram.priority}")

        (check "level-matrix/${name}/sysctl-swappiness"
          ((cfg.boot.kernel.sysctl."vm.swappiness" or null) == lvl.swappiness)
          "got: ${builtins.toJSON (cfg.boot.kernel.sysctl."vm.swappiness" or null)}, expected: ${builtins.toJSON lvl.swappiness}")

        (check "level-matrix/${name}/sysctl-watermark-scale-factor"
          ((cfg.boot.kernel.sysctl."vm.watermark_scale_factor" or null) == lvl.watermarkScaleFactor)
          "got: ${builtins.toJSON (cfg.boot.kernel.sysctl."vm.watermark_scale_factor" or null)}, expected: ${builtins.toJSON lvl.watermarkScaleFactor}")

        (check "level-matrix/${name}/sysctl-watermark-boost-factor"
          ((cfg.boot.kernel.sysctl."vm.watermark_boost_factor" or null) == lvl.watermarkBoostFactor)
          "got: ${builtins.toJSON (cfg.boot.kernel.sysctl."vm.watermark_boost_factor" or null)}, expected: ${builtins.toJSON lvl.watermarkBoostFactor}")

        (check "level-matrix/${name}/oomd-enable"
          (cfg.systemd.oomd.enable == lvl.oomd.enable)
          "got: ${builtins.toJSON cfg.systemd.oomd.enable}, expected: ${builtins.toJSON lvl.oomd.enable}")

        (check "level-matrix/${name}/recompress-timer-presence"
          ((cfg.systemd.timers ? "nixram-zram-recompress") == lvl.zram.recompressionTimerEnableByDefault)
          "timers: ${builtins.toJSON (builtins.attrNames cfg.systemd.timers)}, expected present=${builtins.toJSON lvl.zram.recompressionTimerEnableByDefault}")

        (check "level-matrix/${name}/swappiness-relief-presence"
          ((cfg.systemd.timers ? "nixram-swappiness-relief") == lvl.swappinessReliefEnableByDefault)
          "timers: ${builtins.toJSON (builtins.attrNames cfg.systemd.timers)}, expected present=${builtins.toJSON lvl.swappinessReliefEnableByDefault}")
      ]
      ++ lib.optional lvl.oomd.enable
        (check "level-matrix/${name}/root-slice-pressure-limit"
          ((cfg.systemd.slices."-".sliceConfig.ManagedOOMMemoryPressureLimit or null) == "${toString lvl.oomd.pressureLimitPercent}%")
          "got: ${builtins.toJSON (cfg.systemd.slices."-".sliceConfig.ManagedOOMMemoryPressureLimit or null)}"))
    levelsData.levelNames;

  results = [
    # --- level-4G-defaults ------------------------------------------------
    (check "level-4G-defaults/zram-generator-actually-enabled"
      (cfg-4G.services.zram-generator.enable == true)
      "got: ${builtins.toJSON cfg-4G.services.zram-generator.enable}: settings alone are inert -- upstream gates its whole config on this flag, see modules/zram.nix")

    (check "level-4G-defaults/zram0-settings"
      (cfg-4G.services.zram-generator.settings.zram0 == {
        zram-size = "ram * 75 / 100";
        zram-resident-limit = "ram * 25 / 100";
        compression-algorithm = "lz4 zstd(level=3) (type=idle)";
        swap-priority = 100;
      })
      "got: ${builtins.toJSON cfg-4G.services.zram-generator.settings.zram0}")

    (check "level-4G-defaults/sysctl-swappiness"
      (cfg-4G.boot.kernel.sysctl."vm.swappiness" == 10)
      "got: ${builtins.toJSON (cfg-4G.boot.kernel.sysctl."vm.swappiness" or null)}")

    (check "level-4G-defaults/sysctl-page-cluster"
      (cfg-4G.boot.kernel.sysctl."vm.page-cluster" == 0)
      "got: ${builtins.toJSON (cfg-4G.boot.kernel.sysctl."vm.page-cluster" or null)}")

    (check "level-4G-defaults/sysctl-watermark-scale-factor"
      (cfg-4G.boot.kernel.sysctl."vm.watermark_scale_factor" == 150)
      "got: ${builtins.toJSON (cfg-4G.boot.kernel.sysctl."vm.watermark_scale_factor" or null)}")

    (check "level-4G-defaults/sysctl-watermark-boost-factor"
      (cfg-4G.boot.kernel.sysctl."vm.watermark_boost_factor" == 0)
      "got: ${builtins.toJSON (cfg-4G.boot.kernel.sysctl."vm.watermark_boost_factor" or null)}")

    (check "level-4G-defaults/no-min-free-kbytes"
      (!(cfg-4G.boot.kernel.sysctl ? "vm.min_free_kbytes"))
      "vm.min_free_kbytes unexpectedly present: ${builtins.toJSON (cfg-4G.boot.kernel.sysctl."vm.min_free_kbytes" or null)}")

    (check "level-4G-defaults/no-vfs-cache-pressure-on-reluctant-tier"
      (!(cfg-4G.boot.kernel.sysctl ? "vm.vfs_cache_pressure"))
      "vm.vfs_cache_pressure unexpectedly present on a reluctant tier: ${builtins.toJSON (cfg-4G.boot.kernel.sysctl."vm.vfs_cache_pressure" or null)}")

    (check "level-4G-defaults/overcommit-memory-on-reluctant-tier"
      (cfg-4G.boot.kernel.sysctl."vm.overcommit_memory" == 1)
      "got: ${builtins.toJSON (cfg-4G.boot.kernel.sysctl."vm.overcommit_memory" or null)}")

    (check "level-4G-defaults/root-slice-pressure-limit"
      (cfg-4G.systemd.slices."-".sliceConfig.ManagedOOMMemoryPressureLimit == "60%")
      "got: ${builtins.toJSON (cfg-4G.systemd.slices."-".sliceConfig.ManagedOOMMemoryPressureLimit or null)}")

    (check "level-4G-defaults/root-slice-pressure-duration"
      (cfg-4G.systemd.slices."-".sliceConfig.ManagedOOMMemoryPressureDurationSec == "30s")
      "got: ${builtins.toJSON (cfg-4G.systemd.slices."-".sliceConfig.ManagedOOMMemoryPressureDurationSec or null)}")

    (check "level-4G-defaults/user-slice-pressure-limit"
      (cfg-4G.systemd.slices."user".sliceConfig.ManagedOOMMemoryPressureLimit == "60%")
      "got: ${builtins.toJSON (cfg-4G.systemd.slices."user".sliceConfig.ManagedOOMMemoryPressureLimit or null)}")

    (check "level-4G-defaults/user-slice-pressure-duration"
      (cfg-4G.systemd.slices."user".sliceConfig.ManagedOOMMemoryPressureDurationSec == "30s")
      "got: ${builtins.toJSON (cfg-4G.systemd.slices."user".sliceConfig.ManagedOOMMemoryPressureDurationSec or null)}")

    (check "level-4G-defaults/sshd-oom-score-adjust"
      (cfg-4G.systemd.services.sshd.serviceConfig.OOMScoreAdjust == -900)
      "got: ${builtins.toJSON (cfg-4G.systemd.services.sshd.serviceConfig.OOMScoreAdjust or null)}")

    (check "level-4G-defaults/sshd-managed-oom-preference"
      (cfg-4G.systemd.services.sshd.serviceConfig.ManagedOOMPreference == "omit")
      "got: ${builtins.toJSON (cfg-4G.systemd.services.sshd.serviceConfig.ManagedOOMPreference or null)}")

    (check "level-4G-defaults/oomd-enable"
      (cfg-4G.systemd.oomd.enable == true)
      "got: ${builtins.toJSON cfg-4G.systemd.oomd.enable}")

    (check "level-4G-defaults/tmpfiles-min-ttl-ms"
      (lib.any (r: lib.hasInfix "min_ttl_ms" r && lib.hasInfix "1000" r) cfg-4G.systemd.tmpfiles.rules)
      "rules: ${builtins.toJSON cfg-4G.systemd.tmpfiles.rules}")

    (check "level-4G-defaults/recompress-timer-exists"
      (cfg-4G.systemd.timers ? "nixram-zram-recompress")
      "systemd.timers keys: ${builtins.toJSON (builtins.attrNames cfg-4G.systemd.timers)}")

    (check "level-4G-defaults/recompress-timer-oncalendar"
      ((cfg-4G.systemd.timers.nixram-zram-recompress.timerConfig.OnCalendar or null) == "*:0/15")
      "got: ${builtins.toJSON (cfg-4G.systemd.timers.nixram-zram-recompress.timerConfig.OnCalendar or null)}")

    (check "level-4G-defaults/swappiness-relief-enabled-on-reluctant-tier"
      (cfg-4G.systemd.timers ? "nixram-swappiness-relief")
      "systemd.timers keys: ${builtins.toJSON (builtins.attrNames cfg-4G.systemd.timers)}")

    (check "level-4G-defaults/swappiness-relief-interval"
      ((cfg-4G.systemd.timers.nixram-swappiness-relief.timerConfig.OnUnitActiveSec or null) == "30s")
      "got: ${builtins.toJSON (cfg-4G.systemd.timers.nixram-swappiness-relief.timerConfig.OnUnitActiveSec or null)}")

    (check "level-4G-defaults/swappiness-relief-service-exists"
      (cfg-4G.systemd.services ? "nixram-swappiness-relief")
      "systemd.services keys: ${builtins.toJSON (builtins.attrNames cfg-4G.systemd.services)}")

    # --- level-256M ---------------------------------------------------------
    (check "level-256M/compression-algorithm-zstd-alone"
      (cfg-256M.services.zram-generator.settings.zram0.compression-algorithm == "zstd(level=3)")
      "got: ${builtins.toJSON cfg-256M.services.zram-generator.settings.zram0.compression-algorithm}")

    (check "level-256M/oomd-disabled"
      (cfg-256M.systemd.oomd.enable == false)
      "got: ${builtins.toJSON cfg-256M.systemd.oomd.enable}")

    (check "level-256M/root-slice-empty"
      (cfg-256M.systemd.slices."-".sliceConfig == { })
      "got: ${builtins.toJSON cfg-256M.systemd.slices."-".sliceConfig}")

    (check "level-256M/recompress-timer-absent"
      (!(cfg-256M.systemd.timers ? "nixram-zram-recompress"))
      "systemd.timers keys: ${builtins.toJSON (builtins.attrNames cfg-256M.systemd.timers)}")

    (check "level-256M/sysctl-swappiness-eager"
      (cfg-256M.boot.kernel.sysctl."vm.swappiness" == 120)
      "got: ${builtins.toJSON (cfg-256M.boot.kernel.sysctl."vm.swappiness" or null)}")

    (check "level-256M/swappiness-relief-absent-on-dire-tier"
      (!(cfg-256M.systemd.timers ? "nixram-swappiness-relief"))
      "systemd.timers keys: ${builtins.toJSON (builtins.attrNames cfg-256M.systemd.timers)}")

    (check "level-256M/watermark-scale-factor"
      (cfg-256M.boot.kernel.sysctl."vm.watermark_scale_factor" == 200)
      "got: ${builtins.toJSON (cfg-256M.boot.kernel.sysctl."vm.watermark_scale_factor" or null)}")

    (check "level-256M/vfs-cache-pressure-on-dire-tier"
      (cfg-256M.boot.kernel.sysctl."vm.vfs_cache_pressure" == 200)
      "got: ${builtins.toJSON (cfg-256M.boot.kernel.sysctl."vm.vfs_cache_pressure" or null)}")

    (check "level-256M/no-overcommit-memory-on-dire-tier"
      (!(cfg-256M.boot.kernel.sysctl ? "vm.overcommit_memory"))
      "vm.overcommit_memory unexpectedly present on a dire tier: ${builtins.toJSON (cfg-256M.boot.kernel.sysctl."vm.overcommit_memory" or null)}")

    (check "level-256M/sshd-still-protected"
      (cfg-256M.systemd.services.sshd.serviceConfig.OOMScoreAdjust == -900)
      "got: ${builtins.toJSON (cfg-256M.systemd.services.sshd.serviceConfig.OOMScoreAdjust or null)}")

    # --- level-1G --------------------------------------------------------
    # Unified with 256M/512M's eager swappiness (rationale.md [3]) --
    # compute-boundedness, not headroom, decides architecture (row 4), and
    # 1G shares 256M/512M's "light usage, RAM-desperate" workload profile.
    (check "level-1G/compression-algorithm-zstd-alone"
      (cfg-1G.services.zram-generator.settings.zram0.compression-algorithm == "zstd(level=3)")
      "got: ${builtins.toJSON cfg-1G.services.zram-generator.settings.zram0.compression-algorithm}")

    (check "level-1G/sysctl-swappiness-eager"
      (cfg-1G.boot.kernel.sysctl."vm.swappiness" == 120)
      "got: ${builtins.toJSON (cfg-1G.boot.kernel.sysctl."vm.swappiness" or null)}")

    (check "level-1G/recompress-timer-absent"
      (!(cfg-1G.systemd.timers ? "nixram-zram-recompress"))
      "systemd.timers keys: ${builtins.toJSON (builtins.attrNames cfg-1G.systemd.timers)}")

    # --- level-128G-resident-limit -------------------------------------------
    (check "level-128G-resident-limit/resident-limit-attr"
      (cfg-128G.services.zram-generator.settings.zram0."zram-resident-limit" == "ram * 20 / 100")
      "zram0: ${builtins.toJSON cfg-128G.services.zram-generator.settings.zram0}")

    (check "level-128G-resident-limit/zram-size"
      (cfg-128G.services.zram-generator.settings.zram0.zram-size == "ram * 75 / 100")
      "got: ${builtins.toJSON cfg-128G.services.zram-generator.settings.zram0.zram-size}")

    (check "level-128G-resident-limit/watermark-scale-factor"
      (cfg-128G.boot.kernel.sysctl."vm.watermark_scale_factor" == 100)
      "got: ${builtins.toJSON (cfg-128G.boot.kernel.sysctl."vm.watermark_scale_factor" or null)}")

    # --- sizing-virtual ------------------------------------------------------
    (check "sizing-virtual/has-zram-size"
      (cfg-sizing-virtual.services.zram-generator.settings.zram0 ? "zram-size")
      "zram0: ${builtins.toJSON cfg-sizing-virtual.services.zram-generator.settings.zram0}")

    (check "sizing-virtual/no-resident-limit"
      (!(cfg-sizing-virtual.services.zram-generator.settings.zram0 ? "zram-resident-limit"))
      "zram0: ${builtins.toJSON cfg-sizing-virtual.services.zram-generator.settings.zram0}")

    # --- sizing-physical -------------------------------------------------
    (check "sizing-physical/has-resident-limit"
      (cfg-sizing-physical.services.zram-generator.settings.zram0 ? "zram-resident-limit")
      "zram0: ${builtins.toJSON cfg-sizing-physical.services.zram-generator.settings.zram0}")

    (check "sizing-physical/no-zram-size"
      (!(cfg-sizing-physical.services.zram-generator.settings.zram0 ? "zram-size"))
      "zram0: ${builtins.toJSON cfg-sizing-physical.services.zram-generator.settings.zram0}")

    # --- mode XOR is ENFORCED, not just documented -------------------------
    # The option text has always called zram and zswap "mutually exclusive",
    # but that was enforced only by not CONFIGURING both. On a kernel built
    # with CONFIG_ZSWAP_DEFAULT_ON=y, zswap is armed before userspace exists,
    # so mode="zram" produced exactly the forbidden combination -- and with
    # zram as the only swap device, zswap's writeback target is RAM itself.
    (check "mode-zram/disables-zswap-on-cmdline"
      (lib.elem "zswap.enabled=0" cfg-4G.boot.kernelParams)
      "kernelParams: ${builtins.toJSON cfg-4G.boot.kernelParams}")

    (check "mode-zram/runtime-disable-unit-exists"
      (cfg-4G.systemd.services ? "nixram-zswap-disable")
      "services: ${builtins.toJSON (builtins.attrNames cfg-4G.systemd.services)}")

    (check "mode-zram/runtime-disable-uses-only-shell-builtins"
      # No cat/awk/sed: a unit's PATH does not include coreutils for free.
      (!(lib.any (b: lib.hasInfix b cfg-4G.systemd.services."nixram-zswap-disable".script)
        [ "cat " "awk " "sed " "grep " ]))
      "script: ${cfg-4G.systemd.services."nixram-zswap-disable".script}")

    (check "mode-zram/runtime-disable-tolerates-absent-sysfs"
      (lib.hasInfix "CONFIG_ZSWAP=n" cfg-4G.systemd.services."nixram-zswap-disable".script)
      "script: ${cfg-4G.systemd.services."nixram-zswap-disable".script}")

    # mode="none" must NOT touch zswap either way -- it means "no swap-medium
    # opinion", and two real fleet hosts run mode="none" precisely to adopt
    # only the oomd layer. Silently disabling their zswap would be a
    # surprise change well outside what they opted into.
    (check "mode-none/does-not-touch-zswap"
      (!(lib.any (p: lib.hasPrefix "zswap." p) cfg-mode-none.boot.kernelParams)
        && !(cfg-mode-none.systemd.services ? "nixram-zswap-disable"))
      "kernelParams: ${builtins.toJSON cfg-mode-none.boot.kernelParams}")

    (check "mode-zswap/does-not-disable-itself"
      (!(lib.elem "zswap.enabled=0" cfg-mode-zswap.boot.kernelParams)
        && !(cfg-mode-zswap.systemd.services ? "nixram-zswap-disable"))
      "kernelParams: ${builtins.toJSON cfg-mode-zswap.boot.kernelParams}")

    # --- mode-zswap ------------------------------------------------------
    # Values here match elitebook's real production deployment, not the
    # untested upstream/Pop!_OS defaults -- rationale.md [5], [10].
    (check "mode-zswap/kernel-params"
      (lib.all (p: lib.elem p cfg-mode-zswap.boot.kernelParams) [
        "zswap.enabled=1"
        "zswap.compressor=zstd"
        "zswap.zpool=zsmalloc"
        "zswap.max_pool_percent=30"
        "zswap.accept_threshold_percent=90"
        "zswap.shrinker_enabled=1"
      ])
      "kernelParams: ${builtins.toJSON cfg-mode-zswap.boot.kernelParams}")

    (check "mode-zswap/sysctl-swappiness"
      (cfg-mode-zswap.boot.kernel.sysctl."vm.swappiness" == 25)
      "got: ${builtins.toJSON (cfg-mode-zswap.boot.kernel.sysctl."vm.swappiness" or null)}")

    (check "mode-zswap/sysctl-page-cluster"
      (cfg-mode-zswap.boot.kernel.sysctl."vm.page-cluster" == 2)
      "got: ${builtins.toJSON (cfg-mode-zswap.boot.kernel.sysctl."vm.page-cluster" or null)}")

    (check "mode-zswap/sysctl-watermark-scale-factor"
      (cfg-mode-zswap.boot.kernel.sysctl."vm.watermark_scale_factor" == 50)
      "got: ${builtins.toJSON (cfg-mode-zswap.boot.kernel.sysctl."vm.watermark_scale_factor" or null)}")

    (check "mode-zswap/sysctl-vfs-cache-pressure"
      (cfg-mode-zswap.boot.kernel.sysctl."vm.vfs_cache_pressure" == 80)
      "got: ${builtins.toJSON (cfg-mode-zswap.boot.kernel.sysctl."vm.vfs_cache_pressure" or null)}")

    (check "mode-zswap/sysctl-overcommit-memory"
      (cfg-mode-zswap.boot.kernel.sysctl."vm.overcommit_memory" == 1)
      "got: ${builtins.toJSON (cfg-mode-zswap.boot.kernel.sysctl."vm.overcommit_memory" or null)}")

    (check "mode-zswap/no-admin-reserve-kbytes"
      (!(cfg-mode-zswap.boot.kernel.sysctl ? "vm.admin_reserve_kbytes"))
      "vm.admin_reserve_kbytes unexpectedly present: ${builtins.toJSON (cfg-mode-zswap.boot.kernel.sysctl."vm.admin_reserve_kbytes" or null)}")

    (check "mode-zswap/no-user-reserve-kbytes"
      (!(cfg-mode-zswap.boot.kernel.sysctl ? "vm.user_reserve_kbytes"))
      "vm.user_reserve_kbytes unexpectedly present: ${builtins.toJSON (cfg-mode-zswap.boot.kernel.sysctl."vm.user_reserve_kbytes" or null)}")

    (check "mode-zswap/oomd-pressure-duration"
      (cfg-mode-zswap.systemd.slices."-".sliceConfig.ManagedOOMMemoryPressureDurationSec == "3s")
      "got: ${builtins.toJSON (cfg-mode-zswap.systemd.slices."-".sliceConfig.ManagedOOMMemoryPressureDurationSec or null)}")

    (check "mode-zswap/oomd-pressure-limit-unchanged"
      (cfg-mode-zswap.systemd.slices."-".sliceConfig.ManagedOOMMemoryPressureLimit == "60%")
      "got: ${builtins.toJSON (cfg-mode-zswap.systemd.slices."-".sliceConfig.ManagedOOMMemoryPressureLimit or null)}")

    (check "mode-zswap/no-zram0"
      (!(cfg-mode-zswap.services.zram-generator.settings ? "zram0"))
      "settings keys: ${builtins.toJSON (builtins.attrNames cfg-mode-zswap.services.zram-generator.settings)}")

    # --- level-unset-assertion -----------------------------------------
    (check "level-unset-assertion/assertion-present"
      (lib.any (a: a.assertion == false && lib.hasInfix "detect-level" a.message) cfg-level-unset.assertions)
      "assertions: ${builtins.toJSON (map (a: { inherit (a) assertion message; }) cfg-level-unset.assertions)}")

    # A populated `assertions` list on its own proves nothing -- NixOS's
    # real enforcement runs when `system.build.toplevel` is forced, not on
    # a bare read of `config.assertions` (a passive list). This proves the
    # documented "hard evaluation error" contract by actually forcing that
    # path, the same way a real `nixos-rebuild`/`nix build .#nixosConfigurations.<host>`
    # would.
    (check "level-unset-assertion/toplevel-build-actually-fails"
      (evalFailsBuild { services.nixram.level = null; })
      "expected forcing system.build.toplevel to fail for level=null, but it succeeded")

    # --- new-assertions (2026-07-24 review) --------------------------------
    (check "recompression-timer-requires-algorithm/eval-fails"
      (evalFailsBuild {
        services.nixram.level = "256M";
        services.nixram.zram.recompressionTimer.enable = true;
      })
      "expected forcing system.build.toplevel to fail (256M has recompressionAlgorithm=null) but it succeeded")

    (check "zram-override-wrong-mode/eval-fails"
      (evalFailsBuild {
        services.nixram.level = "16G";
        services.nixram.mode = "zswap";
        swapDevices = [ { device = "/dev/disk/by-label/swap"; } ];
        services.nixram.zram.diskSizeOverride = "ram / 4";
      })
      "expected forcing system.build.toplevel to fail (zram override set while mode=zswap) but it succeeded")

    # --- reserved-name collisions (2026-07-25 adversarial review) ----------
    # Before the assertions this proves, each of these silently discarded
    # the operator's whole config via a plain `//` merge in modules/oomd.nix
    # -- no error at all. Now a hard eval-time failure instead.
    (check "sacrificial-slice-reserved-name-dash/eval-fails"
      (evalFailsBuild {
        services.nixram.level = "4G";
        services.nixram.oomd.sacrificialSlices."-" = { memoryHigh = "1G"; memoryMax = "2G"; };
      })
      "expected forcing system.build.toplevel to fail (sacrificialSlices named \"-\" collides with the root slice) but it succeeded")

    (check "sacrificial-slice-reserved-name-user/eval-fails"
      (evalFailsBuild {
        services.nixram.level = "4G";
        services.nixram.oomd.sacrificialSlices."user" = { memoryHigh = "1G"; memoryMax = "2G"; };
      })
      "expected forcing system.build.toplevel to fail (sacrificialSlices named \"user\" collides with the user slice) but it succeeded")

    (check "sacrificial-slice-reserved-name-user-slice-suffix/eval-fails"
      (evalFailsBuild {
        services.nixram.level = "4G";
        services.nixram.oomd.sacrificialSlices."user.slice" = { memoryHigh = "1G"; memoryMax = "2G"; };
      })
      "expected forcing system.build.toplevel to fail (sacrificialSlices named \"user.slice\" normalizes to the reserved \"user\" key) but it succeeded")

    (check "oomd-unit-reserved-name-diagnostics/eval-fails"
      (evalFailsBuild {
        services.nixram.level = "4G";
        services.nixram.oomd.units."nixram-pressure-diagnostics" = { memoryMax = "200M"; };
      })
      "expected forcing system.build.toplevel to fail (oomd.units named \"nixram-pressure-diagnostics\" collides with nixram's own diagnostics service) but it succeeded")

    # --- mode-none -------------------------------------------------------
    (check "mode-none/no-zram0"
      (!(cfg-mode-none.services.zram-generator.settings ? "zram0"))
      "settings keys: ${builtins.toJSON (builtins.attrNames cfg-mode-none.services.zram-generator.settings)}")

    (check "mode-none/no-swappiness"
      (!(cfg-mode-none.boot.kernel.sysctl ? "vm.swappiness"))
      "got: ${builtins.toJSON (cfg-mode-none.boot.kernel.sysctl."vm.swappiness" or null)}")

    (check "mode-none/no-page-cluster"
      (!(cfg-mode-none.boot.kernel.sysctl ? "vm.page-cluster"))
      "got: ${builtins.toJSON (cfg-mode-none.boot.kernel.sysctl."vm.page-cluster" or null)}")

    (check "mode-none/watermark-scale-factor-still-present"
      (cfg-mode-none.boot.kernel.sysctl."vm.watermark_scale_factor" == 100)
      "got: ${builtins.toJSON (cfg-mode-none.boot.kernel.sysctl."vm.watermark_scale_factor" or null)}")

    (check "mode-none/oomd-still-enabled"
      (cfg-mode-none.systemd.oomd.enable == true)
      "got: ${builtins.toJSON cfg-mode-none.systemd.oomd.enable}")

    # --- override-wins -----------------------------------------------------
    (check "override-wins/disk-size-override"
      (cfg-override.services.zram-generator.settings.zram0.zram-size == "ram / 4")
      "got: ${builtins.toJSON cfg-override.services.zram-generator.settings.zram0.zram-size}")

    (check "override-wins/user-slice-plain-override-no-mkforce-needed"
      (cfg-override-user-slice.systemd.slices."user".sliceConfig == { })
      "got: ${builtins.toJSON cfg-override-user-slice.systemd.slices."user".sliceConfig}")

    (check "override-wins/root-slice-keeps-nixram-default-when-only-user-overridden"
      (cfg-override-user-slice.systemd.slices."-".sliceConfig.ManagedOOMMemoryPressureLimit == "60%")
      "got: ${builtins.toJSON (cfg-override-user-slice.systemd.slices."-".sliceConfig.ManagedOOMMemoryPressureLimit or null)}")

    (check "override-wins/resident-limit-override"
      (cfg-override-resident-limit.services.zram-generator.settings.zram0."zram-resident-limit" == "ram / 8")
      "got: ${builtins.toJSON (cfg-override-resident-limit.services.zram-generator.settings.zram0."zram-resident-limit" or null)}")

    (check "override-wins/priority-override"
      (cfg-override-priority.services.zram-generator.settings.zram0.swap-priority == 50)
      "got: ${builtins.toJSON cfg-override-priority.services.zram-generator.settings.zram0.swap-priority}")

    (check "override-wins/recompression-algorithm-override"
      (cfg-override-recompression-algorithm.services.zram-generator.settings.zram0.compression-algorithm == "lz4 zstd(level=12) (type=idle)")
      "got: ${builtins.toJSON cfg-override-recompression-algorithm.services.zram-generator.settings.zram0.compression-algorithm}")

    (check "override-wins/compression-algorithm-override"
      (cfg-override-compression-algorithm.services.zram-generator.settings.zram0.compression-algorithm == "lzo-rle zstd(level=3) (type=idle)")
      "got: ${builtins.toJSON cfg-override-compression-algorithm.services.zram-generator.settings.zram0.compression-algorithm}")

    (check "override-wins/zswap-accept-threshold-percent"
      (lib.elem "zswap.accept_threshold_percent=70" cfg-override-zswap.boot.kernelParams)
      "kernelParams: ${builtins.toJSON cfg-override-zswap.boot.kernelParams}")

    (check "override-wins/zswap-shrinker-disabled"
      (!(lib.any (p: lib.hasPrefix "zswap.shrinker_enabled" p) cfg-override-zswap.boot.kernelParams))
      "kernelParams: ${builtins.toJSON cfg-override-zswap.boot.kernelParams}")

    (check "override-wins/zswap-disk-medium-hdd-no-page-cluster"
      (!(cfg-override-zswap.boot.kernel.sysctl ? "vm.page-cluster"))
      "got: ${builtins.toJSON (cfg-override-zswap.boot.kernel.sysctl."vm.page-cluster" or null)}")

    (check "override-wins/oomd-protected-units-override"
      (cfg-override-oomd.systemd.services."nixram-test-example".serviceConfig.OOMScoreAdjust == -900)
      "got: ${builtins.toJSON (cfg-override-oomd.systemd.services."nixram-test-example".serviceConfig.OOMScoreAdjust or null)}")

    (check "override-wins/oomd-min-free-kbytes-override"
      (cfg-override-oomd.boot.kernel.sysctl."vm.min_free_kbytes" == 65536)
      "got: ${builtins.toJSON (cfg-override-oomd.boot.kernel.sysctl."vm.min_free_kbytes" or null)}")

    (check "override-wins/oomd-pressure-diagnostics-enable-override"
      (cfg-override-oomd.systemd.timers ? "nixram-pressure-diagnostics")
      "systemd.timers keys: ${builtins.toJSON (builtins.attrNames cfg-override-oomd.systemd.timers)}")

    # --- oomd-ladder (the 2026-07-24 "subsume the whole ladder" redesign) --
    (check "oomd-ladder/unit-memory-min"
      (cfg-override-oomd-ladder.systemd.services."nixram-test-ladder".serviceConfig.MemoryMin == "24M")
      "got: ${builtins.toJSON (cfg-override-oomd-ladder.systemd.services."nixram-test-ladder".serviceConfig.MemoryMin or null)}")

    (check "oomd-ladder/unit-memory-max"
      (cfg-override-oomd-ladder.systemd.services."nixram-test-ladder".serviceConfig.MemoryMax == "150M")
      "got: ${builtins.toJSON (cfg-override-oomd-ladder.systemd.services."nixram-test-ladder".serviceConfig.MemoryMax or null)}")

    (check "oomd-ladder/unit-memory-low"
      (cfg-override-oomd-ladder.systemd.services."nixram-test-ladder".serviceConfig.MemoryLow == "40M")
      "got: ${builtins.toJSON (cfg-override-oomd-ladder.systemd.services."nixram-test-ladder".serviceConfig.MemoryLow or null)}")

    (check "oomd-ladder/unit-memory-high"
      (cfg-override-oomd-ladder.systemd.services."nixram-test-ladder".serviceConfig.MemoryHigh == "80M")
      "got: ${builtins.toJSON (cfg-override-oomd-ladder.systemd.services."nixram-test-ladder".serviceConfig.MemoryHigh or null)}")

    (check "oomd-ladder/unit-oom-score-adjust-override"
      (cfg-override-oomd-ladder.systemd.services."nixram-test-ladder".serviceConfig.OOMScoreAdjust == -700)
      "got: ${builtins.toJSON (cfg-override-oomd-ladder.systemd.services."nixram-test-ladder".serviceConfig.OOMScoreAdjust or null)}")

    (check "oomd-ladder/unit-managed-oom-preference-override"
      (cfg-override-oomd-ladder.systemd.services."nixram-test-ladder".serviceConfig.ManagedOOMPreference == "avoid")
      "got: ${builtins.toJSON (cfg-override-oomd-ladder.systemd.services."nixram-test-ladder".serviceConfig.ManagedOOMPreference or null)}")

    (check "oomd-ladder/unit-restart-sec"
      (cfg-override-oomd-ladder.systemd.services."nixram-test-ladder".serviceConfig.RestartSec == "2s")
      "got: ${builtins.toJSON (cfg-override-oomd-ladder.systemd.services."nixram-test-ladder".serviceConfig.RestartSec or null)}")

    (check "oomd-ladder/unit-start-limit-burst"
      (cfg-override-oomd-ladder.systemd.services."nixram-test-ladder".unitConfig.StartLimitBurst == 20)
      "got: ${builtins.toJSON (cfg-override-oomd-ladder.systemd.services."nixram-test-ladder".unitConfig.StartLimitBurst or null)}")

    (check "oomd-ladder/unit-start-limit-interval-sec"
      (cfg-override-oomd-ladder.systemd.services."nixram-test-ladder".unitConfig.StartLimitIntervalSec == "5min")
      "got: ${builtins.toJSON (cfg-override-oomd-ladder.systemd.services."nixram-test-ladder".unitConfig.StartLimitIntervalSec or null)}")

    (check "oomd-ladder/sacrificial-slice-memory-max"
      (cfg-override-oomd-ladder.systemd.slices."nixram-test-sacrifice".sliceConfig.MemoryMax == "320M")
      "got: ${builtins.toJSON (cfg-override-oomd-ladder.systemd.slices."nixram-test-sacrifice".sliceConfig.MemoryMax or null)}")

    (check "oomd-ladder/sacrificial-slice-memory-high"
      (cfg-override-oomd-ladder.systemd.slices."nixram-test-sacrifice".sliceConfig.MemoryHigh == "256M")
      "got: ${builtins.toJSON (cfg-override-oomd-ladder.systemd.slices."nixram-test-sacrifice".sliceConfig.MemoryHigh or null)}")

    (check "oomd-ladder/sacrificial-slice-pressure-limit"
      (cfg-override-oomd-ladder.systemd.slices."nixram-test-sacrifice".sliceConfig.ManagedOOMMemoryPressureLimit == "60%")
      "got: ${builtins.toJSON (cfg-override-oomd-ladder.systemd.slices."nixram-test-sacrifice".sliceConfig.ManagedOOMMemoryPressureLimit or null)}")

    (check "oomd-ladder/sacrificial-slice-no-kill-priority-weighting"
      (!(cfg-override-oomd-ladder.systemd.slices."nixram-test-sacrifice".sliceConfig ? "OOMScoreAdjust"))
      "got: ${builtins.toJSON cfg-override-oomd-ladder.systemd.slices."nixram-test-sacrifice".sliceConfig}")

    (check "oomd-ladder/root-slice-unaffected-by-sacrificial-slice"
      (cfg-override-oomd-ladder.systemd.slices."-".sliceConfig.ManagedOOMMemoryPressureLimit == "60%")
      "got: ${builtins.toJSON (cfg-override-oomd-ladder.systemd.slices."-".sliceConfig.ManagedOOMMemoryPressureLimit or null)}")

    # The check above alone can't actually discriminate "root slice kept its
    # own pressureSliceConfig" from "root slice got clobbered by a same-named
    # sacrificial slice" -- both this ladder fixture's sacrificial slice AND
    # every level hardcode pressureLimitPercent=60, so both possible outcomes
    # read "60%". ManagedOOMMemoryPressureDurationSec is a field
    # sacrificialSliceEntry NEVER sets at all, so its presence (and value)
    # actually distinguishes the two: a merge collision would make it vanish.
    (check "oomd-ladder/root-slice-keeps-its-own-duration-field"
      (cfg-override-oomd-ladder.systemd.slices."-".sliceConfig.ManagedOOMMemoryPressureDurationSec == "30s")
      "got: ${builtins.toJSON (cfg-override-oomd-ladder.systemd.slices."-".sliceConfig.ManagedOOMMemoryPressureDurationSec or null)}")

    (check "oomd-ladder/swap-used-limit-off-by-default"
      (!(cfg-4G.systemd.oomd.settings.OOM or { } ? "SwapUsedLimit"))
      "got: ${builtins.toJSON (cfg-4G.systemd.oomd.settings.OOM.SwapUsedLimit or null)}")

    (check "oomd-ladder/swap-used-limit-opt-in"
      (cfg-override-oomd-ladder.systemd.oomd.settings.OOM.SwapUsedLimit == "90%")
      "got: ${builtins.toJSON (cfg-override-oomd-ladder.systemd.oomd.settings.OOM.SwapUsedLimit or null)}")

    # --- oomd-unit-all-null (fully-degenerate case) -------------------------
    (check "oomd-unit-all-null/empty-service-config"
      (cfg-override-oomd-all-null.systemd.services."nixram-test-all-null".serviceConfig == { })
      "got: ${builtins.toJSON cfg-override-oomd-all-null.systemd.services."nixram-test-all-null".serviceConfig}")

    (check "oomd-unit-all-null/no-start-limit-config"
      (!(cfg-override-oomd-all-null.systemd.services."nixram-test-all-null".unitConfig ? "StartLimitBurst"))
      "got: ${builtins.toJSON (cfg-override-oomd-all-null.systemd.services."nixram-test-all-null".unitConfig or null)}")

    # --- oomd-disabled-with-ladder-unit (2026-07-25 review) -----------------
    (check "oomd-disabled/ladder-fields-still-unconditional-memory-min"
      (cfg-oomd-disabled-with-ladder-unit.systemd.services."nixram-test-disabled-ladder".serviceConfig.MemoryMin == "24M")
      "got: ${builtins.toJSON (cfg-oomd-disabled-with-ladder-unit.systemd.services."nixram-test-disabled-ladder".serviceConfig.MemoryMin or null)}")

    (check "oomd-disabled/ladder-fields-still-unconditional-restart-sec"
      (cfg-oomd-disabled-with-ladder-unit.systemd.services."nixram-test-disabled-ladder".serviceConfig.RestartSec == "2s")
      "got: ${builtins.toJSON (cfg-oomd-disabled-with-ladder-unit.systemd.services."nixram-test-disabled-ladder".serviceConfig.RestartSec or null)}")

    (check "oomd-disabled/ladder-fields-still-unconditional-start-limit"
      (cfg-oomd-disabled-with-ladder-unit.systemd.services."nixram-test-disabled-ladder".unitConfig.StartLimitIntervalSec == "5min")
      "got: ${builtins.toJSON (cfg-oomd-disabled-with-ladder-unit.systemd.services."nixram-test-disabled-ladder".unitConfig.StartLimitIntervalSec or null)}")

    (check "oomd-disabled/root-slice-not-armed"
      (cfg-oomd-disabled-with-ladder-unit.systemd.slices."-".sliceConfig == { })
      "got: ${builtins.toJSON cfg-oomd-disabled-with-ladder-unit.systemd.slices."-".sliceConfig}")
  ]
  ++ levelMatrixChecks;

  failed = builtins.filter (r: !r.ok) results;

  report = lib.concatMapStringsSep "\n"
    (r: "  - ${r.name}: ${r.detail}")
    failed;

in
if failed != [ ]
then throw ''
  nixram eval-tests FAILED (${toString (builtins.length failed)}/${toString (builtins.length results)}):
  ${report}
''
else {
  # Constructing this derivation depends on `passedCount`, which forces
  # `results` (and therefore every `check` assertion above) even if
  # nothing else in `nix flake check` ever reads the attribute -- so the
  # tests really do run, not just get defined.
  eval-tests = pkgs.runCommand "nixram-eval-tests"
    { passedCount = toString (builtins.length results); }
    ''
      echo "all $passedCount nixram eval tests passed"
      touch $out
    '';

  # A REAL runtime test (ephemeral QEMU, nothing persists) -- eval-tests
  # above only confirm config RENDERING; this is the one exercising actual
  # kernel/systemd behavior. See checks/swappiness-relief-vm-test.nix.
  swappiness-relief-vm-test = import ./swappiness-relief-vm-test.nix {
    inherit pkgs nixpkgs nixramModule;
  };

  # Eval-time tests for the system-manager (non-NixOS) backend -- same
  # rendering-only scope as eval-tests above, via system-manager's own real
  # `lib.makeSystemConfig`. See system-manager/default.nix.
  system-manager-eval-tests = import ./system-manager-eval-tests.nix {
    inherit pkgs systemManagerModule systemManagerLib;
  };
}
