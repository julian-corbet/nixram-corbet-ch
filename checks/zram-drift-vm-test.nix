# Real-kernel coverage for nixram's no-resident-cap safety contract. Evaluation
# tests prove the generator setting is absent; a live zram device proves both
# that mm_stat reports unlimited and that a stale cap can be lifted in place.
{ pkgs, nixramModule }:

pkgs.testers.nixosTest {
  name = "nixram-zram-unlimited";

  nodes.machine = { config, lib, pkgs, ... }: {
    imports = [ nixramModule ];

    options.nixramTest.oldResidentCap = lib.mkOption {
      type = lib.types.bool;
      default = true;
    };

    config = lib.mkMerge [
      {
        virtualisation.memorySize = 768;
        environment.systemPackages = [ pkgs.python3 ];

        # Boot the old contract: same size/algorithm as the new 1G-rounded
        # policy, but with the unsafe resident key present. The specialisation
        # below disables only this conditional definition and enables nixram,
        # giving switch-to-configuration a real key-removal transition.
        nixram = {
          enable = false;
          level = "1G";
          mode = "zram";
          oomd.enable = false;
        };
        services.zram-generator = {
          enable = true;
          settings.zram0 = {
            zram-size = "ram";
            compression-algorithm = "zstd(level=3)";
            swap-priority = 100;
          };
        };

        specialisation.nixram-new.configuration = {
          nixramTest.oldResidentCap = lib.mkForce false;
          nixram.enable = lib.mkForce true;
        };
      }

      (lib.mkIf config.nixramTest.oldResidentCap {
        services.zram-generator.settings.zram0.zram-resident-limit = "ram / 2";
      })
    ];
  };

  testScript = ''
    machine.start()
    machine.wait_for_unit("multi-user.target")

    old_limit = machine.succeed("awk '{ print $4 }' /sys/block/zram0/mm_stat").strip()
    assert int(old_limit) > 0
    old_uuid = machine.succeed("blkid -s UUID -o value /dev/zram0").strip()
    old_size = machine.succeed("cat /sys/block/zram0/disksize").strip()

    # Force genuine swap use and keep the allocating process alive across the
    # switch. If systemd-zram-setup@ were restarted, this process would lose its
    # swap backing or be killed by the implicit swapoff.
    machine.succeed("systemd-run --unit=nixram-test-load --property=MemoryMax=700M python3 -c 'import time; x=bytearray(650*1024*1024); x[::4096]=b\"x\"*(len(x[::4096])); time.sleep(600)'")
    machine.wait_until_succeeds("awk '$1 == \"/dev/zram0\" && $4 > 0 { found=1 } END { exit !found }' /proc/swaps")
    load_pid = machine.succeed("systemctl show -p MainPID --value nixram-test-load.service").strip()

    machine.succeed("/run/current-system/specialisation/nixram-new/bin/switch-to-configuration switch", timeout=120)
    machine.wait_for_unit("multi-user.target")
    machine.succeed("systemctl is-active --quiet nixram-zram-drift.service")
    machine.succeed("systemctl is-active --quiet nixram-sysctl-reapply.service")

    assert machine.succeed("blkid -s UUID -o value /dev/zram0").strip() == old_uuid
    assert machine.succeed("cat /sys/block/zram0/disksize").strip() == old_size
    assert machine.succeed("systemctl show -p MainPID --value nixram-test-load.service").strip() == load_pid
    machine.succeed("kill -0 " + load_pid)
    machine.succeed("awk '$1 == \"/dev/zram0\" && $4 > 0 { found=1 } END { exit !found }' /proc/swaps")
    machine.fail("journalctl --since='1 minute ago' --no-pager -u 'systemd-zram-setup@zram0.service' | grep -F 'Stopped Create swap'")

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

    resident_limit = machine.succeed("awk '{ print $4 }' /sys/block/zram0/mm_stat").strip()
    assert resident_limit == "0", f"nixram booted with unsafe mem_limit={resident_limit}"

    # Reproduce stale state from the old generation. Restarting the checker must
    # lift it in place, without swapoff or device recreation, and remain green.
    machine.succeed("printf '%s' $((16 * 1024 * 1024)) > /sys/block/zram0/mem_limit")
    machine.succeed("systemctl restart nixram-zram-drift.service")
    machine.succeed("journalctl -u nixram-zram-drift.service --no-pager | grep -F 'UNSAFE RESIDENT LIMIT APPLIED'")
    machine.succeed("awk '{ exit ($4 == 0 ? 0 : 1) }' /sys/block/zram0/mm_stat")
    machine.fail("journalctl -u nixram-zram-drift.service --no-pager | grep -F 'swapoff /dev/'")

    # Kernel-level adversarial proof: the same zram device accepts writes with
    # no artificial cap and rejects them once mem_limit is crossed. This guards
    # against reintroducing the old assumption that mem_limit is graceful.
    extra = machine.succeed("zramctl --find --size 64M").strip()
    machine.succeed(f"dd if=/dev/urandom of={extra} bs=4K count=4096 oflag=direct status=none")
    machine.succeed(f"zramctl --reset {extra}")
    extra = machine.succeed("zramctl --find --size 64M").strip()
    name = extra.rsplit('/', 1)[-1]
    machine.succeed(f"printf '%s' $((1024 * 1024)) > /sys/block/{name}/mem_limit")
    machine.fail(f"dd if=/dev/urandom of={extra} bs=4K count=4096 oflag=direct status=none")
  '';
}
