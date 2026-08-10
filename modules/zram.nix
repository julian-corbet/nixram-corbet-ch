# modules/zram.nix
#
# Wires services.zram-generator.settings -- deliberately NOT the legacy
# NixOS `zramSwap` module, which only ever controls virtual disksize
# (via memoryPercent/memoryMax) and has no notion of a physical
# resident-limit at all; nixpkgs itself documents zram-generator as the
# intended replacement. See docs/rationale.md and studies/README.md.

{ lib, config, pkgs, ... }:

with lib;

let
  cfg = config.nixram;
  levelsData = import ../levels.nix;
  inherit (levelsData) levelNames levels;

  # See modules/default.nix "EVAL SAFETY" -- never index `levels` with
  # `cfg.level` directly.
  activeLevelName = if cfg.level != null then cfg.level else builtins.head levelNames;
  activeLevel = levels.${activeLevelName};
  activeZram = activeLevel.zram;

  diskSizeExpr = if cfg.zram.diskSizeOverride != null
    then cfg.zram.diskSizeOverride
    else activeZram.diskSizeExpr;

  residentLimitExpr = if cfg.zram.residentLimitOverride != null
    then cfg.zram.residentLimitOverride
    else activeZram.residentLimitExpr;

  priority = if cfg.zram.priorityOverride != null
    then cfg.zram.priorityOverride
    else activeZram.priority;

  recompressionAlgorithm = if cfg.zram.recompressionAlgorithmOverride != null
    then cfg.zram.recompressionAlgorithmOverride
    else activeZram.recompressionAlgorithm;

  primaryAlgorithm = if cfg.zram.compressionAlgorithmOverride != null
    then cfg.zram.compressionAlgorithmOverride
    else activeZram.compressionAlgorithm;

  # zram-generator's compression-algorithm syntax: a primary algorithm,
  # optionally followed by one or more secondary algorithms tagged
  # "(type=idle)" for the idle-recompression pass registered at device
  # creation. Only ever assembled here, in one place -- levels.nix only
  # stores the algorithm *choices*, not this syntax.
  compressionAlgorithm =
    if cfg.zram.recompressionTimer.enable && recompressionAlgorithm != null
    then "${primaryAlgorithm} ${recompressionAlgorithm} (type=idle)"
    else primaryAlgorithm;

  # sizing = "virtual"  -> only zram-size;
  # sizing = "physical" -> only zram-resident-limit (zram-size stays at
  #                        zram-generator's own upstream default,
  #                        min(ram / 2, 4096) -- only the physical
  #                        budget is nixram's opinion in this mode);
  # sizing = "both"     -> both keys.
  zramGeneratorSettings = {
    compression-algorithm = compressionAlgorithm;
    swap-priority = priority;
  } // optionalAttrs (cfg.zram.sizing != "physical") {
    zram-size = diskSizeExpr;
  } // optionalAttrs (cfg.zram.sizing != "virtual" && residentLimitExpr != null) {
    zram-resident-limit = residentLimitExpr;
  };

  # The recompression maintenance script: a rolling two-phase design,
  # gated on actual system idleness rather than run unconditionally on a
  # fixed schedule (the operator's explicit correction -- cadence should be
  # "whenever there is idle time", not a fixed calendar interval). The
  # timer fires often (see recompressionTimer.onCalendar's new default);
  # each firing checks CPU PSI first and does nothing at all unless the
  # box is genuinely quiet right now, so a busy box simply defers to
  # whenever it next goes idle instead of forcing this work in daily
  # regardless of load, and a box with frequent idle windows gets MORE
  # chances to mark and recompress, not fewer.
  #
  # Once the idle gate passes, the same rolling two-phase design as
  # before: each run recompresses whatever was idle-marked by the
  # PREVIOUS idle run and has stayed untouched since (the kernel
  # automatically clears a page's idle flag the moment it's written
  # again, so this is a real dwell period, not "mark and recompress in
  # the same breath" -- the latter would recompress the entire device
  # every single run, since everything looks idle the instant after
  # being marked). Only THEN does it mark the current resident set idle
  # again, becoming the input for the NEXT idle run.
  #
  # FOUR RUNTIME GATES, each of which logs and exits 0. All four describe the
  # ENVIRONMENT rather than a fault this run could repair, and the timer fires
  # again in minutes, so a red unit would only be noise:
  #
  #   1. /sys/block/zram0/recompress absent -- pre-6.2 kernel, or
  #      CONFIG_ZRAM_MULTI_COMP disabled.
  #   2. the device node exists but the device is not initialised
  #      (initstate != 1). A real boot race, not a theoretical one: the timer
  #      carries Persistent=true, so it fires a catch-up run the moment
  #      timers.target is reached, and on corbet-server that landed one second
  #      BEFORE systemd-zram-setup@zram0 had set disksize. The kernel's
  #      recompress_store() bails with -EINVAL while !init_done(zram), so such a
  #      run can do nothing except fail.
  #   3. no recompression algorithm registered -- recomp_algorithm reads back
  #      empty. Recompression is then impossible by construction, and phase 1's
  #      write returns EINVAL on every attempt.
  #   4. CPU PSI says the box is not idle.
  #
  # Gate 3 is the one that actually cost something. When a `switch` changes the compression
  # algorithms of a zram device that is already initialised, the kernel refuses
  # the primary ("zram: Can't change algorithm for initialized device", EBUSY),
  # so a host can sit for days with a live device whose registered algorithms are
  # the ones it booted with and not the ones now declared. If those boot-time
  # algorithms had no secondary, every recompression run is an EINVAL until the
  # next reboot. modules/zram-drift.nix is what makes that divergence visible;
  # this unit's job is only to not thrash while it lasts.
  #
  # WHY THE TWO PHASES NO LONGER SHARE A FATE. `set -e` used to turn phase 1's
  # write into an immediate unit failure, which meant phase 2 -- the idle
  # MARKING -- never ran at all. That is the worst possible coupling, because
  # phase 2 is what feeds the NEXT run: once phase 1 starts failing the device
  # stops being marked, so the mechanism cannot resume on its own even after the
  # condition that broke phase 1 has gone away. Measured on corbet-server: 36
  # consecutive failed runs, one every 15 minutes from 04:00 to 12:45, each
  # dying on `echo "type=idle" > /sys/block/zram0/recompress` with "write error:
  # Invalid argument" while recomp_algorithm was empty. The journal carried
  # `Failed with result 'exit-code'` and nothing else, and not one page was
  # marked idle in that entire window.
  #
  # errexit stays ON -- the fix is to say which failures mean what, not to stop
  # checking. The gates absorb everything that is merely the environment; phase
  # 1's write is then allowed to fail WITHOUT taking the run down, so phase 2
  # still executes; and the run exits non-zero at the end if either phase really
  # failed, so a genuine fault is still a red unit rather than a warning nobody
  # reads. It simply can no longer skip work on its way out.
  #
  # Reads use the `read` builtin rather than `cat`, in the same spirit as
  # nixram-zswap-disable below: the unit's PATH is whatever `path` renders to and
  # nothing else. Here that is gawk plus the set NixOS appends to every unit
  # (coreutils, findutils, gnugrep, gnused, systemd), so `cat` would in fact
  # resolve -- but a builtin cannot be broken by a future `path` edit, and these
  # are single-line sysfs reads where `cat` buys nothing.
  recompressionScript = pkgs.writeShellScript "nixram-zram-recompress" ''
    set -euo pipefail

    dev=/sys/block/zram0

    if [ ! -e "$dev/recompress" ]; then
      echo "nixram: $dev/recompress not present (kernel lacks zram multi-compression support or it's disabled) -- skipping idle recompression this run" >&2
      exit 0
    fi

    # Gate 2: initialised? An uninitialised device rejects both phases.
    if ! read -r initstate < "$dev/initstate" || [ "$initstate" != "1" ]; then
      echo "nixram: zram0 exists but is not initialised yet (initstate is not 1) -- systemd-zram-setup@zram0 has probably not finished; skipping this run (will retry next timer tick)" >&2
      exit 0
    fi

    # Gate 3: is there anything to recompress WITH? recomp_algorithm lists one
    # line per registered secondary algorithm and is empty when there are none,
    # so a failed read is exactly the "none registered" case.
    if ! read -r recomp_algs < "$dev/recomp_algorithm"; then
      echo "nixram: no recompression algorithm registered on zram0 ($dev/recomp_algorithm is empty) -- the live device cannot recompress; skipping this run (see nixram-zram-drift for whether the live device still matches the declaration)" >&2
      exit 0
    fi

    # Idle gate: only proceed if the box is genuinely quiet right now.
    # CPU PSI's "some" line (avg10) is the fraction of the last 10s any
    # task spent waiting for CPU -- a low value means little contention,
    # a reasonable proxy for "safe to spend cycles on background work."
    # Missing PSI (CONFIG_PSI=n, or psi=0 on the kernel command line) is
    # not fatal: proceed without the gate rather than never recompress
    # at all on such a kernel.
    psi=/proc/pressure/cpu
    if [ -e "$psi" ]; then
      some_avg10=$(awk '/^some/ {for (i=1;i<=NF;i++) if ($i ~ /^avg10=/) {sub("avg10=","",$i); print $i}}' "$psi")
      is_idle=$(awk -v v="''${some_avg10:-0}" 'BEGIN { print (v < 10.0) ? 1 : 0 }')
      if [ "$is_idle" != "1" ]; then
        echo "nixram: CPU pressure too high (some avg10=''${some_avg10}%) -- not idle, skipping this check (will retry next timer tick)" >&2
        exit 0
      fi
    else
      echo "nixram: $psi not present (kernel lacks PSI) -- proceeding without an idle gate" >&2
    fi

    # Phase 1: recompress pages idle-marked by the previous idle run
    # that have stayed untouched since (their idle flag survived).
    #
    # Deliberately NOT fatal. The write is a request to the kernel to do
    # optional background work, and the kernel can refuse it for reasons that
    # have nothing to do with whether phase 2 should run -- EAGAIN while another
    # post-processing action (writeback, a concurrent recompress) holds
    # pp_in_progress, or EINVAL from a state the gates above cannot see.
    # Wrapping it in the `if` condition is what exempts it from errexit; the
    # brace group's stderr is folded into the captured stdout so the kernel's
    # own error text reaches the journal instead of being thrown away.
    phase1_failed=0
    if ! phase1_err=$({ echo "type=idle" > "$dev/recompress"; } 2>&1); then
      phase1_failed=1
      echo "nixram: WARNING the kernel refused the recompression pass (''${phase1_err:-no error text}) with recomp_algorithm=''${recomp_algs} -- continuing to the idle marking anyway so the next run still has input" >&2
    fi

    # Phase 2: mark the current resident set idle, for the NEXT idle
    # run to act on after a full dwell period.
    #
    # This one IS fatal. Unlike phase 1 it asks for no work, only a flag sweep,
    # and the gates above have already established that the device exists and is
    # initialised -- so a failure here is not a busy kernel, it is the two-phase
    # design being broken, and the next run would have nothing to act on.
    if ! phase2_err=$({ echo "all" > "$dev/idle"; } 2>&1); then
      echo "nixram: idle marking failed on an initialised device (''${phase2_err:-no error text}) -- the next recompression run will have no idle pages to act on" >&2
      exit 1
    fi

    # Report phase 1's refusal only now, with phase 2 already done. Losing a
    # pass is worth a red unit; losing the marking that feeds every future pass
    # is not something to risk in order to report it.
    if [ "$phase1_failed" != "0" ]; then
      exit 1
    fi
  '';

  # PSI-gated swappiness relief valve. the operator's own design intent: hold
  # swappiness LOW at rest (reluctant tiers: only cache eviction, never
  # anon, under normal fluctuation), but let the kernel actually use swap
  # once a real overflow event is underway -- "swap is for overflow when
  # upgrades run or whatever, or for icecold pages," not for routine
  # fullness. Hysteresis, not a single threshold: avg10 (10s average) is
  # fast enough to catch a real spike quickly and enter relief; avg60
  # (60s average) is deliberately the SLOWER signal required to leave
  # relief, so a brief lull mid-spike doesn't bounce swappiness back down
  # before the pressure has actually resolved. State tracked in a small
  # file under /run so a reboot always starts back at the low baseline.
  # See docs/rationale.md [17].
  swappinessReliefScript = pkgs.writeShellScript "nixram-swappiness-relief" ''
    set -euo pipefail

    psi=/proc/pressure/memory
    state_file=/run/nixram-swappiness-relief.state
    # The ACTUAL resolved sysctl value, not the tier's raw levels.nix
    # constant -- modules/sysctls.nix sets "vm.swappiness" via mkDefault, so
    # a host is free to override it (the "escape hatch on every layer"
    # contract every sysctl here carries). Baking activeLevel.swappiness in
    # directly would ignore that override entirely: the first time relief
    # is entered and then left, this script would silently revert the
    # host's chosen value back to nixram's own stale tier default. Falls
    # back to the tier constant only if nothing (nixram or a host) ever set
    # the sysctl at all (e.g. sysctls.enable = false).
    baseline=${toString (config.boot.kernel.sysctl."vm.swappiness" or activeLevel.swappiness)}
    relief=${toString cfg.zram.swappinessRelief.reliefValue}
    high=${toString cfg.zram.swappinessRelief.pressureHighThreshold}
    low=${toString cfg.zram.swappinessRelief.pressureLowThreshold}

    if [ ! -e "$psi" ]; then
      echo "nixram: $psi not present (kernel lacks PSI) -- relief valve has no signal to act on, leaving swappiness at its boot-time baseline" >&2
      exit 0
    fi

    some_line=$(awk '/^some/ {print; exit}' "$psi")
    avg10=$(echo "$some_line" | awk '{for (i=1;i<=NF;i++) if ($i ~ /^avg10=/) {sub("avg10=","",$i); print $i}}')
    avg60=$(echo "$some_line" | awk '{for (i=1;i<=NF;i++) if ($i ~ /^avg60=/) {sub("avg60=","",$i); print $i}}')

    state=baseline
    [ -e "$state_file" ] && state=$(cat "$state_file")

    if [ "$state" = "baseline" ]; then
      entering=$(awk -v v="''${avg10:-0}" -v h="$high" 'BEGIN { print (v >= h) ? 1 : 0 }')
      if [ "$entering" = "1" ]; then
        echo "$relief" > /proc/sys/vm/swappiness
        echo relief > "$state_file"
        echo "nixram: memory pressure rising (some avg10=''${avg10}% >= ''${high}%) -- entering relief, swappiness -> $relief" >&2
      else
        # Reconcile out-of-band drift. This branch used to do nothing at all,
        # which made the valve a pure edge-trigger: it wrote swappiness only
        # when CROSSING between baseline and relief, and never checked that
        # the value it believed in was still the value the kernel had. Anyone
        # -- a tuning experiment, a privileged container sharing this kernel
        # (vm.* is not namespaced), a stray sysctl -w -- could move swappiness
        # and the valve would sit at state=baseline forever, reporting success
        # every 30s while the declared value was not in effect.
        #
        # That is not hypothetical: corbet-server was found at a live
        # swappiness of 150 with 10 declared, state=baseline on disk, and the
        # last real transition logged 12 days earlier. The reluctant-tier
        # design (low static baseline + a valve that briefly lifts to 60) was
        # not merely overridden but inverted, since 150 sits above even the
        # relief ceiling -- and the valve was dead code in that state, because
        # it can only ever ENTER relief from a baseline it never re-asserts.
        #
        # $baseline is the RESOLVED sysctl value, not the raw tier constant
        # (see the comment where it is defined), so re-asserting it enforces
        # whatever the host actually declared -- it does not drag a host's own
        # override back to nixram's default. The cost is that runtime tuning
        # by hand no longer sticks: on a declaratively-configured host that is
        # the intended outcome, and the place to change swappiness is the
        # config, not /proc.
        current=$(cat /proc/sys/vm/swappiness)
        if [ "$current" != "$baseline" ]; then
          echo "$baseline" > /proc/sys/vm/swappiness
          echo "nixram: swappiness was $current out-of-band, expected $baseline at rest -- reconciled" >&2
        fi
      fi
    else
      leaving=$(awk -v v="''${avg60:-100}" -v l="$low" 'BEGIN { print (v < l) ? 1 : 0 }')
      if [ "$leaving" = "1" ]; then
        echo "$baseline" > /proc/sys/vm/swappiness
        echo baseline > "$state_file"
        echo "nixram: memory pressure resolved (some avg60=''${avg60}% < ''${low}%) -- leaving relief, swappiness -> $baseline" >&2
      fi
    fi
  '';
