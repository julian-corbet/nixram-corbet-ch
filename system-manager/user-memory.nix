# User-visible memory policy for system-manager hosts.
#
# The base nixram module intentionally stays independent of package managers:
# system-manager configures systemd and files, while nixarch reconciles pacman
# packages. This module therefore publishes package names through
# `nixram.archPackages`; a consumer joins that list to its own Arch backend.

{ lib, config, ... }:

let
  cfg = config.nixram;
in
{
  options.nixram = {
    profileSync.package.enable = lib.mkEnableOption "the Arch profile-sync-daemon package";

    dmemcg = {
      package.enable = lib.mkEnableOption "the Arch dmemcg-booster package";

      booster.state = lib.mkOption {
        type = lib.types.enum [ "unmanaged" "disabled" "enabled" ];
        default = "unmanaged";
        description = ''
          Desired state of dmemcg-booster's system daemon. `unmanaged` leaves
          the distro unit alone, `disabled` masks it, and `enabled` renders
          the daemon as a managed service after a runtime preflight proves
          that the current cgroup root exposes `dmem.capacity`.

          The preflight matters for containers: a namespaced cgroup root can
          expose `dmem.current` and `dmem.max` while hiding the capacity file
          the upstream booster requires to calculate its limits.
        '';
      };

      booster.command = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "/usr/bin/dmemcg-booster --use-system-bus";
        description = ''
          Command for the system daemon, supplied by the host's package
          backend. It is required only when `state = "enabled"`; keeping it
          unset lets this reusable module avoid assuming a distro binary
          path.
        '';
      };
    };

    archPackages = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      readOnly = true;
      description = "Selected Arch package names for a host reconciler to consume.";
    };
  };

  config = {
    assertions = [
      {
        assertion = cfg.dmemcg.booster.state != "enabled" || cfg.dmemcg.package.enable;
        message = "nixram.dmemcg.booster.state = \"enabled\" requires nixram.dmemcg.package.enable = true.";
      }
      {
        assertion = cfg.dmemcg.booster.state != "enabled" || cfg.dmemcg.booster.command != null;
        message = "nixram.dmemcg.booster.state = \"enabled\" requires nixram.dmemcg.booster.command from the host package backend.";
      }
    ];

    nixram.archPackages = lib.unique (
      lib.optional cfg.profileSync.package.enable "profile-sync-daemon"
      ++ lib.optional cfg.dmemcg.package.enable "dmemcg-booster"
    );

    # A foreign package unit is not disabled by `systemd.services.<name>.enable
    # = false` under system-manager. Mask it explicitly, which is also what
    # makes the desired disabled state survive package reinstalls.
    systemd.maskedUnits = lib.optional (cfg.dmemcg.booster.state == "disabled")
      "dmemcg-booster-system.service";

    system-manager.preActivationAssertions.dmemcg-booster-capacity =
      lib.mkIf (cfg.dmemcg.booster.state == "enabled") {
        script = ''
          if [ ! -r /sys/fs/cgroup/dmem.capacity ]; then
            echo "nixram: dmemcg-booster requires /sys/fs/cgroup/dmem.capacity at this cgroup root; refusing to enable a daemon that cannot calculate limits" >&2
            exit 1
          fi
        '';
      };

    systemd.services.dmemcg-booster-system = lib.mkIf (cfg.dmemcg.booster.state == "enabled") {
      description = "dmem cgroup foreground-game booster (nixram)";
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        ExecStart = cfg.dmemcg.booster.command;
        Restart = "always";
        RestartSec = "5s";
      };
    };
  };
}
