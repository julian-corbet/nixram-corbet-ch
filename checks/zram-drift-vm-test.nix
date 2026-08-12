# Real-kernel coverage for the resident-limit half of nixram's drift contract.
# Evaluation tests can prove that comparison code was rendered, but only a live
# zram device proves that mm_stat's fourth field and the generator's rounding
# behave as the checker expects.
{ pkgs, nixramModule }:

pkgs.testers.nixosTest {
  name = "nixram-drift-resident-limit";

  nodes.machine = { ... }: {
    imports = [ nixramModule ];
    virtualisation.memorySize = 512;
    nixram = {
      enable = true;
      level = "512M";
      mode = "zram";
      oomd.enable = false;
    };
  };

  testScript = ''
    machine.start()
    machine.wait_for_unit("multi-user.target")
    machine.succeed("systemctl is-active --quiet nixram-zram-drift.service")
    machine.succeed("systemctl is-active --quiet nixram-sysctl-reapply.service")

    expected_sysctls = {
        "vm.swappiness": "120",
        "vm.page-cluster": "0",
        "vm.vfs_cache_pressure": "200",
        "vm.watermark_scale_factor": "200",
        "vm.watermark_boost_factor": "0",
    }
    for key, expected in expected_sysctls.items():
        actual = machine.succeed(f"sysctl -n {key}").strip()
        assert actual == expected, f"{key}: got {actual}, expected {expected}"

    # Reproduce the false-success outcome directly: the declaration and unit
    # can both be green while the kernel values have drifted. The default
    # bridge must reconcile every owned value, not just swappiness.
    machine.succeed("sysctl -q -w vm.swappiness=60 vm.page-cluster=3 vm.vfs_cache_pressure=100 vm.watermark_scale_factor=10 vm.watermark_boost_factor=15000")
    machine.succeed("systemctl restart nixram-sysctl-reapply.service")
    for key, expected in expected_sysctls.items():
        actual = machine.succeed(f"sysctl -n {key}").strip()
        assert actual == expected, f"reapply failed for {key}: got {actual}, expected {expected}"

    declared = machine.succeed("awk '{ print $4 }' /sys/block/zram0/mm_stat").strip()
    assert int(declared) > 16 * 1024 * 1024

    # Any nonzero value used to pass. Prove that a live but wildly wrong cap
    # now fails loudly and does not offer the dangerous old swapoff recipe.
    machine.succeed("printf '%s' $((16 * 1024 * 1024)) > /sys/block/zram0/mem_limit")
    machine.fail("systemctl restart nixram-zram-drift.service")
    machine.succeed("journalctl -u nixram-zram-drift.service --no-pager | grep -F 'RESIDENT LIMIT MISMATCH'")
    machine.fail("journalctl -u nixram-zram-drift.service --no-pager | grep -F 'swapoff /dev/'")

    machine.succeed(f"printf '%s' {declared} > /sys/block/zram0/mem_limit")
    machine.succeed("systemctl reset-failed nixram-zram-drift.service")
    machine.succeed("systemctl restart nixram-zram-drift.service")
    machine.succeed("systemctl is-active --quiet nixram-zram-drift.service")
  '';
}