in
{
  config = mkIf (cfg.enable && cfg.mode == "zram") {
    # services.zram-generator's own upstream module gates its ENTIRE config
    # (the systemd units, /etc/systemd/zram-generator.conf itself) behind
    # `mkIf cfg.enable` -- setting only `.settings` without this produces a
    # fully-populated but completely inert configuration: no error, no
    # warning, just no zram device at boot. Caught by the runtime VM test
    # (checks/swappiness-relief-vm-test.nix), not by eval-tests, which only
    # inspect `.settings` and have no way to notice the upstream gate was
    # never satisfied.
    services.zram-generator.enable = true;
    services.zram-generator.settings.zram0 = zramGeneratorSettings;

    # ENFORCE the mode XOR against the KERNEL's own default, not just against
    # this module's other branch. `mode` documents zram and zswap as "deliberately
    # mutually exclusive", but until now that was enforced only by not
    # CONFIGURING both -- nothing ever turned the other one OFF. Any kernel built
    # with CONFIG_ZSWAP_DEFAULT_ON=y (all CachyOS kernels, among others) arms
    # zswap before userspace exists, with no cmdline parameter and nothing in any
    # config file to point at. On such a kernel `mode = "zram"` silently produced
    # exactly the combination the option text promises is impossible.
    #
    # And it is worse than the usual double-compression argument, because zswap's
    # writeback target is the swap device -- which in this mode is zram, i.e. RAM.
    # A zswap pool in front of a zram device compresses already-compressed pages
    # into the same resource it is caching, and its eviction path leads nowhere:
    # there is no durable store to shed to, so under real pressure the box can
    # only compress, never actually free anything. Observed on a 125 GiB host
    # whose only swap device was zram: zswap enabled=Y, stored_pages climbing,
    # written_back_pages pinned at 0.
    boot.kernelParams = [ "zswap.enabled=0" ];

    # The kernel parameter only takes effect on the NEXT BOOT, so a `switch` on a
    # box that already booted with zswap armed would leave it armed -- the same
    # "writing it is not applying it" gap the sysctl layer solves with its reapply
    # bridge. This closes it at switch time too. Disabling zswap at runtime stops
    # new stores; pages already in the pool stay readable and fault back in
    # normally, so this is safe to run on a live box with a non-empty pool.
    #
    # Ordered before the zram device comes up so zswap is never armed in front of
    # it. Deliberately uses only shell BUILTINS (read/printf/test, no cat/awk) --
    # a systemd unit's PATH does not include coreutils just because something else
    # installed it, the exact trap that made nixram-zram-recompress exit 127 until
    # it grew an explicit `path`.
    systemd.services.nixram-zswap-disable = {
      description = "Disable zswap (nixram mode=\"zram\" -- the two are mutually exclusive)";
      wantedBy = [ "multi-user.target" ];
      before = [ "systemd-zram-setup@zram0.service" "shutdown.target" ];
      conflicts = [ "shutdown.target" ];
      # DefaultDependencies=false IS LOAD-BEARING, and its absence is not a style
      # nit -- it cost a host every login path at once (2026-07-29).
      #
      # `before = systemd-zram-setup@zram0.service` puts this unit inside the EARLY
      # BOOT chain: that generator-made unit runs before dev-zram0.swap, which
      # swap.target needs, which /run mounts and sysinit.target order against. But
      # systemd's default dependencies for a service also add an implicit
      # `After=basic.target` -- and basic.target comes AFTER sysinit.target. So the
      # unit ends up required to run both before and after sysinit, i.e.:
      #
      #   sysinit.target -> suid-sgid-wrappers.service -> run-wrappers.mount
      #     -> swap.target -> dev-zram0.swap -> systemd-zram-setup@zram0.service
      #     -> nixram-zswap-disable.service -> basic.target -> sysinit.target
      #
      # systemd breaks such a cycle by DELETING one job, and it is under no
      # obligation to pick ours. On the host that hit this it deleted
      # suid-sgid-wrappers.service, so /run/wrappers was never populated, PAM's
      # unix_chkpwd helper did not exist, and EVERY authentication path failed --
      # ssh and console alike ("helper binary execve failed", "Access denied for
      # user root by PAM account configuration"). The box booted, served k3s and
      # NFS, and could not be logged into. Nothing in the log named nixram.
      #
      # Turning default dependencies off drops the implicit basic.target ordering
      # and leaves only the one edge that is actually wanted (before zram setup).
      # The explicit shutdown.target pair is what DefaultDependencies would
      # otherwise have supplied and must be restored by hand, or the unit is not
      # stopped cleanly on shutdown.
      #
      # wantedBy stays multi-user.target on purpose: this unit must ALSO run at
      # `switch` time on an already-booted host, which is the gap the whole
      # service exists to close (see the comment above). Making it wantedBy the
      # zram-setup unit instead would fix boot and silently reintroduce that gap.
      unitConfig.DefaultDependencies = false;
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        param=/sys/module/zswap/parameters/enabled

        if [ ! -e "$param" ]; then
          echo "nixram: $param absent -- this kernel has no zswap (CONFIG_ZSWAP=n); nothing to disable"
          exit 0
        fi

        read -r cur < "$param"
        if [ "$cur" = "N" ]; then
          echo "nixram: zswap already disabled"
          exit 0
        fi

        if printf '0' > "$param"; then
          echo "nixram: zswap disabled (mode=\"zram\"): a zswap pool in front of a zram device double-compresses into the same RAM it is caching, and has no durable store to write back to"
        else
          echo "nixram: WARNING could not write $param -- zswap stays armed in front of the zram device until the next boot picks up zswap.enabled=0 from the kernel command line" >&2
        fi
      '';
    };

    systemd.services.nixram-zram-recompress = mkIf cfg.zram.recompressionTimer.enable {
      description = "nixram zram idle-page recompression (rolling two-phase pass)";
      # Explicit PATH dependency -- the script uses `awk`, and a systemd
      # service's default PATH is NOT guaranteed to include it just
      # because some package happens to be in environment.systemPackages
      # elsewhere. Caught by the runtime VM test: this was silently
      # absent before, so the script would exit 127 the first time it
      # actually ran on a box that hadn't separately installed gawk.
      path = [ pkgs.gawk ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${recompressionScript}";
        # This is maintenance work fighting the exact symptom (memory
        # pressure / stalls) it exists to prevent -- keep it out of the
        # way of anything PSI is watching.
        Nice = 19;
        CPUWeight = 10;
        IOSchedulingClass = "idle";
      };
    };

    systemd.timers.nixram-zram-recompress = mkIf cfg.zram.recompressionTimer.enable {
      description = "Timer for nixram zram idle-page recompression";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = cfg.zram.recompressionTimer.onCalendar;
        Persistent = true;
      };
    };

    systemd.services.nixram-swappiness-relief = mkIf cfg.zram.swappinessRelief.enable {
      description = "nixram PSI-gated swappiness relief valve";
      # See the matching comment on nixram-zram-recompress above -- same
      # missing-PATH bug, caught by the same runtime VM test.
      path = [ pkgs.gawk ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${swappinessReliefScript}";
        # Needs to react quickly to real pressure -- unlike recompression,
        # this is not background maintenance to defer, so no Nice/IOWeight
        # downgrade here.
      };
    };

    systemd.timers.nixram-swappiness-relief = mkIf cfg.zram.swappinessRelief.enable {
      description = "Timer for nixram PSI-gated swappiness relief valve";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "${toString cfg.zram.swappinessRelief.checkIntervalSec}s";
        OnUnitActiveSec = "${toString cfg.zram.swappinessRelief.checkIntervalSec}s";
        # systemd's own default AccuracySec is 1 MINUTE -- it coalesces
        # nearby timer firings for power saving, which silently defeats
        # a check interval shorter than that (caught by the runtime VM
        # test: a 5s test override never actually fired more often than
        # ~15-45s apart). This mechanism exists specifically to react to
        # pressure faster than a coarse, unconditional cadence would --
        # a 1-minute-accuracy default undermines that at ANY
        # checkIntervalSec setting, including the real 30s default.
        AccuracySec = "1s";
      };
    };
  };
}
