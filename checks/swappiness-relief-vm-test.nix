# checks/swappiness-relief-vm-test.nix
#
# A REAL runtime test, not eval-only: boots an actual NixOS VM (ephemeral
# QEMU via pkgs.testers.nixosTest -- nothing persists after the build, no
# standing VM infrastructure needed) and exercises the swappiness-relief
# mechanism end to end, exactly as it runs in production: the real systemd
# timer, real memory pressure, real /proc/pressure/memory readings, real
# kernel PSI accounting.
#
# This is the one mechanism this session's own docs flag as genuinely
# unvalidated (docs/rationale.md [17]) -- eval-tests only confirm the
# module RENDERS the right systemd units; they say nothing about whether
# the PSI-gated hysteresis logic actually behaves as designed under real
# pressure. This test closes that gap for the core round trip: enter
# relief under sustained pressure, leave relief once it genuinely passes.
#
# HONEST RECORD OF WHAT REPEATED REAL RUNS ACTUALLY SHOWED (this matters --
# read before trusting a single green run, and before "simplifying" away
# the retry loop below): across roughly a dozen real VM-boot attempts made
# while building this test, generating genuine, non-fatal, SUSTAINED PSI
# pressure at swappiness=10 turned out to be a real, three-way bifurcation
# rather than a single reliable outcome:
#   - too gentle a workload (a single serial grower at any size short of
#     real exhaustion; concurrent stress-ng below ~90%) produces NO
#     measurable PSI stall at all -- the kernel simply never needs to
#     reclaim, because a low swappiness value means it does not try to
#     until genuinely forced. This is the reluctant tier's own design
#     intent working correctly, not a test bug.
#   - a workload tuned into the narrow effective band (concurrent
#     stress-ng around 92%) MOST OFTEN produces a genuine gradual climb
#     over roughly 25-30 seconds (observed peaks: 10.32 and 12.15 across
#     two otherwise-identical runs) that clears the module's real 10%
#     entry threshold for a handful of seconds before decaying back down
#     just as gently once the workload stops -- this is the case that
#     actually proves the mechanism, and it has been observed with exact
#     matching production log lines for BOTH the entry and the exit
#     transition (see the mechanism's own log format in modules/zram.nix).
#   - the SAME workload, same percentage, unchanged, occasionally overshoots
#     straight into a hard kernel OOM-kill instead (kswapd invoking the
#     OOM killer directly, jumping from a low single-digit avg10 reading
#     to a killed process in well under a second -- too fast for any
#     external monitor polling at sub-second granularity to react to).
# No amount of percentage-tuning tried eliminated the third outcome without
# also eliminating the second (dialing back far enough to guarantee no hard
# OOM reliably produced no pressure at all instead). This looks like a
# genuine, irreducible property of how kswapd/direct-reclaim behaves right
# at the edge of real exhaustion under a low swappiness value, not a
# solvable test-authoring bug -- see docs/rationale.md [17] for the
# production-relevant implication (a sufficiently ABRUPT real memory spike
# could plausibly outrun this mechanism's reaction time the same way it
# outran this test's monitor, independent of checkIntervalSec).
#
# Given that, the testScript below does not pretend a single attempt is
# reliable: it retries with a fresh workload instance on failure (whether
# the failure was "decayed without crossing the threshold" or "the
# previous attempt's workload got OOM-killed"), and only fails the build
# if EVERY attempt in a generous budget comes up empty -- which would be a
# genuine signal worth investigating, not noise to retry away forever.
#
# PRESSURE GENERATION (pressureRampScript below): stress-ng for genuine
# CONCURRENT memory demand (a single serial grower cannot replicate real
# contention no matter how large it grows -- see the record above), wrapped
# in an external Python safety net that watches the exact
# /proc/pressure/memory signal the relief valve itself acts on and pauses
# (SIGSTOP) the workers if pressure ever climbs far beyond what any real
# run has produced, as a backstop against a truly runaway allocation --
# not the primary detection path, and not a fix for the hard-OOM outcome
# above (which happens too fast for any poll-based backstop to catch).
#
# Building this test (across every pressure-generation approach tried)
# caught three real, pre-existing bugs nothing else in the repo had ever
# exercised at runtime:
#   1. `services.zram-generator.enable` was never set -- the upstream
#      module gates its ENTIRE config (including the systemd units and
#      /etc/systemd/zram-generator.conf itself) behind that flag, so
#      `mode = "zram"` silently produced no zram device at all. Fixed in
#      modules/zram.nix.
#   2. The PSI-reading scripts (recompression, swappiness-relief, pressure
#      diagnostics) use `awk` with no explicit PATH dependency -- fine in
#      an interactive shell, but a systemd service's default PATH doesn't
#      guarantee it. Fixed via `path = [ pkgs.gawk ];` on all three units.
#   3. systemd's own default `AccuracySec` (1 minute) silently coalesces
#      any timer firing more often than that, defeating a short
#      checkIntervalSec entirely. Fixed with an explicit `AccuracySec` on
#      the relief-valve timer.
#
# Picked the "2G" level deliberately: the smallest RELUCTANT tier (the
# relief valve is disabled by default at 256M/512M/1G, which are already
# eager -- see levels.nix), so the VM needs the least RAM to generate
# real, convincing pressure in reasonable wall-clock time.

