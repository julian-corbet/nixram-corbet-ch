import hashlib
import json
import mmap
import os
import random
import time

DEVICE = "/sys/block/zram1"
DEV_NODE = "/dev/zram1"
LEVELS = [1, 3, 6, 9, 12]
CORPORA = {
    "heap-dict": "/tmp/heap-dict.bin",
    "heap-buffer": "/tmp/heap-buffer.bin",
    "binary-elf": "/tmp/binary-elf.bin",
    "text-source": "/tmp/text-source.bin",
    "random-control": "/tmp/random-control.bin",
}
REPS = 4


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


def load_corpus(path):
    size = os.path.getsize(path)
    buf = mmap.mmap(-1, size)
    with open(path, "rb") as f:
        data = f.read()
    buf.write(data)
    buf.seek(0)
    digest = hashlib.sha256(data).hexdigest()
    return buf, size, digest


def run_trial(corpus_name, path, level):
    buf, size, expect_digest = load_corpus(path)

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
        "corpus": corpus_name,
        "level": level,
        "corpus_bytes": size,
        "compress_seconds": compress_seconds,
        "decompress_seconds": decompress_seconds,
        "compress_MBps": (size / 1024 / 1024) / compress_seconds,
        "decompress_MBps": (size / 1024 / 1024) / decompress_seconds,
        "orig_data_size": stat["orig_data_size"],
        "compr_data_size": stat["compr_data_size"],
        "mem_used_total": stat["mem_used_total"],
        "ratio_orig_over_compr": stat["orig_data_size"] / stat["compr_data_size"],
        "integrity_ok": integrity_ok,
    }


def main():
    plan = []
    for _rep in range(REPS):
        for corpus_name, path in CORPORA.items():
            shuffled_levels = LEVELS[:]
            random.shuffle(shuffled_levels)
            for level in shuffled_levels:
                plan.append((corpus_name, path, level))
    random.shuffle(plan)

    results = []
    for i, (corpus_name, path, level) in enumerate(plan):
        r = run_trial(corpus_name, path, level)
        results.append(r)
        print("[%d/%d] %-15s level=%-3d ratio=%.4f comp=%.1fMB/s decomp=%.1fMB/s ok=%s" % (
            i + 1, len(plan), corpus_name, level,
            r["ratio_orig_over_compr"], r["compress_MBps"], r["decompress_MBps"], r["integrity_ok"],
        ))

    with open("/tmp/level_results.json", "w") as f:
        json.dump(results, f, indent=2)


if __name__ == "__main__":
    main()
