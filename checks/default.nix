# checks/default.nix
#
# EVAL-TIME tests for the nixram NixOS module. No VM, no build: every
# test evaluates a full NixOS configuration (nixram needs the real
# NixOS option tree -- services.zram-generator, systemd.*, boot.* --
# not a bare `evalModules` over nixram's own options alone) and then
# inspects what the module RENDERS into `config`. These check the
# module's output values, never runtime behavior on a booted machine.

{ pkgs, nixpkgs, nixramModule }:

let
  lib = pkgs.lib;

  # Evaluate nixram (always enabled) plus whatever `extraConfig` a test
  # needs, against a minimal-but-complete NixOS configuration. Only the
  # specific attributes each test inspects get forced below -- never
  # `config.system.build.toplevel`.
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

  # One test result. `detail` is only read when `ok == false` (in the
  # failure report below), but it's always a plain string here so
  # forcing it is never a surprise.
  check = name: ok: detail: { inherit name ok detail; };

  cfg-4G = evalFor { services.nixram.level = "4G"; };
  cfg-256M = evalFor { services.nixram.level = "256M"; };
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

  results = [
    # --- level-4G-defaults ------------------------------------------------
    (check "level-4G-defaults/zram0-settings"
      (cfg-4G.services.zram-generator.settings.zram0 == {
        zram-size = "ram";
        zram-resident-limit = "ram * 35 / 100";
        compression-algorithm = "zstd zstd(level=12) (type=idle)";
        swap-priority = 100;
      })
      "got: ${builtins.toJSON cfg-4G.services.zram-generator.settings.zram0}")

    (check "level-4G-defaults/sysctl-swappiness"
      (cfg-4G.boot.kernel.sysctl."vm.swappiness" == 180)
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
      ((cfg-4G.systemd.timers.nixram-zram-recompress.timerConfig.OnCalendar or null) == "daily")
      "got: ${builtins.toJSON (cfg-4G.systemd.timers.nixram-zram-recompress.timerConfig.OnCalendar or null)}")

    # --- level-256M ---------------------------------------------------------
    (check "level-256M/compression-algorithm-no-idle-tier"
      (cfg-256M.services.zram-generator.settings.zram0.compression-algorithm == "zstd(level=1)")
      "got: ${builtins.toJSON cfg-256M.services.zram-generator.settings.zram0.compression-algorithm}")

    (check "level-256M/oomd-disabled"
      (cfg-256M.systemd.oomd.enable == false)
      "got: ${builtins.toJSON cfg-256M.systemd.oomd.enable}")

    (check "level-256M/root-slice-empty"
      (cfg-256M.systemd.slices."-".sliceConfig == { })
      "got: ${builtins.toJSON cfg-256M.systemd.slices."-".sliceConfig}")

    (check "level-256M/no-recompress-timer"
      (!(cfg-256M.systemd.timers ? "nixram-zram-recompress"))
      "systemd.timers keys: ${builtins.toJSON (builtins.attrNames cfg-256M.systemd.timers)}")

    (check "level-256M/watermark-scale-factor"
      (cfg-256M.boot.kernel.sysctl."vm.watermark_scale_factor" == 200)
      "got: ${builtins.toJSON (cfg-256M.boot.kernel.sysctl."vm.watermark_scale_factor" or null)}")

    (check "level-256M/sshd-still-protected"
      (cfg-256M.systemd.services.sshd.serviceConfig.OOMScoreAdjust == -900)
      "got: ${builtins.toJSON (cfg-256M.systemd.services.sshd.serviceConfig.OOMScoreAdjust or null)}")

    # --- level-128G-no-resident-limit ---------------------------------------
    (check "level-128G-no-resident-limit/no-resident-limit-attr"
      (!(cfg-128G.services.zram-generator.settings.zram0 ? "zram-resident-limit"))
      "zram0: ${builtins.toJSON cfg-128G.services.zram-generator.settings.zram0}")

    (check "level-128G-no-resident-limit/zram-size"
      (cfg-128G.services.zram-generator.settings.zram0.zram-size == "min(ram / 2, 16384)")
      "got: ${builtins.toJSON cfg-128G.services.zram-generator.settings.zram0.zram-size}")

    (check "level-128G-no-resident-limit/watermark-scale-factor"
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

    # --- mode-zswap ------------------------------------------------------
    (check "mode-zswap/kernel-params"
      (lib.all (p: lib.elem p cfg-mode-zswap.boot.kernelParams) [
        "zswap.enabled=1"
        "zswap.compressor=zstd"
        "zswap.zpool=zsmalloc"
        "zswap.max_pool_percent=20"
        "zswap.accept_threshold_percent=90"
        "zswap.shrinker_enabled=1"
      ])
      "kernelParams: ${builtins.toJSON cfg-mode-zswap.boot.kernelParams}")

    (check "mode-zswap/sysctl-swappiness"
      (cfg-mode-zswap.boot.kernel.sysctl."vm.swappiness" == 120)
      "got: ${builtins.toJSON (cfg-mode-zswap.boot.kernel.sysctl."vm.swappiness" or null)}")

    (check "mode-zswap/sysctl-page-cluster"
      (cfg-mode-zswap.boot.kernel.sysctl."vm.page-cluster" == 2)
      "got: ${builtins.toJSON (cfg-mode-zswap.boot.kernel.sysctl."vm.page-cluster" or null)}")

    (check "mode-zswap/sysctl-watermark-scale-factor"
      (cfg-mode-zswap.boot.kernel.sysctl."vm.watermark_scale_factor" == 125)
      "got: ${builtins.toJSON (cfg-mode-zswap.boot.kernel.sysctl."vm.watermark_scale_factor" or null)}")

    (check "mode-zswap/no-zram0"
      (!(cfg-mode-zswap.services.zram-generator.settings ? "zram0"))
      "settings keys: ${builtins.toJSON (builtins.attrNames cfg-mode-zswap.services.zram-generator.settings)}")

    # --- level-unset-assertion -----------------------------------------
    (check "level-unset-assertion/assertion-present"
      (lib.any (a: a.assertion == false && lib.hasInfix "detect-level" a.message) cfg-level-unset.assertions)
      "assertions: ${builtins.toJSON (map (a: { inherit (a) assertion message; }) cfg-level-unset.assertions)}")

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
  ];

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
}