{ pkgs, nixpkgs, nixramModule }:

let
  # See the file's top-level comment for the full empirical record this
  # design is based on -- a self-paced serial grower (checking PSI before
  # each small allocation step, stopping the instant avg10 ticked up) was
  # tried first and ruled out: it held 1600 MB (78% of the VM's 2048 MB)
  # for well over a minute with avg10 pinned at a flat 0.0 throughout. At
  # swappiness=10 the kernel resists reclaiming anon memory until
  # genuinely forced to, so a single leisurely allocator the kernel can
  # always keep pace with never dents free memory enough to cause real
  # stall -- a direct consequence of the reluctant tier's own design, not
  # a flaw in the growth technique. Concurrent demand (stress-ng) is what
  # actually creates contention; the safety net below just keeps it from
  # running fully unsupervised.
  pressureRampScript = pkgs.writeScriptBin "nixram-test-pressure-ramp" ''
    #!${pkgs.python3}/bin/python3
    import os, signal, subprocess, sys, time

    # PURE SAFETY NET, not the primary detection path -- deliberately set
    # HIGH, well above the pressure a normal run of this workload produces
    # (observed peaks: 10.32-12.15). Earlier, lower values were tried and
    # ruled out: freezing (SIGSTOP) only ever HALTS the workers' ongoing
    # contention, after which avg10 purely decays from wherever it was
    # paused -- it does not hold pressure steady. A trigger set anywhere
    # near or below the real entry threshold therefore guarantees the
    # relief valve never sees a sustained crossing at all; it just
    # truncates the climb early. This value exists only to stop something
    # genuinely running away, which normal runs never come remotely close
    # to -- it is not expected to fire in an ordinary pass.
    TARGET_AVG10 = 30.0
    CHECK_S = 0.5
    # The narrow effective band found empirically (see top-level comment):
    # below roughly 90% this VM never generates measurable PSI stall at
    # all; at 92% most runs climb gently and clear the entry threshold,
    # but a minority overshoot into a hard kernel OOM instead. No
    # percentage found eliminates the second outcome without also
    # eliminating the first -- retrying (see testScript) is how this test
    # manages that, not a higher/lower number here.
    #
    # Absolute store path, not a bare "stress-ng" name: this script runs as
    # a systemd-run transient unit's main process, which does NOT inherit
    # environment.systemPackages' PATH -- the same missing-PATH dependency
    # class of bug already found (and fixed) for the awk-using services
    # elsewhere in this project, this time for subprocess.Popen instead.
    STRESS_ARGS = [
        "${pkgs.stress-ng}/bin/stress-ng", "--vm", "4", "--vm-bytes", "92%", "--vm-keep", "--timeout", "0",
    ]

    def read_avg10():
        with open("/proc/pressure/memory") as f:
            for line in f:
                if line.startswith("some"):
                    for tok in line.split():
                        if tok.startswith("avg10="):
                            return float(tok.split("=")[1])
        return 0.0

    proc = subprocess.Popen(STRESS_ARGS, start_new_session=True)
    pgid = os.getpgid(proc.pid)

    def cleanup(signum=None, frame=None):
        # Called on SIGTERM (what `systemctl stop` sends this unit's main
        # process). A SIGSTOPped process group would otherwise leave
        # SIGTERM pending indefinitely -- SIGCONT first so it can actually
        # act on the SIGKILL that follows, so teardown is immediate
        # instead of waiting out systemd's own stop-timeout escalation.
        try:
            os.killpg(pgid, signal.SIGCONT)
        except ProcessLookupError:
            pass
        try:
            os.killpg(pgid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        sys.exit(0)

    signal.signal(signal.SIGTERM, cleanup)
    signal.signal(signal.SIGINT, cleanup)

    print("stress-ng launched, watching /proc/pressure/memory", flush=True)
    paused = False
    while True:
        avg10 = read_avg10()
        print(f"avg10={avg10}, paused={paused}", flush=True)
        if not paused and avg10 >= TARGET_AVG10:
            print(f"pressure detected (avg10={avg10}) -- pausing workers before they run away", flush=True)
            os.killpg(pgid, signal.SIGSTOP)
            paused = True
        if proc.poll() is not None:
            print("stress-ng process exited unexpectedly", flush=True)
            break
        time.sleep(CHECK_S)
  '';
in

pkgs.testers.nixosTest {
  name = "nixram-swappiness-relief";

  nodes.machine = { config, pkgs, lib, ... }: {
    imports = [ nixramModule ];
    services.nixram = {
      enable = true;
      level = "2G";
      zram.swappinessRelief = {
        # Test-time override, not a production recommendation -- the real
        # default (30s) is itself an unvalidated starting point
        # (rationale.md [17]). The pressure this test's workload produces
        # is a genuinely brief transient (observed rising above the 10%
        # entry threshold for only a handful of seconds before decaying
        # on its own, regardless of anything else in this test) -- a
        # 5-second cadence missed it on one real run. 1 second (matched by
        # an equally tight AccuracySec in production code, see
        # modules/zram.nix) gives the mechanism many samples inside that
        # narrow window, which is what actually makes catching a real
        # threshold crossing more reliable here, not a longer wait.
        checkIntervalSec = 1;
      };
    };
    # Must actually match the level: residentLimitExpr/diskSizeExpr
    # evaluate against the VM's real detected RAM at boot, same as any
    # physical machine -- see rationale.md [1]/[2] and faq.md.
    virtualisation.memorySize = 2048;
    # 2 vCPUs so a memory-bound workload doesn't itself become the CPU
    # bottleneck, which would show up as CPU pressure instead of the
    # memory pressure this test actually needs to generate.
    virtualisation.cores = 2;
    # This test still pushes the VM well beyond ordinary usage to
    # generate genuine PSI pressure -- the test VM image ships
    # panic_on_oom=1 by default, which would turn every hard-OOM outcome
    # (see the top-level comment -- a real minority of runs) into a full
    # kernel panic instead of a contained, retriable unit failure. Forced
    # off here, test-only -- this is NOT something nixram itself sets or
    # recommends for real boxes.
    boot.kernel.sysctl."vm.panic_on_oom" = lib.mkForce 0;
  };

  testScript = ''
    machine.start()
    machine.wait_for_unit("multi-user.target")

    with subtest("zram device is actually created, not just rendered"):
        machine.succeed("test -e /dev/zram0")
        machine.succeed("swapon --show | grep -q /dev/zram0")

    with subtest("reluctant tier rests at the low baseline (10), not the old flat 60"):
        machine.succeed("test $(cat /proc/sys/vm/swappiness) -eq 10")

    with subtest("relief-valve timer is enabled and running"):
        machine.succeed("systemctl is-active nixram-swappiness-relief.timer")

    active_unit = None

    with subtest("genuine sustained pressure drives swappiness into relief (-> 60)"):
        # See the file's top-level comment for why this retries: the
        # pressure workload genuinely bifurcates run to run between a
        # gradual climb that clears the entry threshold and an occasional
        # hard kernel OOM-kill of the workload unit itself -- both are
        # real, repeatedly-observed outcomes of the SAME configuration,
        # not a sign of a broken test. A fresh unit each attempt avoids
        # any ambiguity from a previous attempt's failed/OOM-killed unit
        # still occupying its name. Failing every attempt in this budget
        # would be a genuine signal worth investigating, not noise.
        MAX_ATTEMPTS = 5
        entered_relief = False
        for attempt in range(1, MAX_ATTEMPTS + 1):
            unit = f"stress{attempt}"
            machine.succeed(
                f"systemd-run --unit={unit} --collect "
                "${pressureRampScript}/bin/nixram-test-pressure-ramp"
            )
            active_unit = unit
            try:
                # Per-attempt budget, not the old single-shot 120s: a real
                # climb-to-threshold has taken ~25-30s in every observed
                # run, and a hard OOM resolves (as a unit failure, not a
                # hang) within a few seconds -- 45s comfortably covers a
                # genuine success without wasting time on a doomed attempt.
                machine.wait_until_succeeds(
                    "test $(cat /proc/sys/vm/swappiness) -eq 60", timeout=45
                )
                entered_relief = True
                break
            except Exception as e:
                print(
                    f"attempt {attempt}/{MAX_ATTEMPTS} did not enter relief in time ({e}) -- retrying with a fresh workload"
                )
                machine.execute(f"systemctl stop {unit}")

        assert entered_relief, f"swappiness never entered relief after {MAX_ATTEMPTS} attempts"

    with subtest("pressure resolving drives swappiness back to baseline (-> 10)"):
        machine.succeed(f"systemctl stop {active_unit}")
        # avg60 (the slower, deliberately-harder-to-satisfy exit signal)
        # needs a real 60s window of calm, plus tick/slack -- see
        # rationale.md [17] for why exit uses avg60, not avg10.
        machine.wait_until_succeeds(
            "test $(cat /proc/sys/vm/swappiness) -eq 10", timeout=180
        )
  '';
}
