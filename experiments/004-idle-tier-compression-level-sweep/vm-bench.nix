# experiments/004-idle-tier-compression-level-sweep/vm-bench.nix
#
# Runs experiment 004 entirely inside a throwaway NixOS VM (pkgs.testers.nixosTest
# -- nothing persists after the build) rather than on any real host. Earlier
# experiments (005, 006) hot-added a scratch /dev/zram1 on real hardware; that
# needed a kernel module load (`modprobe zram`) on a live, shared machine.
# Corrected after direct feedback: kernel/device experiments belong in a
# disposable VM, never on a real host, even when the specific action looks
# safe (see feedback_vm_experiments_not_live_host in Claude's own memory).
# Everything below -- the zram module, the corpora, the benchmark -- exists
# only inside the ephemeral guest and is discarded when the build finishes.
#
# Same core methodology as 005/006: real zram device, O_DIRECT writes/reads,
# ratio read from mm_stat, throughput timed directly, SHA-256 round-trip
# verified. The corpora are freshly generated inside this VM rather than
# reusing 005/006's exact byte-for-byte files (those lived in /tmp on the
# host and no longer exist) -- same five shapes (two heap patterns, real ELF
# bytes, real text, incompressible random control), same target size, so the
# ratios and trends are comparable in spirit even though absolute throughput
# numbers are not directly comparable to bare-metal 006 (this runs under
# QEMU virtualization).

{ pkgs, nixpkgs }:

