# Evaluation tests for the user-memory extension.
#
# The Home Manager surface is deliberately stubbed instead of adding
# home-manager as a flake input. These tests prove the files and units nixram
# emits; the consumer's real Home Manager evaluation proves the final renderer.

{ pkgs, nixpkgs, homeModule }:

let
  lib = nixpkgs.lib;

  homeStub = { lib, ... }: {
    options = {
      assertions = lib.mkOption { type = lib.types.listOf lib.types.unspecified; default = [ ]; };
      home.packages = lib.mkOption { type = lib.types.listOf lib.types.unspecified; default = [ ]; };
      xdg.configFile = lib.mkOption { type = lib.types.attrsOf lib.types.unspecified; default = { }; };
      systemd.user.services = lib.mkOption { type = lib.types.attrsOf lib.types.unspecified; default = { }; };
      systemd.user.timers = lib.mkOption { type = lib.types.attrsOf lib.types.unspecified; default = { }; };
    };
  };

  evalFor = extraConfig:
    (lib.evalModules {
      specialArgs = { inherit pkgs; };
      modules = [ homeModule homeStub extraConfig ];
    }).config;

  enabled = evalFor {
    nixram.profileSync = {
      service.enable = true;
      command = "/usr/bin/profile-sync-daemon";
      browsers = [ "firefox" ];
      resyncInterval = "30min";
      backupLimit = 3;
    };
    nixram.dmemcg.booster = {
      state = "enabled";
      command = "/usr/bin/dmemcg-booster";
    };
  };

  enabledWithNixpkgs = evalFor {
    nixram.profileSync = {
      service.enable = true;
      browsers = [ "firefox" ];
    };
  };

  disabledDmem = evalFor {
    nixram.dmemcg.booster.state = "disabled";
  };

  invalidProfile = evalFor {
    nixram.profileSync = {
      service.enable = true;
      command = "/usr/bin/profile-sync-daemon";
    };
  };

  check = name: ok: detail: { inherit name ok detail; };

  results = [
    (check "profile-sync/writes-explicit-browser-list"
      (lib.hasInfix "BROWSERS=( 'firefox' )" enabled.xdg.configFile."psd/psd.conf".text
        && lib.hasInfix "BACKUP_LIMIT=3" enabled.xdg.configFile."psd/psd.conf".text)
      "text: ${enabled.xdg.configFile."psd/psd.conf".text}")

    (check "profile-sync/renders-arch-command-and-startup-contract"
      (enabled.systemd.user.services.psd.Service.ExecStart == "/usr/bin/profile-sync-daemon startup"
        && enabled.systemd.user.services.psd.Service.ExecStop == "/usr/bin/profile-sync-daemon unsync"
        && enabled.systemd.user.services.psd.Install.WantedBy == [ "default.target" ])
      "service: ${builtins.toJSON enabled.systemd.user.services.psd}")

    (check "profile-sync/defaults-to-nixpkgs-on-a-home-manager-host"
      (lib.elem pkgs.profile-sync-daemon enabledWithNixpkgs.home.packages
        && enabledWithNixpkgs.systemd.user.services.psd.Service.ExecStart
          == "${pkgs.profile-sync-daemon}/bin/profile-sync-daemon startup")
      "service: ${builtins.toJSON enabledWithNixpkgs.systemd.user.services.psd}")

    (check "profile-sync/renders-periodic-resync"
      (enabled.systemd.user.timers.psd-resync.Timer.OnUnitActiveSec == "30min"
        && enabled.systemd.user.timers.psd-resync.Install.WantedBy == [ "timers.target" ])
      "timer: ${builtins.toJSON enabled.systemd.user.timers.psd-resync}")

    (check "profile-sync/rejects-implicit-browser-autoselection"
      (builtins.any (a: !a.assertion) invalidProfile.assertions)
      "assertions: ${builtins.toJSON invalidProfile.assertions}")

    (check "dmemcg/enabled-renders-graphical-session-unit"
      (enabled.systemd.user.services.dmemcg-booster-user.Service.ExecStart == "/usr/bin/dmemcg-booster"
        && enabled.systemd.user.services.dmemcg-booster-user.Install.WantedBy == [ "graphical-session-pre.target" ])
      "service: ${builtins.toJSON enabled.systemd.user.services.dmemcg-booster-user}")

    (check "dmemcg/disabled-shadows-a-stale-vendor-user-unit"
      (disabledDmem.systemd.user.services.dmemcg-booster-user.Unit.ConditionPathExists
        == "/run/nixram/dmemcg-booster-user-enabled")
      "service: ${builtins.toJSON disabledDmem.systemd.user.services.dmemcg-booster-user}")
  ];

  failed = builtins.filter (r: !r.ok) results;
  report = lib.concatMapStringsSep "\n" (r: "  - ${r.name}: ${r.detail}") failed;
in
if failed != [ ]
then throw ''
  nixram user-memory eval tests FAILED (${toString (builtins.length failed)}/${toString (builtins.length results)}):
  ${report}
''
else
  pkgs.runCommand "nixram-user-memory-eval-tests"
    { passedCount = toString (builtins.length results); }
    ''
      echo "all $passedCount nixram user-memory eval tests passed"
      touch $out
    ''
