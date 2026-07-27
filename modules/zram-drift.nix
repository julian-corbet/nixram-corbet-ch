# modules/zram-drift.nix — notice when the RUNNING zram device stops matching the declaration.
#
# THE GAP THIS EXISTS FOR. A zram device is created once, at boot, by a systemd generator reading
# /etc/systemd/zram-generator.conf. A later `nixos-rebuild switch` rewrites that file and reloads
# units — but nothing tears down and recreates a block device that is currently active as swap, and
# nothing should: systemd will not yank swap out from under running processes.
#
# So a host can sit indefinitely in a state the Nix model has no name for: **declared correctly,
# applied never**. The switch succeeded. The config on disk is right. The device is whatever the
# last boot made it.
#
# Observed live 2026-07-27 on a 125 GiB host, 21.7 hours after a switch that had landed the same
# day: declared `zram-size = ram * 75 / 100` (94.3 GiB) with an idle-recompression pass, running
# 25.1 GiB with plain zstd and no recompression at all. A quarter of the declared capacity, and
# nothing anywhere said so.
#
# This is the same failure class as an activation that half-succeeds: the loud half worked, so it
# looked finished. nixram already enforces one invariant against live kernel state at runtime
# (`nixram-zswap-disable`, because a kernel built CONFIG_ZSWAP_DEFAULT_ON arms the thing this
# module's `mode` says is mutually exclusive). This is the same shape, applied to nixram's own
# device: compare what is declared against what the kernel actually has, and fail loudly rather
# than let a box quietly run something else.
#
# WHY IT ONLY REPORTS. It deliberately does NOT recreate the device. Doing that means `swapoff`,
# which pages everything resident back into RAM — on a box under memory pressure that is precisely
# the wrong moment to do it automatically, and memory pressure is when a wrong zram size hurts
# most. The unit tells you, and names the command; a human picks the moment.
{ lib, config, ... }:
let
  cfg = config.nixram;
  zcfg = config.services.zram-generator.settings.zram0 or { };

  declaredSize = zcfg.zram-size or null;
  declaredResident = zcfg.zram-resident-limit or null;
  declaredAlgo = zcfg.compression-algorithm or null;

  # nixram emits exactly two shapes for these expressions -- `ram`, or `ram * N / M` -- because the
  # ratio is fixed per tier group and collapses to a flat fraction (see levels.nix's own note on
  # why the pi()/3-smooth machinery is not needed at runtime). The check parses those two and
  # NOTHING else: an unrecognised expression is reported as unverifiable rather than silently
  # treated as a pass, because "I could not check" and "it matches" must never look the same.
  parseExpr = expr: ''
    parse_expr() {
      # $1: the expression. Echoes bytes, or "?" if the shape is not one we can evaluate here.
      # COMPUTE IN WHOLE MiB, the way zram-generator itself does -- its own conf.example says
      # these expressions are "as a function of MemTotal, both in MB". Doing the arithmetic in
      # bytes and comparing exactly produces a false positive on every host: on a 125 GiB box the
      # byte-exact answer misses the generator's MiB-truncated one by ~345 KB.
      local e="''${1// /}" ram_kb ram_mib
      read -r _ ram_kb _ < /proc/meminfo
      ram_mib=$(( ram_kb / 1024 ))
      case "$e" in
        ram) echo $(( ram_mib * 1048576 )) ;;
        ram\*[0-9]*/[0-9]*)
          local n="''${e#ram\*}"; local num="''${n%%/*}"; local den="''${n##*/}"
          echo $(( (ram_mib * num / den) * 1048576 )) ;;
        *) echo "?" ;;
      esac
    }
    expected=$(parse_expr ${lib.escapeShellArg expr})
  '';