let
  benchScript = pkgs.writeText "nixram-004-bench.py" ''
    import glob, hashlib, mmap, os, random, re, string, sys, time

    DEVICE = "/sys/block/zram1"
    DEV_NODE = "/dev/zram1"
    LEVELS = [3, 6, 9, 12, 15, 19]
    REPS = 4
    TARGET_BYTES = 64 * 1024 * 1024
    PAGE = 4096

    def make_heap_dict(seed=42):
        rnd = random.Random(seed)
        keep = []
        for _ in range(40000):
            d = {}
            for _ in range(rnd.randint(3, 12)):
                k = "".join(rnd.choices(string.ascii_lowercase, k=rnd.randint(4, 12)))
                v = rnd.choice([
                    rnd.randint(0, 1 << 30),
                    "".join(rnd.choices(string.ascii_letters + string.digits, k=rnd.randint(5, 40))),
                    rnd.random(), None, True,
                ])
                d[k] = v
            keep.append(d)
        return keep

    def make_heap_buffer(seed=42):
        rnd = random.Random(seed)
        keep = []
        for _ in range(6000):
            n = rnd.randint(200, 4000)
            header = bytes([0] * rnd.randint(0, 64))
            payload = bytes(rnd.getrandbits(8) if rnd.random() < 0.6 else 0 for _ in range(n))
            keep.append(header + payload)
            keep.append(list(range(rnd.randint(10, 500))))
            keep.append("/".join("seg%d" % rnd.randint(0, 999) for _ in range(rnd.randint(2, 8))))
        return keep

    def dump_anon_regions(target_bytes):
        regions = []
        with open("/proc/self/maps") as f:
            for line in f:
                m = re.match(r"([0-9a-f]+)-([0-9a-f]+) (\S+)", line)
                if not m:
                    continue
                perms = m.group(3)
                parts = line.strip().split(None, 5)
                pathname = parts[5] if len(parts) > 5 else ""
                if "r" not in perms:
                    continue
                if pathname and not pathname.startswith("["):
                    continue
                regions.append((int(m.group(1), 16), int(m.group(2), 16)))
        out = bytearray()
        with open("/proc/self/mem", "rb", 0) as memf:
            for start, end in regions:
                if len(out) >= target_bytes:
                    break
                size = end - start
                if size <= 0 or size > 512 * 1024 * 1024:
                    continue
                try:
                    memf.seek(start)
                    out.extend(memf.read(size))
                except OSError:
                    continue
        return bytes(out[: (len(out) // PAGE) * PAGE])

    def gen_heap_corpus(shape, path):
        keep = make_heap_dict() if shape == "dict" else make_heap_buffer()
        data = dump_anon_regions(TARGET_BYTES)
        with open(path, "wb") as f:
            f.write(data)
        globals()["_keep_alive_%s" % shape] = keep
        return len(data)

    def gen_concat_corpus(paths, out_path, target):
        buf = bytearray()
        for p in paths:
            if len(buf) >= target:
                break
            try:
                with open(p, "rb") as f:
                    buf.extend(f.read())
            except OSError:
                continue
        n = (min(len(buf), target) // PAGE) * PAGE
        with open(out_path, "wb") as f:
            f.write(bytes(buf[:n]))
        return n

    def gen_random_corpus(path, target):
        n = (target // PAGE) * PAGE
        with open(path, "wb") as f:
            f.write(os.urandom(n))
        return n

    def build_corpora():
        corpora = {}
        n = gen_heap_corpus("dict", "/tmp/heap-dict.bin")
        corpora["heap-dict"] = ("/tmp/heap-dict.bin", n)
        n = gen_heap_corpus("buffer", "/tmp/heap-buffer.bin")
        corpora["heap-buffer"] = ("/tmp/heap-buffer.bin", n)

        elf_paths = sorted(glob.glob("/nix/store/*-coreutils-*/bin/*")) + \
            sorted(glob.glob("/nix/store/*-systemd-*/bin/*")) + \
            sorted(glob.glob("/nix/store/*-python3-*/bin/*"))
        n = gen_concat_corpus(elf_paths, "/tmp/binary-elf.bin", TARGET_BYTES)
        corpora["binary-elf"] = ("/tmp/binary-elf.bin", n)

        text_paths = []
        for root, _dirs, files in os.walk(os.environ["NIXPKGS_LIB"]):
            for fn in files:
                if fn.endswith(".nix"):
                    text_paths.append(os.path.join(root, fn))
        text_paths.sort()
        n = gen_concat_corpus(text_paths, "/tmp/text-source.bin", TARGET_BYTES)
        corpora["text-source"] = ("/tmp/text-source.bin", n)

        n = gen_random_corpus("/tmp/random-control.bin", TARGET_BYTES)
        corpora["random-control"] = ("/tmp/random-control.bin", n)

        for name, (path, n) in corpora.items():
            print("corpus %s: %d bytes (%d pages)" % (name, n, n // PAGE), flush=True)
        return corpora

    def write_sysfs(name, value, retries=10):
        for attempt in range(retries):
            try:
                with open(os.path.join(DEVICE, name), "w") as f:
                    f.write(str(value))
                return
            except OSError as e:
                if e.errno == 16 and attempt < retries - 1:
                    time.sleep(0.2)
                    continue
                raise

    def read_sysfs(name):
        with open(os.path.join(DEVICE, name)) as f:
            return f.read().strip()

    def read_mm_stat():
        raw = read_sysfs("mm_stat").split()
        fields = [
            "orig_data_size", "compr_data_size", "mem_used_total", "mem_limit",
            "mem_used_max", "same_pages", "pages_compacted", "huge_pages", "huge_pages_since",
        ]
        return dict(zip(fields, (int(x) for x in raw)))

    def run_trial(corpus_name, path, size, level):
        with open(path, "rb") as f:
            data = f.read(size)
        buf = mmap.mmap(-1, size)
        buf.write(data)
        buf.seek(0)
        expect_digest = hashlib.sha256(data).hexdigest()

        write_sysfs("reset", 1)
        write_sysfs("algorithm_params", "algo=zstd level=%d" % level)
        write_sysfs("comp_algorithm", "zstd")
        write_sysfs("disksize", size)

        fd = os.open(DEV_NODE, os.O_WRONLY | os.O_DIRECT)
        buf.seek(0)
        t0 = time.perf_counter()
        written = os.write(fd, buf)
        os.fsync(fd)
        t1 = time.perf_counter()
        os.close(fd)
        compress_seconds = t1 - t0

        stat = read_mm_stat()

        read_buf = mmap.mmap(-1, size)
        fd = os.open(DEV_NODE, os.O_RDONLY | os.O_DIRECT)
        t0 = time.perf_counter()
        got = os.readv(fd, [read_buf])
        t1 = time.perf_counter()
        os.close(fd)
        decompress_seconds = t1 - t0

        read_buf.seek(0)
        got_bytes = read_buf.read(size)
        got_digest = hashlib.sha256(got_bytes).hexdigest()
        integrity_ok = (got_digest == expect_digest) and (written == size) and (got == size)

        write_sysfs("reset", 1)
        buf.close()
        read_buf.close()

        return {
            "corpus": corpus_name, "level": level, "corpus_bytes": size,
            "compress_seconds": compress_seconds, "decompress_seconds": decompress_seconds,
            "compress_MBps": (size / 1024 / 1024) / compress_seconds,
            "decompress_MBps": (size / 1024 / 1024) / decompress_seconds,
            "orig_data_size": stat["orig_data_size"], "compr_data_size": stat["compr_data_size"],
            "mem_used_total": stat["mem_used_total"],
            "ratio_orig_over_compr": stat["orig_data_size"] / stat["compr_data_size"],
            "integrity_ok": integrity_ok,
        }

    def main():
        corpora = build_corpora()
        plan = []
        for _rep in range(REPS):
            for corpus_name, (path, size) in corpora.items():
                shuffled = LEVELS[:]
                random.shuffle(shuffled)
                for level in shuffled:
                    plan.append((corpus_name, path, size, level))
        random.shuffle(plan)

        results = []
        for i, (corpus_name, path, size, level) in enumerate(plan):
            r = run_trial(corpus_name, path, size, level)
            results.append(r)
            print("[%d/%d] %-15s level=%-3d ratio=%.4f comp=%.1fMB/s decomp=%.1fMB/s ok=%s" % (
                i + 1, len(plan), corpus_name, level,
                r["ratio_orig_over_compr"], r["compress_MBps"], r["decompress_MBps"], r["integrity_ok"],
            ), flush=True)

        import json
        with open("/tmp/results-004.json", "w") as f:
            json.dump(results, f, indent=2)

        failed = [r for r in results if not r["integrity_ok"]]
        print("RESULT-SUMMARY: %d/%d trials integrity-verified" % (len(results) - len(failed), len(results)), flush=True)
        if failed:
            print("INTEGRITY FAILURES: %d" % len(failed), flush=True)
            sys.exit(1)

        by_level = {}
        for r in results:
            by_level.setdefault(r["level"], []).append(r["ratio_orig_over_compr"])
        for level in LEVELS:
            ratios = by_level.get(level, [])
            avg = sum(ratios) / len(ratios) if ratios else 0.0
            print("LEVEL-AVG level=%d avg_ratio=%.4f n=%d" % (level, avg, len(ratios)), flush=True)

    if __name__ == "__main__":
        main()
  '';
in

pkgs.testers.nixosTest {
  name = "nixram-004-recompression-level-sweep";

  nodes.machine = { config, pkgs, lib, ... }: {
    virtualisation.memorySize = 2048;
    virtualisation.cores = 4;
    environment.systemPackages = [ pkgs.python3 ];
    boot.kernelModules = [ "zram" ];
    boot.extraModprobeConfig = "options zram num_devices=2";
  };

  testScript = ''
    machine.start()
    machine.wait_for_unit("multi-user.target")

    with subtest("zram module loaded, scratch zram1 available (never zram0)"):
        machine.succeed("modprobe zram || true")
        machine.succeed("test -e /sys/block/zram1")

    with subtest("run the level sweep"):
        # machine.succeed() captures the command's stdout as a return value
        # but does not echo it into the build log on its own -- print() it
        # explicitly so the per-trial and summary lines actually land here.
        output = machine.succeed(
            "NIXPKGS_LIB=${nixpkgs}/lib python3 ${benchScript} 2>&1"
        )
        print(output)
  '';
}
