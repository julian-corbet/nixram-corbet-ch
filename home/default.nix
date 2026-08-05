# Per-user memory policy for Home Manager.
#
# system-manager has no `systemd.user.services` option. This module is the
# user-plane companion to system-manager/user-memory.nix: it owns PSD's config
# and user units, plus the user half of dmemcg-booster.

{ lib, config, pkgs, ... }:

let
  cfg = config.nixram;
  profileCfg = cfg.profileSync;
  dmemCfg = cfg.dmemcg;
  profileCommand = if profileCfg.command != null
    then profileCfg.command
    else "${pkgs.profile-sync-daemon}/bin/profile-sync-daemon";
  dmemCommand = if dmemCfg.booster.command != null
    then dmemCfg.booster.command
    else "${pkgs.coreutils}/bin/false";
  browserList = lib.concatMapStringsSep " " lib.escapeShellArg profileCfg.browsers;
in
{
  options.nixram = {
    profileSync = {
      service.enable = lib.mkEnableOption "Profile Sync Daemon for this user";

      command = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = ''
          Absolute profile-sync-daemon command. The default uses nixpkgs and
          adds that package to this Home Manager profile. A system-manager host
          with the Arch package declared through `profileSync.package.enable`
          should set this to `/usr/bin/profile-sync-daemon` instead.
        '';
      };

      browsers = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        example = [ "firefox" ];
        description = ''
          PSD browser identifiers to manage. This must be explicit whenever
          the service is enabled: leaving PSD's BROWSERS array unset makes it
          auto-select every supported browser it discovers.
        '';
      };

      resyncInterval = lib.mkOption {
        type = lib.types.str;
        default = "1h";
        description = "PSD's periodic resync interval, in systemd time-span syntax.";
      };

      backupLimit = lib.mkOption {
        type = lib.types.ints.positive;
        default = 5;
        description = "Number of PSD crash-recovery snapshots to retain.";
      };
    };

    dmemcg.booster = {
      state = lib.mkOption {
        type = lib.types.enum [ "unmanaged" "disabled" "enabled" ];
        default = "unmanaged";
        description = ''
          Desired state of the user half of dmemcg-booster. Match this with
          the system-manager plane: `disabled` shadows a previously enabled
          vendor user unit with a condition that is always false, while
          `enabled` renders the foreground-session unit declaratively.
        '';
      };

      command = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "/usr/bin/dmemcg-booster";
        description = ''
          Command for the user daemon, supplied by the host package backend.
          It is required only when `state = "enabled"`.
        '';
      };
    };
  };

  config = lib.mkMerge [
    (lib.mkIf profileCfg.service.enable {
      assertions = [
        {
          assertion = profileCfg.browsers != [ ];
          message = "nixram.profileSync.service.enable requires an explicit non-empty nixram.profileSync.browsers list.";
        }
      ];

      home.packages = lib.optional (profileCfg.command == null) pkgs.profile-sync-daemon;

      xdg.configFile."psd/psd.conf".text = ''
        # Managed by nixram. PSD snapshots this file while active; change it
        # declaratively and restart psd.service to apply a new browser set.
        BROWSERS=( ${browserList} )
        USE_BACKUPS="yes"
        BACKUP_LIMIT=${toString profileCfg.backupLimit}
      '';

      systemd.user.services = {
        psd = {
          Unit = {
            Description = "Profile Sync Daemon (nixram)";
            Documentation = [ "man:psd(1)" "man:profile-sync-daemon(1)" ];
            Wants = [ "psd-resync.timer" ];
            RequiresMountsFor = [ "/home/" ];
          };
          Service = {
            Slice = "background.slice";
            Type = "oneshot";
            RemainAfterExit = true;
            ExecStart = "${profileCommand} startup";
            ExecStartPost = "${profileCommand} resync";
            ExecStop = "${profileCommand} unsync";
            Environment = [ "LAUNCHED_BY_SYSTEMD=1" ];
          };
          Install.WantedBy = [ "default.target" ];
        };

        psd-resync = {
          Unit = {
            Description = "Timed Profile Sync Daemon resync (nixram)";
            After = [ "psd.service" ];
            PartOf = [ "psd.service" ];
          };
          Service = {
            Type = "oneshot";
            ExecStart = "${profileCommand} resync";
          };
        };
      };

      systemd.user.timers.psd-resync = {
        Unit.Description = "Timer for Profile Sync Daemon resync (nixram)";
        Timer = {
          OnUnitActiveSec = profileCfg.resyncInterval;
          Persistent = true;
        };
        Install.WantedBy = [ "timers.target" ];
      };
    })

    (lib.mkIf (dmemCfg.booster.state == "disabled") {
      # The vendor user unit may have been enabled manually. Home Manager
      # writes a higher-precedence unit with a false condition so the old
      # wants symlink becomes inert without an imperative user-session edit.
      systemd.user.services.dmemcg-booster-user = {
        Unit = {
          Description = "dmem cgroup foreground-game booster (disabled by nixram)";
          ConditionPathExists = "/run/nixram/dmemcg-booster-user-enabled";
        };
        Service.ExecStart = dmemCommand;
      };
    })

    (lib.mkIf (dmemCfg.booster.state == "enabled") {
      assertions = [
        {
          assertion = dmemCfg.booster.command != null;
          message = "nixram.dmemcg.booster.state = \"enabled\" requires nixram.dmemcg.booster.command from the host package backend.";
        }
      ];

      systemd.user.services.dmemcg-booster-user = {
        Unit.Description = "dmem cgroup foreground-game booster (nixram)";
        Service = {
          ExecStart = dmemCommand;
          Restart = "always";
          RestartSec = "5s";
        };
        Install.WantedBy = [ "graphical-session-pre.target" ];
      };
    })
  ];
}