in
{
  options.nixram.zram.driftCheck = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Check at boot and on every switch that the live zram device matches what this module
        declares, and fail the unit when it does not.

        On by default: the drift it catches is invisible — the switch reports success, the config
        file is correct, and only `/sys/block/zram0` disagrees. A check that has to be remembered
        and turned on would not have caught the case that motivated it.

        The check never modifies the device; see the module header for why recreating it
        automatically is the wrong behaviour.
      '';
    };

    device = lib.mkOption {
      type = lib.types.str;
      default = "zram0";
      description = "Which zram device to verify. Matches the generator section this module writes.";
    };
  };

  config = lib.mkIf (cfg.enable && cfg.mode == "zram" && cfg.zram.driftCheck.enable) {
    systemd.services.nixram-zram-drift = {
      description = "nixram: verify the live zram device matches the declaration";
      wantedBy = [ "multi-user.target" ];
      # After the generator's own setup, or there is nothing to compare against yet.
      after = [ "systemd-zram-setup@${cfg.zram.driftCheck.device}.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        dev=/sys/block/${cfg.zram.driftCheck.device}
        drift=0

        if [ ! -d "$dev" ]; then
          echo "nixram-zram-drift: $dev absent -- no zram device to verify." >&2
          echo "  mode is \"zram\" and this module declared one, so it should exist by now." >&2
          exit 1
        fi

        ${lib.optionalString (declaredSize != null) (parseExpr declaredSize + ''
          actual=$(cat "$dev/disksize")
          if [ "$expected" = "?" ]; then
            echo "nixram-zram-drift: cannot verify size -- unrecognised expression ${declaredSize}." >&2
            echo "  live disksize is $actual bytes; check it by hand." >&2
            drift=1
          # 2 MiB of slack: the generator truncates to whole MiB and the kernel page-aligns what
          # it is given, so the live value is near the declared one but rarely equal to the byte.
          # Anything inside this window is the same intent; anything outside is real drift (the
          # case that motivated this module was off by a factor of nearly four).
          elif [ "$expected" != "0" ] && { [ $(( actual > expected ? actual - expected : expected - actual )) -gt 2097152 ]; }; then
            echo "nixram-zram-drift: DISKSIZE MISMATCH" >&2
            echo "  declared ${declaredSize} = $expected bytes" >&2
            echo "  live                     $actual bytes" >&2
            drift=1
          fi
        '')}

        ${lib.optionalString (declaredResident != null) ''
          # READ IT FROM mm_stat, NOT FROM mem_limit. /sys/block/zram0/mem_limit is mode 0200 --
          # write-only -- so `cat` yields nothing on every host, and a check reading it would
          # report "not applied" universally. mm_stat's 4th field is the same value, readable.
          # (Found the hard way: the first version of this check did read mem_limit, and a
          # hand-built fake sysfs with a readable file hid the bug that a real box exposed in
          # one command.)
          lim=$(awk '{print $4}' "$dev/mm_stat" 2>/dev/null || echo "")
          # Presence, not exactness: the kernel page-aligns this one and the arithmetic path
          # differs from disksize's, so a byte comparison is not meaningful. What matters is
          # whether a limit exists at all -- 0 means "no limit", which is the failure mode.
          if [ -z "$lim" ] || [ "$lim" = "0" ]; then
            echo "nixram-zram-drift: RESIDENT LIMIT NOT APPLIED" >&2
            echo "  declared zram-resident-limit ${declaredResident}, live mm_stat mem_limit is ''${lim:-unreadable}" >&2
            echo "  the physical budget is nixram's whole model in this mode -- without it the" >&2
            echo "  virtual ceiling is the only bound, which is not what was declared." >&2
            drift=1
          fi
        ''}

        ${lib.optionalString (declaredAlgo != null) ''
          # comp_algorithm lists every algorithm with the ACTIVE one in [brackets].
          active=$(sed -n 's/.*\[\([^]]*\)\].*/\1/p' "$dev/comp_algorithm" 2>/dev/null || echo "")
          want=$(echo ${lib.escapeShellArg declaredAlgo} | awk '{print $1}' | sed 's/(.*//')
          if [ -n "$active" ] && [ "$active" != "$want" ]; then
            echo "nixram-zram-drift: ALGORITHM MISMATCH -- declared primary '$want', live '$active'" >&2
            drift=1
          fi

          case ${lib.escapeShellArg declaredAlgo} in
            *' '*)
              recomp=$(cat "$dev/recomp_algorithm" 2>/dev/null || echo "")
              if [ -z "$recomp" ]; then
                echo "nixram-zram-drift: RECOMPRESSION NOT CONFIGURED" >&2
                echo "  declared '${declaredAlgo}' asks for a secondary pass; recomp_algorithm is empty." >&2
                drift=1
              fi ;;
          esac
        ''}

        if [ "$drift" -ne 0 ]; then
          cat >&2 <<EOF

        The declaration is correct; the DEVICE is stale. A zram device is created once at boot by
        a systemd generator, and a switch rewrites the config without resizing a device that is
        already active as swap.

        Recreate it (no reboot required):
          swapoff /dev/${cfg.zram.driftCheck.device} && systemctl restart systemd-zram-setup@${cfg.zram.driftCheck.device}.service

        Or leave it -- the next boot applies the declaration by itself. Note that swapoff pages
        everything resident back into RAM, so pick a moment when the box has headroom.
        EOF
          exit 1
        fi

        echo "nixram-zram-drift: live device matches the declaration."
      '';
    };
  };
}
