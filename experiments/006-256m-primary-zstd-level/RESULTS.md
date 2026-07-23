# 006 — 256M's primary: zstd level 1 vs. the documented sweet spot

**Question:** 256M is the one tier with no recompression pass, so its primary
carries density alone (`rationale.md [9]`). It shipped with `zstd(level=1)` —
the cheapest setting. Is that actually right, or does zstd's own documented
default/"sweet spot" (level 3) win instead, given `rationale.md [11]` already
claims zstd decompression speed is roughly level-invariant?

**Method:** real zram device (`/dev/zram1`, hot-added, never the host's live
`zram0` swap), `O_DIRECT` writes/reads, five real corpora reused from
experiment 005 (`heap-dict`, `heap-buffer`, `binary-elf`, `text-source`,
`random-control`), levels 1/3/6/9/12 swept, 4 reps per (corpus, level) pair,
order double-shuffled, ratio read from `mm_stat`, compress/decompress
throughput timed directly, SHA-256 round-trip verified. 100/100 trials
integrity-verified. Level is set via the kernel's `algorithm_params` sysfs
node (`algo=zstd level=N`, write-only) followed by `comp_algorithm=zstd`
— confirmed working by the monotonic ratio increase with level before
trusting any further numbers from it. A transient `EBUSY` on rapid
reset/reconfigure cycling (same failure mode noted in experiment 005)
required a short retry-with-backoff around the sysfs writes; not otherwise
investigated.

## Why this needed a real measurement, not the literature

zstd's own README states decompression is "roughly the same at all
settings," and its per-level parameter tables (`clevels.h`) show level 1 and
level 3 use identical window/hash/chain sizes below 16 KB inputs — both
facts suggestive, neither validated at zram's actual 4 KiB granularity in
zstd's own general-purpose, large-file benchmarks. This project already
learned the cost of trusting the wrong benchmark once (experiment 005's
`lzo1x_1`-vs-`lzo-rle` trap); this experiment exists so the level-1-vs-3
question doesn't repeat that mistake.

## Results (median of 4 reps)

| corpus | level | ratio | compress MB/s | decompress MB/s |
|---|---|---|---|---|
| heap-dict | 1 | 3.223 | 273.4 | 485.6 |
| heap-dict | 3 | 3.270 | 254.2 | 488.7 |
| heap-dict | 6 | 3.399 | 84.2 | 509.9 |
| heap-dict | 9 | 3.397 | 34.9 | 528.0 |
| heap-dict | 12 | 3.467 | 17.2 | 504.0 |
| heap-buffer | 1 | 3.336 | 311.9 | 508.5 |
| heap-buffer | 3 | 3.303 | 263.4 | 504.8 |
| heap-buffer | 6 | 3.329 | 90.7 | 498.6 |
| heap-buffer | 9 | 3.330 | 40.7 | 510.6 |
| heap-buffer | 12 | 3.457 | 23.5 | 536.5 |
| binary-elf | 1 | 2.045 | 240.9 | 458.9 |
| binary-elf | 3 | 2.094 | 204.8 | 445.4 |
| binary-elf | 6 | 2.136 | 71.2 | 470.0 |
| binary-elf | 9 | 2.136 | 43.8 | 461.0 |
| binary-elf | 12 | 2.240 | 18.9 | 410.6 |
| text-source | 1 | 3.212 | 246.9 | 484.5 |
| text-source | 3 | 3.303 | 213.5 | 445.3 |
| text-source | 6 | 3.457 | 74.3 | 496.0 |
| text-source | 9 | 3.465 | 37.7 | 460.5 |
| text-source | 12 | 3.494 | 16.7 | 439.4 |
| random-control | 1-12 | 1.000 | 707→29 | ~1300-1530 |

## Reading it

**Decompression speed really is flat across levels, confirmed at 4 KiB
granularity, not just borrowed from general-purpose benchmarks.** Every real
corpus stays in a ~440-540 MB/s band from level 1 through level 12, with no
consistent downward trend as level rises. This is the load-bearing fact:
whatever level 256M's primary uses, the synchronous page-fault cost is the
same.

**Level 1 → 3 is a small, close-to-free density win on the decompression
side, at a real but modest compression-side cost.** Ratio improves 1.5-2.8%
on three of four real corpora (heap-buffer is flat-to-slightly-worse,
3.336→3.303, within noise for this corpus's byte pattern), while compress
throughput drops 7-16% (e.g. heap-dict 273→254 MB/s). Compression happens
during reclaim, not on the fault path — a real cost, but a smaller one than
the flat decompression story might suggest, and nowhere near the cliff seen
later.

**The real cliff sits between level 3 and level 6, not at 1-vs-3.** Compress
throughput drops roughly 3x from level 3 to level 6 (e.g. heap-dict
254→84 MB/s) for a similar-sized ratio gain to the 1→3 step (3.270→3.399,
+3.9%). Level 9 barely improves on level 6's ratio at all (3.399→3.397,
essentially flat) while compress speed keeps falling (84→35 MB/s) — a
genuinely bad trade. Level 12 recovers a little more ratio (3.467) at
another large compress-speed cost.

## What this means for 256M's primary

**Level 3 beats level 1**: real, confirmed density gain, and it lands on the
one axis (decompression) that's actually free regardless of level, at a
modest cost on the other axis (compression, off the critical path). Level 6+
is not worth it for the *default* — the compress-side cost triples for
comparable or worse marginal ratio gain, on the single tier this project
already calls "as CPU-constrained as it is memory-constrained." Level 1
remains useful as the `zram.compressionAlgorithmOverride` fallback for a
genuinely CPU-starved box (the "0.1vCore" case) where even level 3's modest
compress-time cost isn't affordable.

**Status:** closed. Changes 256M's default primary from `zstd(level=1)` to
`zstd(level=3)` in `levels.nix`. Provides levels 3/6/9/12 ratio-per-CPU-second
data relevant to the still-open experiment 004 (recompression-tier level
sweep) but does not close it — 004's cost-cliff hypothesis is specifically
about levels ≥13's optimal-parser switch, which this sweep didn't reach.
