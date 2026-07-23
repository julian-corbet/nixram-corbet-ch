# 005 — lz4 vs lzo-rle as the fast primary

**Question:** for the redesigned fast-primary + zstd-recompression tiers
(the correction to the zstd-primary/zstd-secondary mistake nixram shipped
with — see the recompression-intent research), which fast algorithm belongs
in the primary slot: `lz4` or `lzo-rle`?

## Why real zram devices, not a userspace library

The zstd-level sweep (experiment 004, still unwritten to disk — its data
lives only in chat history from the session that ran it) tested `lzo1x_1`
via a Python compression library, believing it was testing "lzo." It
wasn't. The kernel's `lzo-rle` is a distinct backend
(`drivers/block/zram/backend_lzorle.c`) — LZO1X with explicit run-length
encoding of repeated bytes, added specifically because zero-runs are
extremely common in real memory pages. No userspace library exposes it
under that name; testing "lzo" via `python-lzo` silently measures the wrong
algorithm.

This experiment avoids that trap entirely by never reimplementing anything:
it creates real zram block devices (`/dev/zram1`, hot-added fresh —
`/dev/zram0` is the host's existing in-use zram swap and is left untouched),
sets `comp_algorithm` to `lz4` or `lzo-rle`, writes real
corpora directly to the device with `O_DIRECT`, and reads the actual
compression ratio back from `/sys/block/zram1/mm_stat` — the exact
in-kernel backend production zram would use, with zero translation layer.

## Method

- **Corpora** (captured fresh on this run; the 004 corpora were lost when
  the session scratchpad was wiped — this time everything lives in this
  directory, not `/tmp`):
  - `heap-dict` — 44.6 MB, real CPython object graph (dict-heavy: string
    keys, mixed int/str/float/bool values), captured via `/proc/self/mem`
    over its own anonymous mappings.
  - `heap-buffer` — 42.7 MB, real CPython object graph (buffer-heavy: byte
    strings with partial zero-runs, lists, path-like strings), same capture
    method, different allocation shape.
  - `binary-elf` — 10.4 MB, real ELF bytes (`python3.12` interpreter +
    linked `.so` libraries, concatenated).
  - `text-source` — 16.0 MB, real UTF-8 text (CPython stdlib `.py` files,
    concatenated).
  - `random-control` — 16.0 MB, `/dev/urandom` — incompressible sanity
    check; both algorithms must land at ratio 1.0000, or the harness is
    wrong.
- **Trials:** 5 reps × 5 corpora × 2 algorithms = 50 trials, algorithm order
  shuffled within each (corpus, rep) pair and the whole trial plan shuffled
  again — no monotonic ordering for drift to alias onto.
- **Per trial:** reset device → set `comp_algorithm` → set `disksize` to the
  corpus size → `O_DIRECT` write the whole corpus (timed, wall-clock
  compress cost) → read `mm_stat` → `O_DIRECT` read the whole device back
  (timed, wall-clock decompress cost, `O_DIRECT` forces a real decompress,
  not a page-cache hit) → SHA-256 the read-back bytes against the original
  → reset.
- **Integrity:** all 50/50 trials verified byte-identical round-trip.
  `mm_stat`'s own `orig_data_size`/`compr_data_size` accounting already
  excludes same-filled pages (short-circuited before any compressor) and
  correctly prices huge pages — no manual same-page/huge-page bookkeeping
  needed, unlike the lost 004 harness.
- **Environment:** a bare-metal x86_64 Linux host running a recent CachyOS
  kernel, measuring zram against the live host kernel (not a VM). zram is a
  host-kernel object regardless of any container boundary, hence the care
  around the existing `zram0`.

## Results

Ratio = `orig_data_size / compr_data_size` (median of 5 reps shown for
throughput; ratio is deterministic per corpus/algorithm and identical
across reps, as expected):

| corpus | lz4 ratio | lzo-rle ratio | lzo-rle vs lz4 | lz4 decomp MB/s | lzo-rle decomp MB/s | lzo-rle vs lz4 |
|---|---|---|---|---|---|---|
| heap-dict | 2.2717 | 2.4070 | +5.95% | 502.9 | 476.2 | −5.3% |
| heap-buffer | 1.7957 | 1.9301 | +7.49% | 629.9 | 475.9 | −24.5% |
| binary-elf | 1.8606 | 1.9134 | +2.84% | 474.2 | 363.5 | −23.3% |
| text-source | 2.0152 | 2.1218 | +5.29% | 516.2 | 398.7 | −22.8% |
| random-control | 1.0000 | 1.0000 | +0.00% | 473.8 | 508.3 | +7.3% |

(Compress-side throughput is noisier — a shared 4-CPU cgroup budget on a
live cluster node — and the two algorithms are close enough there that it
doesn't change the conclusion; decompress is the number that matters most
for a swap primary, since it sits on the synchronous page-fault path.)

## Reading it

**lzo-rle wins density, every time, on real memory content** (+2.8% to
+7.5%). **lz4 wins decompression speed, every time except the pure-noise
control** (12–25% faster on 3 of 4 real corpora). This is the textbook
lz4-vs-lzo trade-off, now confirmed on this box with real kernel backends
instead of assumed from documentation.

The random-control row is doing its job as a sanity check (ratio 1.0000 on
both — nothing is being compressed that shouldn't be) and incidentally
shows lzo-rle's fast-reject path beats lz4's on pure noise; irrelevant to
the tier decision since real memory is never shaped like `/dev/urandom` in
aggregate.

## What this means for the primary choice

For tiers running the corrected fast-primary + zstd-recompression design:
the primary's job is to be cheap on the hot path, because zstd-recompress
recovers density later (that pass alone is worth ~20–28%, per the
recompression-intent research — an order of magnitude more than lzo-rle's
~3–7% edge over lz4). Decompression latency is the one primary-slot cost
that recompression *cannot* paper over — it's paid on every page fault, and
the module's stated purpose ("scrape the barrel — even with a big barrel")
means these are exactly the boxes where page faults under pressure are
common. That argues for **lz4 as the uniform primary** on every tier that
gets a zstd-recompression pass, not the size-dependent lz4-then-lzo-rle
split that seemed reasonable before this measurement.

lzo-rle only earns its keep on a primary that will *never* get a
recompression pass (the 256M tier, and the 64G/128G tier if it keeps a
dense zstd primary and drops recompression per the Option B alternative) —
and in both those cases the audit already points to a dense algorithm
(`zstd`) as primary anyway, not a fast one, so lzo-rle doesn't get a slot in
either design.

**Status:** closed. Feeds the primary/recompression redesign once it's
implemented in `levels.nix`.
