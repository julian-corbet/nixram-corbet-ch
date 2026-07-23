# 004 — idle-tier compression level sweep

**Question:** where does the ratio-per-CPU-second curve actually flatten for
recompressing 4 KiB zram pages with zstd — is `level=12`, nixram's ORIGINAL
default for idle-tier recompression when this experiment was first framed,
the right stopping point? The design has since simplified the recompression
default to a uniform `zstd(level=3)` (the same setting also used as
256M/512M/1G's primary) as a deliberate simplification, not a re-measurement
(`rationale.md [11]`) — so whether recompression on genuinely idle, off-path
pages would actually benefit from going denser than that level=3 default was
the open part of this question.

**Method:** a real, ephemeral NixOS VM (`pkgs.testers.nixosTest`, nothing
persists after the build), not real hardware — corrected mid-session after
direct feedback that kernel/device experiments (loading the `zram` module,
hot-adding a device) belong in a disposable VM, never on a live host, even
when the specific action looks safe. Inside the VM: a scratch `/dev/zram1`
(never `zram0`), `O_DIRECT` writes/reads, five real corpora captured fresh
inside the guest (two heap shapes via `/proc/self/mem` dumps, real ELF bytes
from the guest's own `/nix/store` binaries, real text from nixpkgs' own `.nix`
source tree, and a genuinely random incompressible control), levels
3/6/9/12/15/19 swept, 4 reps per (corpus, level) pair, order double-shuffled,
ratio read from `mm_stat`, throughput timed directly, SHA-256 round-trip
verified. **120/120 trials integrity-verified.** See `vm-bench.nix`.

One methodology note, stated plainly: the `text-source` corpus ended up only
~1.1 MB (273 pages) instead of the ~64 MB target — the glob against the
guest's nixpkgs `lib/` tree found less real `.nix` text than expected. Still
real, non-synthetic content, still run through all 6 levels × 4 reps (24
trials, all integrity-verified) — just a smaller sample than the other four
corpora. Its numbers track the other three real-content corpora closely
enough that this doesn't change the reading below, but it's a real gap in
corpus size, not swept under the rug.

## Results (median of 4 reps, ratio = orig/compressed)

| corpus | level=3 | level=6 | level=9 | level=12 | level=15 | level=19 |
|---|---|---|---|---|---|---|
| heap-dict | 3.259 | 3.374 | 3.371 | 3.443 | 3.474 | 3.485 |
| heap-buffer | 3.087 | 3.149 | 3.147 | 3.251 | 3.275 | 3.284 |
| binary-elf | 1.831 | 1.870 | 1.870 | 1.936 | 1.953 | 1.960 |
| text-source | 3.037 | 3.181 | 3.188 | 3.211 | 3.232 | 3.242 |
| random-control | 1.000 | 1.000 | 1.000 | 1.000 | 1.000 | 1.000 |

Compress throughput collapses steadily across the same range regardless of
corpus (heap-dict: 316 → 112 → 36 → 19 → 9.5 → 4.9 MB/s from level 3 to 19 —
roughly halving at every step from 9 onward). Decompress throughput stays
flat throughout (670-770 MB/s across all six levels on every real corpus),
confirming 006's finding again at a wider level range: decompression cost is
level-invariant at 4 KiB granularity.

## Reading it

**The curve keeps rising through level 12, then genuinely flattens.** Every
real corpus gains real, measurable ratio from level 3 through level 12 (e.g.
heap-dict +5.6% total, binary-elf +5.7%) — this is the range 006 already
covered and closed for the PRIMARY algorithm, but it's relevant here too since
recompression was simplified to reuse that same level.

**Past level 12, the story changes completely.** 12→15→19 buys heap-dict
only +0.9% then +0.3% more ratio, binary-elf +0.9% then +0.4%, while compress
throughput keeps roughly halving at each step (heap-dict 18.7 → 9.5 → 4.9
MB/s). `random-control` makes the waste explicit: its ratio is pinned at
1.000 across all six levels — every one of those halvings in compress speed
beyond level 12 buys literally nothing on data that can't compress, and only
marginal fractions of a percent on data that can. This closes the question
004 was framed around: level 12 (or thereabouts) really is close to the
practical ceiling for 4 KiB zram pages; levels 15 and 19 are not worth it,
even for a CPU-idle-gated background pass where compress cost matters far
less than on the primary path.

**The more useful finding is upstream of that, though.** The CURRENT
recompression default is `zstd(level=3)` — the same cheap setting as the
primary, adopted for uniformity (`rationale.md [11]`), not because level=3
was ever shown to be the right density target for a pass that only runs when
the CPU is otherwise idle. This sweep shows a real, measured gap between
level=3 and level=9-12 on every real corpus (heap-dict alone: 3.259 → 3.371 →
3.443, a genuine +5.6% by level 12) — density the recompression pass is
currently leaving on the table for no reason that holds up under measurement.
Recompression is exactly the case where that gap is closeable for free: it
only runs when CPU PSI shows genuine idleness (`modules/zram.nix`'s idle
gate), so the compress-side cost that makes level=12 a bad idea for the
*primary* path doesn't apply the same way here — idle cycles are, by
definition, cycles nothing else wants.

Between level 9 and level 12 specifically: the 6→9 step is flat-to-noise on
every corpus (heap-dict 3.374→3.371, essentially unchanged), while 9→12 gives
a real further gain (+2.1% on heap-dict) for roughly 2x more compress cost
(35.9→18.7 MB/s on heap-dict) — a cost that stays trivial in absolute terms
for a background pass regardless (recompressing a realistic idle-marked
batch takes single-digit seconds of idle CPU either way).

## What this means for the design

**Recommendation, not yet applied without review:** raise the reluctant
tiers' (2G-128G) recompression algorithm from `zstd(level=3)` back toward
`zstd(level=12)` — reversing the "uniform level=3" simplification
specifically for the RECOMPRESSION pass, while leaving every tier's PRIMARY
algorithm exactly as 006 already closed it (`zstd(level=3)` alone at
256M/512M/1G, `lz4` at 2G-128G). This is a genuine architecture change (undoes
part of a deliberate prior simplification), not a mechanical config tweak —
flagged clearly for review rather than silently applied, even though this
project's own precedent (005, 006) is to update `levels.nix` directly once an
experiment closes with a clear numeric answer.

**Status:** closed. Levels 15/19 conclusively rule out going denser than ~12
for idle-tier recompression on 4 KiB pages, on any of the corpora tested.
Whether to act on the level=3→12 recompression-density recommendation above
is the one open follow-up from this experiment.
