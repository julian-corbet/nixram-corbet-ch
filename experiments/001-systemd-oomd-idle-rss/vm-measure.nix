# experiments/001-systemd-oomd-idle-rss/vm-measure.nix
#
# Measures systemd-oomd's real idle RSS on a 256M-class box, inside a
# throwaway NixOS VM (pkgs.testers.nixosTest -- nothing persists after the
# build). Boots nixram at the "256M" level with oomd.enable FORCED true
# (overriding that tier's default of false, see levels.nix), waits for the
# system to settle, then reads systemd-oomd's real RSS from
# /proc/<pid>/status and compares it against the tier's total budget.
#
# Not a pass/fail check -- a measurement. See RESULTS.md for the reading.

{ pkgs, nixramModule }:

pkgs.testers.nixosTest {
  name = "nixram-001-oomd-idle-rss";

  nodes.machine = { config, pkgs, lib, ... }: {
    imports = [ nixramModule ];
    services.nixram = {
      enable = true;
      level = "256M";
      oomd.enable = lib.mkForce true; # override the 256M default (off) to measure the cost being traded away
    };
    virtualisation.memorySize = 256;
    virtualisation.cores = 1;
  };

  testScript = ''
    machine.start()
    machine.wait_for_unit("multi-user.target")

    with subtest("systemd-oomd is actually running (override took effect)"):
        machine.succeed("systemctl is-active systemd-oomd.service")

    with subtest("let the system settle to a real idle steady state"):
        # 30s idle window -- long enough for oomd's own startup allocations
        # (reading cgroup state, opening PSI files) to finish and settle,
        # short enough to keep this a quick measurement, not a soak test.
        machine.sleep(30)

    with subtest("measure systemd-oomd's real RSS"):
        pid = machine.succeed("systemctl show -p MainPID --value systemd-oomd.service").strip()
        status = machine.succeed(f"cat /proc/{pid}/status")
        vmrss_line = [l for l in status.splitlines() if l.startswith("VmRSS:")][0]
        rss_kb = int(vmrss_line.split()[1])
        total_mib = 256
        pct = (rss_kb / 1024) / total_mib * 100
        print(f"RESULT: systemd-oomd VmRSS = {rss_kb} kB ({rss_kb/1024:.2f} MiB) on a {total_mib} MiB box = {pct:.3f}% of total RAM", flush=True)

        # Also capture total system memory actually in use at idle, for
        # context -- how much of the 256M budget is already spoken for
        # before oomd's own cost is even added.
        meminfo = machine.succeed("cat /proc/meminfo")
        total_kb = int([l for l in meminfo.splitlines() if l.startswith("MemTotal:")][0].split()[1])
        avail_kb = int([l for l in meminfo.splitlines() if l.startswith("MemAvailable:")][0].split()[1])
        used_kb = total_kb - avail_kb
        print(f"RESULT: system idle MemTotal={total_kb}kB MemAvailable={avail_kb}kB (used={used_kb}kB, {used_kb/total_kb*100:.1f}% of total)", flush=True)
  '';
}
