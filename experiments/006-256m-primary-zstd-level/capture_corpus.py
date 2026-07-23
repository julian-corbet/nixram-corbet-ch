import mmap, os, random, re, string, sys

TARGET_BYTES = 64 * 1024 * 1024
PAGE = 4096

def make_heap_objects(shape, seed):
    rnd = random.Random(seed)
    keep = []
    if shape == "dict_heavy":
        for _ in range(40000):
            d = {}
            for _ in range(rnd.randint(3, 12)):
                k = "".join(rnd.choices(string.ascii_lowercase, k=rnd.randint(4, 12)))
                v = rnd.choice([
                    rnd.randint(0, 1 << 30),
                    "".join(rnd.choices(string.ascii_letters + string.digits, k=rnd.randint(5, 40))),
                    rnd.random(),
                    None,
                    True,
                ])
                d[k] = v
            keep.append(d)
    elif shape == "buffer_heavy":
        for _ in range(6000):
            n = rnd.randint(200, 4000)
            # realistic mixed-entropy buffers: structured header + semi-random payload
            header = bytes([0] * rnd.randint(0, 64))
            payload = bytes(rnd.getrandbits(8) if rnd.random() < 0.6 else 0 for _ in range(n))
            keep.append(header + payload)
            keep.append(list(range(rnd.randint(10, 500))))
            keep.append("/".join("seg%d" % rnd.randint(0, 999) for _ in range(rnd.randint(2, 8))))
    else:
        raise SystemExit("unknown shape")
    return keep

def dump_anon_regions(target_bytes):
    maps_path = "/proc/self/maps"
    mem_path = "/proc/self/mem"
    regions = []
    with open(maps_path) as f:
        for line in f:
            m = re.match(r"([0-9a-f]+)-([0-9a-f]+) (\S+)", line)
            if not m:
                continue
            perms = m.group(3)
            path_part = line.strip().split(None, 5)
            pathname = path_part[5] if len(path_part) > 5 else ""
            if "r" not in perms:
                continue
            if pathname and not pathname.startswith("[") :
                continue  # skip file-backed mappings (binary/libs), keep anon + heap + stack-like
            start = int(m.group(1), 16)
            end = int(m.group(2), 16)
            regions.append((start, end))

    out = bytearray()
    with open(mem_path, "rb", 0) as memf:
        for start, end in regions:
            if len(out) >= target_bytes:
                break
            size = end - start
            if size <= 0 or size > 512 * 1024 * 1024:
                continue
            try:
                memf.seek(start)
                chunk = memf.read(size)
            except OSError:
                continue
            out.extend(chunk)
    return bytes(out[: (len(out) // PAGE) * PAGE])

def main():
    shape = sys.argv[1]
    outpath = sys.argv[2]
    keep = make_heap_objects(shape, seed=42)
    data = dump_anon_regions(TARGET_BYTES)
    with open(outpath, "wb") as f:
        f.write(data)
    print("shape=%s bytes=%d pages=%d" % (shape, len(data), len(data) // PAGE))
    # keep `keep` alive until after dump
    globals()["_keep_alive"] = keep

if __name__ == "__main__":
    main()
