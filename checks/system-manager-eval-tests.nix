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

  results = [
    # --- level-24G-defaults (mode = zswap) --------------------------------
    (check "sm-24G/sysctl-file-replaceExisting"
      (cfg-24G.environment.etc."sysctl.d/60-nixram.conf".replaceExisting == true)
      "got: ${builtins.toJSON (cfg-24G.environment.etc."sysctl.d/60-nixram.conf".replaceExisting or null)}")

    (check "sm-24G/sysctl-file-contains-swappiness"
      (lib.hasInfix "vm.swappiness = 25" cfg-24G.environment.etc."sysctl.d/60-nixram.conf".text)
      "text: ${cfg-24G.environment.etc."sysctl.d/60-nixram.conf".text}")

    (check "sm-24G/sysctl-file-contains-watermark"
      (lib.hasInfix "vm.watermark_scale_factor = 50" cfg-24G.environment.etc."sysctl.d/60-nixram.conf".text)
      "text: ${cfg-24G.environment.etc."sysctl.d/60-nixram.conf".text}")

    (check "sm-24G/sysctl-file-contains-page-cluster"
      (lib.hasInfix "vm.page-cluster = 2" cfg-24G.environment.etc."sysctl.d/60-nixram.conf".text)
      "text: ${cfg-24G.environment.etc."sysctl.d/60-nixram.conf".text}")

    (check "sm-24G/sysctl-file-contains-vfs-cache-pressure"
      (lib.hasInfix "vm.vfs_cache_pressure = 80" cfg-24G.environment.etc."sysctl.d/60-nixram.conf".text)
      "text: ${cfg-24G.environment.etc."sysctl.d/60-nixram.conf".text}")

    (check "sm-24G/sysctl-file-contains-overcommit-memory"
      (lib.hasInfix "vm.overcommit_memory = 1" cfg-24G.environment.etc."sysctl.d/60-nixram.conf".text)
      "text: ${cfg-24G.environment.etc."sysctl.d/60-nixram.conf".text}")

    (check "sm-24G/sysctl-file-no-admin-reserve-kbytes"
      (!(lib.hasInfix "admin_reserve_kbytes" cfg-24G.environment.etc."sysctl.d/60-nixram.conf".text))
      "text: ${cfg-24G.environment.etc."sysctl.d/60-nixram.conf".text}")

    (check "sm-24G/sysctl-file-no-user-reserve-kbytes"
      (!(lib.hasInfix "user_reserve_kbytes" cfg-24G.environment.etc."sysctl.d/60-nixram.conf".text))
      "text: ${cfg-24G.environment.etc."sysctl.d/60-nixram.conf".text}")

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

    # --- mode-none -----------------------------------------------------------
    (check "sm-mode-none/no-zswap-preactivation-assertion"
      (!(cfg-mode-none.system-manager.preActivationAssertions ? "nixram-zswap-active"
        && cfg-mode-none.system-manager.preActivationAssertions.nixram-zswap-active.enable))
      "got enable: ${builtins.toJSON (cfg-mode-none.system-manager.preActivationAssertions.nixram-zswap-active.enable or null)}")

    (check "sm-mode-none/no-swappiness-in-sysctl-file"
      (!(lib.hasInfix "vm.swappiness" cfg-mode-none.environment.etc."sysctl.d/60-nixram.conf".text))
      "text: ${cfg-mode-none.environment.etc."sysctl.d/60-nixram.conf".text}")

    (check "sm-mode-none/no-vfs-cache-pressure-in-sysctl-file"
      (!(lib.hasInfix "vfs_cache_pressure" cfg-mode-none.environment.etc."sysctl.d/60-nixram.conf".text))
      "text: ${cfg-mode-none.environment.etc."sysctl.d/60-nixram.conf".text}")

    (check "sm-mode-none/no-overcommit-memory-in-sysctl-file"
      (!(lib.hasInfix "overcommit_memory" cfg-mode-none.environment.etc."sysctl.d/60-nixram.conf".text))
      "text: ${cfg-mode-none.environment.etc."sysctl.d/60-nixram.conf".text}")

    # --- override-wins -----------------------------------------------------
    (check "sm-override-wins/max-pool-percent-in-preactivation-script"
      (lib.hasInfix "max_pool_percent 40"
        cfg-override-max-pool.system-manager.preActivationAssertions.nixram-zswap-active.script)
      "script: ${cfg-override-max-pool.system-manager.preActivationAssertions.nixram-zswap-active.script}")
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
