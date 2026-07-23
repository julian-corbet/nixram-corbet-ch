# system-manager/sysctls.nix
#
# The system-manager equivalent of modules/sysctls.nix. Same values, same
# reasoning (see that file and docs/rationale.md [3]/[4]/[5]/[7]) -- only the
# APPLICATION mechanism differs, because system-manager has no
# `boot.kernel.sysctl` option (that's a NixOS-specific abstraction over a
# sysctl.d file + systemd-sysctl.service; both of those exist on any systemd
# distro on their own).
#
# Rendered as a single `environment.etc."sysctl.d/90-nixram.conf"` file
# instead, `replaceExisting = true` (system-manager silently no-ops an
# `environment.etc` entry without this whenever the target path already
# exists on disk -- see infra's own knowledge/fleet/elitebook/declarative-config.md
# "Trap 1"), plus a bridge unit that re-triggers systemd-sysctl.service when
# the file's content changes. Writing the file is not applying it:
# systemd-sysctl only reads sysctl.d at boot, so without the bridge a changed
# value would sit on disk, inert, until the next reboot -- the exact pattern
# elitebook's own hand-written memory.nix already uses for this same problem.
#
# The "90" prefix is load-bearing, not cosmetic: CachyOS ships its own
# `/usr/lib/sysctl.d/70-cachyos-settings.conf` with its own swappiness/
# vfs_cache_pressure values -- confirmed live on elitebook, not assumed.
# systemd-sysctl applies sysctl.d files in lexical order and the LAST one
# wins for any given key, so a file sorting before 70 would be silently
# overridden by the distro default, defeating this whole layer with no
# error. elitebook's own memory.nix already discovered this the hard way
# (its own files are numbered 90/95/99 for exactly this reason) -- 90
# here matches that same, already-proven-necessary convention.
#
# Only the ZSWAP-mode values apply here (`mode = "zram"` is rejected outright
# by the assertion in default.nix, so its own sysctl set -- reluctant-tier
# swappiness=10 + the relief valve -- never applies under this backend; there
# is no relief-valve mechanism for zswap mode in the NixOS module either, so
# nothing is lost by that split).

{ lib, config, ... }:

with lib;

let
  cfg = config.services.nixram;
  levelsData = import ../levels.nix;
  inherit (levelsData) levelNames levels;

  activeLevelName = if cfg.level != null then cfg.level else builtins.head levelNames;
  activeLevel = levels.${activeLevelName};

  # Same values, same "directed" honesty tag, same source as
  # modules/sysctls.nix's zswapSwappiness/zswapWatermarkScaleFactor -- kept
  # as a separate literal here rather than imported, because the two option
  # trees (NixOS module system vs. system-manager's) cannot cleanly share a
  # `let` binding across files; see docs/rationale.md [3]/[5] for the single
  # source of truth these two copies must never drift from.
  zswapSwappiness = 25;
  zswapWatermarkScaleFactor = 50;
  zswapPageCluster = if cfg.zswap.diskMedium == "ssd" then 2 else null;

  # Same values, same reasoning, same "zswap-only, no zram equivalent" split
  # as modules/sysctls.nix's identically-named bindings -- see that file for
  # the full writeup, including why admin_reserve_kbytes/user_reserve_kbytes
  # are deliberately NOT set anywhere in this project (dead under
  # overcommit_memory=1, which is what this actually sets).
  zswapVfsCachePressure = 80;
  zswapOvercommitMemory = 1;

  finalMinFreeKbytes =
    if cfg.minFreeKbytesOverride != null
    then cfg.minFreeKbytesOverride
    else activeLevel.minFreeKbytesOverride;

  sysctlLines = lib.concatStringsSep "\n" (
    [
      "vm.watermark_boost_factor = 0" # sourced -- rationale.md [5]
      "vm.watermark_scale_factor = ${toString zswapWatermarkScaleFactor}" # directed -- elitebook's real production value
    ]
    ++ (
      if cfg.mode == "zswap" then
        [
          "vm.swappiness = ${toString zswapSwappiness}" # directed -- rationale.md [3]
          "vm.vfs_cache_pressure = ${toString zswapVfsCachePressure}" # directed -- elitebook's real value
          "vm.overcommit_memory = ${toString zswapOvercommitMemory}" # directed -- elitebook's real value
        ]
        ++ optional (zswapPageCluster != null) "vm.page-cluster = ${toString zswapPageCluster}"
      else
        [ ] # mode = "none": no swap-medium opinion, matches modules/sysctls.nix
    )
    ++ optional (finalMinFreeKbytes != null) "vm.min_free_kbytes = ${toString finalMinFreeKbytes}"
  );
in
{
  config = mkIf (cfg.enable && cfg.sysctls.enable) {
    environment.etc."sysctl.d/90-nixram.conf" = {
      replaceExisting = true;
      text = ''
        # Managed by nixram (system-manager backend) -- do not hand-edit,
        # changes will be overwritten on the next activation.
        ${sysctlLines}
      '';
    };

    # Bridge pattern: system-manager only restarts a unit when ITS OWN store
    # path moves, and does not restart foreign units or notice that an
    # `environment.etc` file a unit merely reads has changed. restartTriggers
    # renders the sysctl file's store path INTO this unit, so this unit's own
    # path moves whenever the file's content changes -- exactly the diff the
    # engine acts on. Same pattern as elitebook's own memory.nix
    # `sysctl-reapply` unit.
    systemd.services.nixram-sysctl-reapply = {
      description = "Re-apply /etc/sysctl.d/90-nixram.conf after a declarative change (systemd-sysctl is boot-only)";
      wantedBy = [ "multi-user.target" ];
      restartTriggers = [ config.environment.etc."sysctl.d/90-nixram.conf".source ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "/usr/bin/systemctl restart systemd-sysctl.service";
      };
    };

    # MGLRU min_ttl_ms -- systemd.tmpfiles.rules IS a real, fully-supported
    # system-manager option (confirmed by reading nix/modules/tmpfiles.nix:
    # identical type and rendering to the NixOS module), so this one line
    # ports over completely unchanged from modules/sysctls.nix.
    systemd.tmpfiles.rules = [
      "w /sys/kernel/mm/lru_gen/min_ttl_ms - - - - ${toString activeLevel.mglruMinTtlMs}"
    ];
  };
}
