# modules/lean-activation.nix
#
# Shed named tenant units for a short window around a REAL nix closure swap,
# so switch-to-configuration restarting the survival core does not have to
# contend with a resident tenant for the same RAM headroom at the exact
# moment activation itself is under the most pressure. This is the
# activation-time counterpart to `oomd.units`/`oomd.sacrificialSlices`
# (this module's steady-state memory-pressure protection): those two guard
# what happens once the box IS under pressure; this one avoids manufacturing
# a pressure spike in the first place, purely as a side effect of deploying.
#
# WHY THIS IS NIXRAM'S TERRITORY, NOT A DEPLOY MECHANISM: the trigger
# condition here is exclusively "does this closure swap change what's
# resident," never anything about HOW the new closure arrived (pushed,
# pulled, image-booted) -- that boundary is deliberate. A host states the
# memory fact ("these units cannot afford to be resident during an
# activation restart"); nixram is the sole owner of what that fact implies
# for the memory subsystem.
#
# Gated purely on `units != []`, independent of `nixram.enable`/`level` --
# this mechanism does not touch zram/zswap/sysctls and has nothing to say
# about a RAM anchor; a host can use it standalone.

{ lib, config, pkgs, ... }:

let
  cfg = config.nixram.leanActivation;
in
{
  options.nixram.leanActivation = {
    units = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "podman-bulwark" ];
      description = ''
        Systemd service NAMES (no trailing `.service` -- it is appended
        automatically), stopped just before a REAL closure swap and restarted
        `settleSeconds` later via a detached transient timer, so the restart
        survives the activation itself replacing the very units that would
        otherwise perform it.

        Each name is checked against the unit actually loaded on THIS box
        (`systemctl cat`) before anything is touched, and skipped silently if
        it does not exist -- so the same list is safe to share across hosts
        that do not all carry every named unit (a host that inherits a
        common policy but does not run one of the named tenants gets a
        no-op for that entry, not a failed activation).

        Detection of "a real closure swap" (as opposed to a reload/boot,
        which must never bounce these units) compares `/run/current-system`
        against `/nix/var/nix/profiles/system`, exactly like a plain
        `system.activationScripts` entry would by hand -- this module adds no
        new detection primitive, only the generic, host-portable rendering
        of the shed/restart pair.
      '';
    };

    settleSeconds = lib.mkOption {
      type = lib.types.ints.positive;
      default = 60;
      description = ''
        Delay, in seconds, between stopping a unit in `units` and restarting
        it, via a detached `systemd-run --on-active=`. Long enough for
        switch-to-configuration to finish restarting the survival core before
        the shed tenant returns and starts competing for RAM again.
      '';
    };
  };

  config = lib.mkIf (cfg.units != [ ]) {
    system.activationScripts.nixramLeanActivation = {
      supportsDryActivation = false;
      text = ''
        if [ "$(readlink -f /run/current-system 2>/dev/null)" \
             != "$(readlink -f /nix/var/nix/profiles/system 2>/dev/null)" ]; then
          for tenant in ${lib.concatStringsSep " " (map (t: "${t}.service") cfg.units)}; do
            # Only act on tenants that ACTUALLY exist as units on THIS box -- see
            # the `units` option's own description for why the same list can be
            # shared across hosts that don't all carry every named tenant.
            ${pkgs.systemd}/bin/systemctl cat "$tenant" >/dev/null 2>&1 || continue
            echo "[nixram-lean-activation] closure swap — freeing $tenant for the core restart"
            ${pkgs.systemd}/bin/systemctl stop "$tenant" 2>/dev/null || true
            ${pkgs.systemd}/bin/systemd-run --on-active=${toString cfg.settleSeconds}s \
              ${pkgs.systemd}/bin/systemctl start "$tenant" >/dev/null 2>&1 || true
          done
        fi
      '';
    };
  };
}
