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
# most. The unit reports the mismatch and points at the safe lifecycle boundary; it deliberately
# does not print a tempting one-line `swapoff` recipe for a constrained host.
#
# THE HOSTS THIS ALSO COVERS. `mode = "none"` does not mean "no zram". It is the correct mode for a
# host whose zram device is real but created by nixpkgs' own legacy `zramSwap` module instead of
# this project's zram-generator wiring — that is the entire reason `nixram.zram.legacyPercent`
# exists. Those hosts are the ones this check matters most on: they are the smallest boxes here,
# their zram pool is the only reclaim tier they have, and nothing else on them ever looks at the
# live device. Gating this whole verifier on `mode == "zram"` left exactly them with none.
#
# Under that mode the comparison target changes, because the DECLARATION is not nixram's. The check
# reads what the legacy module was TOLD — `zramSwap.memoryPercent` / `.memoryMax` / `.algorithm` —
# rather than this module's own zram-generator settings, which under `mode = "none"` nixram never
# wrote and must not assume exist. It also drops the resident-limit check entirely: the legacy
# module has no such concept (it only ever sets a size), so a missing mem_limit there is a
# capability that module lacks, not drift, and a checker reporting the same unfixable condition on
# every boot only teaches an operator to stop reading it.
#
# Not hypothetical. A 456 MiB box in this project runs the legacy module at 40 % of RAM (~182 MiB)
# behind a leftover `memoryMax` cap that pins the live device to exactly 100 MiB. The moment that
# cap leaves the config, the running device keeps its 100 MiB until something swapoffs it — the
# same "declared correctly, applied never" state as above, on a host the old gate excluded.
{ lib, config, ... }:
let
  cfg = config.nixram;

  # WHO OWNS THE DEVICE decides what this check is allowed to compare against.
  #
  # `nixramOwned`: mode="zram" — the device came from this module's own zram-generator settings,
  # so every declared field below is nixram's own.
  #
  # `legacyOwned`: mode="none" AND nixpkgs' legacy zramSwap module is on — a real zram device this
  # module deliberately did not create. `or false` because `zramSwap` is a nixpkgs NixOS option
  # that a foreign or minimal eval need not have declared at all, and an absent option has to read
  # as "no legacy device", not as an evaluation error.
  nixramOwned = cfg.mode == "zram";
  legacyOwned = cfg.mode == "none" && (config.zramSwap.enable or false);

  # Only consulted on the nixram-owned path. Under `legacyOwned` this attrset does happen to be
  # populated on today's nixpkgs (nixos/modules/config/zram.nix renders zramSwap through
  # zram-generator too), and reading it anyway would be a trap: its `zram-size` is that module's
  # own expression shape, e.g. "min(40 / 100 * ram, 104857600 / 1024 / 1024)", which the parser
  # below does not recognise and would report as unverifiable drift on every boot.
  zcfg = if nixramOwned then (config.services.zram-generator.settings.zram0 or { }) else { };

  declaredSize = zcfg.zram-size or null;
  declaredResident = zcfg.zram-resident-limit or null;
  declaredAlgo = zcfg.compression-algorithm or null;

  # What the legacy module was told — its own options, not its rendering. Same reason the nixram
  # path parses `zram-size` rather than trusting the generator: the input is the declaration, and
  # a check that reads a downstream artifact can only ever verify that the artifact matches itself.
  legacyPercent = config.zramSwap.memoryPercent or null;
  legacyMemoryMax = config.zramSwap.memoryMax or null;
  legacyAlgo = config.zramSwap.algorithm or null;

  # The PRIMARY algorithm is the first whitespace-separated token of compression-algorithm, minus
  # any "(param=...)" suffix: "lz4 zstd(level=3) (type=idle)" declares lz4 as primary with an idle
  # recompression pass behind it.
  #
  # Computed HERE, at eval time, and not by piping the literal through `awk` at runtime -- see the
  # PATH note above the script. The string is a build-time constant; there was never a reason to
  # recompute it on every boot, and doing so is what put a text-processing tool on the critical
  # path of a check whose whole job is to be trustworthy.
  primaryAlgoOf =
    spec:
    if spec == null then
      null
    else
      lib.head (lib.splitString "(" (lib.head (lib.splitString " " spec)));

  declaredPrimaryAlgo = primaryAlgoOf declaredAlgo;

  # The primary algorithm to expect on the live device, whichever module declared it -- parsed the
  # same way on both paths.
  #
  # The legacy module's `algorithm` is USUALLY one bare token, but it is not one by construction:
  # nixpkgs types it `either (enum [ "842" "lzo" "lzo-rle" "lz4" "lz4hc" "zstd" ]) str` and pipes
  # the value verbatim into `compression-algorithm` (nixos/modules/config/zram.nix), so the open
  # `str` arm accepts a full multi-algorithm spec and zram-generator honours it. Comparing an
  # unparsed "lz4 zstd(level=3) (type=idle)" against the single token the kernel reports back in
  # [brackets] would fail on every boot, forever, on a host that declared nothing wrong -- the
  # precise failure mode the header refuses to inflict on the legacy path.
  #
  # What the legacy path still does NOT get is the recompression sub-check below, which stays keyed
  # on nixram's own `declaredAlgo`. Not because the legacy module cannot ask for a secondary pass
  # -- through that same open `str` it can -- but because nothing in this project does, so
  # extending it would add a branch no real device has ever exercised. The primary-algorithm
  # comparison is the part that earns its place on both paths.
  expectedAlgo = if legacyOwned then primaryAlgoOf legacyAlgo else declaredPrimaryAlgo;

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
        Check at boot and on every switch that the live zram device matches the declaration it was
        built from, and fail the unit when it does not.

        Which declaration depends on who owns the device: this module's own zram-generator settings
        under `mode = "zram"`, or nixpkgs' legacy `zramSwap` options under `mode = "none"` (see the
        module header). A `mode = "none"` host with no zram device at all gets no unit — there is
        nothing to verify.

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
      description = ''
        Which zram device to verify. Matches the generator section this module writes, and equally
        the first (and, at the default `zramSwap.swapDevices = 1`, only) device the legacy module
        creates. Exactly one device is verified: a multi-device legacy configuration is not
        modelled here.
      '';
    };
  };

  config = lib.mkIf (cfg.enable && cfg.zram.driftCheck.enable && (nixramOwned || legacyOwned)) {
    systemd.services.nixram-zram-drift = {
      description = "nixram: verify the live zram device matches the declaration";
      wantedBy = [ "multi-user.target" ];
      # After the generator's own setup, or there is nothing to compare against yet. The same unit
      # name covers the legacy path: nixpkgs' zramSwap renders through zram-generator as well
      # (nixos/modules/config/zram.nix). Ordering against a unit that does not exist is a systemd
      # no-op, so this stays correct even if that ever stops being true.
      after = [ "systemd-zram-setup@${cfg.zram.driftCheck.device}.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      # NOTHING BELOW MAY CALL A BINARY OUTSIDE SYSTEMD'S DEFAULT UNIT PATH, and this unit
      # deliberately declares no `path`. NixOS gives a unit coreutils, findutils, gnugrep, gnused,
      # systemd and util-linux -- and NOT gawk. An earlier version parsed mm_stat and the declared
      # algorithm with `awk`; on a real host every one of those calls died with "awk: command not
      # found", `lim` and `want` came back empty, and the check reported RESIDENT LIMIT NOT APPLIED
      # and ALGORITHM MISMATCH against a device that matched the declaration exactly.
      #
      # That is the worst failure a checker has. A check that cannot run must not be able to
      # manufacture the very drift it exists to detect -- the operator's next move is to `swapoff`
      # a live swap device on a box under memory pressure, on the strength of a broken `$4`. So the
      # parsing is bash builtins and eval-time constants, with `sed` (guaranteed present) the only
      # external call left. Adding a tool here means adding `path` too.
      script = ''
        dev=/sys/block/${cfg.zram.driftCheck.device}
        drift=0

        if [ ! -d "$dev" ]; then
          echo "nixram-zram-drift: $dev absent -- no zram device to verify." >&2
          ${if legacyOwned
            then ''echo "  zramSwap.enable is on and declared one, so it should exist by now." >&2''
            else ''echo "  mode is \"zram\" and this module declared one, so it should exist by now." >&2''}
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

        ${lib.optionalString (legacyOwned && legacyPercent != null) ''
          # LEGACY SIZE. No expression parser here, and deliberately so: `zramSwap.memoryPercent`
          # is a plain integer in Nix, so the expected size is arithmetic on a build-time constant
          # rather than a string the boot has to re-derive. The MiB truncation mirrors
          # zram-generator's own "as a function of MemTotal, both in MB" arithmetic, exactly as
          # parse_expr does above, and the same 2 MiB slack absorbs the rounding either side.
          read -r _ ram_kb _ < /proc/meminfo
          expected=$(( (ram_kb / 1024) * ${toString legacyPercent} / 100 * 1048576 ))
          ${lib.optionalString (legacyMemoryMax != null) ''
            # zramSwap.memoryMax is the min() term of the legacy module's own expression -- it caps
            # LOGICAL disksize, not physical residency, so a device pinned to the cap is exactly
            # what was declared and must not read as drift.
            if [ "$expected" -gt ${toString legacyMemoryMax} ]; then
              expected=${toString legacyMemoryMax}
            fi
          ''}
          actual=$(cat "$dev/disksize")
          if [ $(( actual > expected ? actual - expected : expected - actual )) -gt 2097152 ]; then
            echo "nixram-zram-drift: DISKSIZE MISMATCH" >&2
            echo "  declared zramSwap.memoryPercent = ${toString legacyPercent}%${lib.optionalString (legacyMemoryMax != null) " (capped by memoryMax = ${toString legacyMemoryMax})"} -> $expected bytes" >&2
            echo "  live                              $actual bytes" >&2
            echo "  (this host runs mode=\"none\": the declaration above is nixpkgs' legacy zramSwap" >&2
            echo "   module's, not nixram's -- nixram only publishes the percentage to it.)" >&2
            drift=1
          fi
        ''}

        ${lib.optionalString (legacyOwned && legacyPercent == null) ''
          # Unreachable against nixpkgs itself (memoryPercent has a default of 50), and kept anyway:
          # something else could declare `zramSwap.enable` without it, and this module's own rule is
          # that "I could not check" never gets to look like "it matches".
          echo "nixram-zram-drift: cannot verify size -- zramSwap is enabled but declares no" >&2
          echo "  memoryPercent, so there is no declared size to compare the live device against." >&2
          echo "  Live disksize is $(cat "$dev/disksize") bytes; check it by hand." >&2
          drift=1
        ''}

        ${lib.optionalString (nixramOwned && declaredResident != null) ''
          # nixram-owned devices only -- the legacy module cannot set a resident limit at all, so
          # on those hosts an absent mem_limit is a missing capability, not drift. See the header.
          #
          # READ IT FROM mm_stat, NOT FROM mem_limit. /sys/block/zram0/mem_limit is mode 0200 --
          # write-only -- so `cat` yields nothing on every host, and a check reading it would
          # report "not applied" universally. mm_stat's 4th field is the same value, readable.
          # (Found the hard way: the first version of this check did read mem_limit, and a
          # hand-built fake sysfs with a readable file hid the bug that a real box exposed in
          # one command.)
          lim=""
          if [ -r "$dev/mm_stat" ]; then
            # Field 4 of mm_stat, via bash's own field splitting -- no external text tool; see
            # the PATH note on this script. `|| :` because `read` returns non-zero on a
            # short/EOF-terminated line and `set -e` would take the script down with it; an
            # unreadable value must fall through to the report below, not abort.
            read -r _ _ _ lim _ < "$dev/mm_stat" || :
          fi
          ${parseExpr declaredResident}
          expected_limit="$expected"
          if [ -z "$lim" ] || [ "$lim" = "0" ]; then
            echo "nixram-zram-drift: RESIDENT LIMIT NOT APPLIED" >&2
            echo "  declared zram-resident-limit ${declaredResident}, live mm_stat mem_limit is ''${lim:-unreadable}" >&2
            echo "  the physical budget is nixram's whole model in this mode -- without it the" >&2
            echo "  virtual ceiling is the only bound, which is not what was declared." >&2
            drift=1
          elif [ "$expected_limit" = "?" ]; then
            echo "nixram-zram-drift: cannot verify resident limit -- unrecognised expression ${declaredResident}." >&2
            echo "  live mm_stat mem_limit is $lim bytes; check it by hand." >&2
            drift=1
          # The generator evaluates RAM expressions in whole MiB and the kernel page-aligns the
          # result. The same 2 MiB tolerance used for disksize absorbs both effects without
          # allowing an arbitrary nonzero cap to masquerade as the declared physical budget.
          elif [ $(( lim > expected_limit ? lim - expected_limit : expected_limit - lim )) -gt 2097152 ]; then
            echo "nixram-zram-drift: RESIDENT LIMIT MISMATCH" >&2
            echo "  declared zram-resident-limit ${declaredResident} = $expected_limit bytes" >&2
            echo "  live mm_stat mem_limit                              $lim bytes" >&2
            drift=1
          fi
        ''}

        ${lib.optionalString (expectedAlgo != null) (''
          # comp_algorithm lists every algorithm with the ACTIVE one in [brackets].
          active=$(sed -n 's/.*\[\([^]]*\)\].*/\1/p' "$dev/comp_algorithm" 2>/dev/null || echo "")
          want=${lib.escapeShellArg expectedAlgo}
          if [ -n "$active" ] && [ "$active" != "$want" ]; then
            echo "nixram-zram-drift: ALGORITHM MISMATCH -- declared primary '$want', live '$active'" >&2
            drift=1
          fi
        '' + lib.optionalString (nixramOwned && declaredAlgo != null) ''

          case ${lib.escapeShellArg declaredAlgo} in
            *' '*)
              # First line only, via `read` rather than `$(cat ...)`: the kernel pads this
              # attribute with trailing NUL bytes, and command substitution strips them with a
              # "ignored null byte in input" warning on every single run -- noise in the journal
              # of a unit whose output is supposed to mean something.
              recomp=""
              if [ -r "$dev/recomp_algorithm" ]; then
                read -r recomp < "$dev/recomp_algorithm" || :
              fi
              if [ -z "$recomp" ]; then
                echo "nixram-zram-drift: RECOMPRESSION NOT CONFIGURED" >&2
                echo "  declared '${declaredAlgo}' asks for a secondary pass; recomp_algorithm is empty." >&2
                drift=1
              fi ;;
          esac
        '')}

        if [ "$drift" -ne 0 ]; then
          cat >&2 <<EOF

        The declaration is correct; the DEVICE is stale. A zram device is created once at boot by
        a systemd generator, and a switch rewrites the config without resizing a device that is
        already active as swap.
        ${lib.optionalString legacyOwned ''

          The declaration compared here is nixpkgs' own zramSwap module's, not nixram's: this host
          runs mode="none", and that module renders into the same zram-generator config nixram
          would have written (nixos/modules/config/zram.nix), so the remediation below is identical.
        ''}
        The safe repair boundary is a planned boot into a generation whose declaration and boot
        entry have already been verified. Do not swap off the active device on a constrained host:
        that pages its contents back into RAM and can turn this diagnostic into an OOM incident.

        A no-reboot migration needs a host-specific, rollback-capable plan that keeps the existing
        swap online while replacement capacity is proven; this checker intentionally cannot infer
        or execute such a plan.
        EOF
          exit 1
        fi

        echo "nixram-zram-drift: live device matches the declaration."
      '';
    };
  };
}
