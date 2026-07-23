# Experiments

The ledger of open questions behind nixram's extrapolated (◐) values. Every
entry here corresponds to a judgment call flagged in `levels.nix` and
`docs/rationale.md` as reasoned-but-unmeasured. Results feed back into
`levels.nix` as tag upgrades — extrapolated becomes measured (or sourced,
if the measurement confirms an existing upstream number) once an experiment
closes.

Status is `open` for 002 and 003; 001, 004, 005, and 006 have been run and
are closed, feeding their results back into `levels.nix`.

## 001 — systemd-oomd idle RSS on a 256M box

**Question:** is disabling `oomd.enable` at the 256M level actually the
right trade?

**Hypothesis:** systemd-oomd's own idle resident-memory footprint on a 256M
box is large enough, relative to total RAM, that running it costs more
headroom than its PSI-based early-warning protection is worth at that tier.

**Method:** a real, ephemeral NixOS VM (`pkgs.testers.nixosTest`, nothing
persists after the build) booted at nixram's "256M" level with `oomd.enable`
force-overridden to `true`, 30s idle settle window, `systemd-oomd`'s real
`VmRSS` read from `/proc/<pid>/status`. See
[`001-systemd-oomd-idle-rss/RESULTS.md`](001-systemd-oomd-idle-rss/RESULTS.md).

**Result:** 4.77 MiB VmRSS on a 256 MiB box (1.86% of total RAM, 6.2% of the
tier's own resident-limit budget) — real and measurable, not negligible, but
the more striking number is that the box is already at 51.5% idle memory
usage before oomd is even added. Supports the existing default for a sharper
reason than before: on a box where more than half of RAM is already baseline
overhead at idle, oomd's own ~2% permanent tax is a real subtraction from the
exact headroom it exists to protect.

**Status:** closed. `levels.nix`'s 256M `oomd.enable = false` note upgrades
from "extrapolated, DELIBERATE, unmeasured" to "extrapolated, DELIBERATE,
own-measured." See
[`docs/rationale.md` \[8\]](../docs/rationale.md#8-systemd-oomd-disabled-at-256m).

## 002 — idle-recompression cadence

**Question:** does nixram's idle-recompression timer's check frequency and
PSI-idleness gate actually maximize recompressed bytes reclaimed without
wasting CPU on pages that get touched again before they'd have been
recompressed anyway?

**Hypothesis:** this question was first framed when the timer ran on a
fixed "daily" calendar cadence — since redesigned into a check-frequency
plus idle-gate model instead (default: check every 15 minutes via
`onCalendar = "*:0/15"`, but only act if CPU PSI's "some" avg10 line is
genuinely low; see `rationale.md [11]`). The open part of the original
question survives the redesign unchanged: is 15 minutes, and the specific
idleness threshold, actually the cadence that maximizes recompressed bytes
per CPU-second, or would a different check interval change the outcome,
given the two-phase mark/recompress design's effective dwell period is now
a function of how often the idle gate actually opens rather than a fixed
calendar spacing.

**Method sketch:** instrument the recompression script to log bytes
recompressed per run against `zram0/mm_stat`, sweep the check interval
(`zram.recompressionTimer.onCalendar`) and the PSI idleness threshold
across a range on a representative sustained workload, and compare
recompressed-bytes-per-CPU-second across settings.

**Status:** open. See
[`docs/rationale.md` \[11\]](../docs/rationale.md#11-idle-recompression-zstdlevel3-gated-on-genuine-idleness).

## 003 — swappiness sweep on a jampacked server

**Question:** does a higher swappiness value actually beat a lower one on
tail-latency (p99) under steady memory pressure, for a long-uptime server
tier?

**Hypothesis:** this question was first framed around `vm.swappiness = 180`
— Pop!_OS's own zram default and nixram's very first, single flat value,
before the eager/reluctant tier split existed. 180 is no longer used
anywhere in the project: the eager tiers (256M/512M/1G) moved 180 → 130
(adversarially revised) → 120 (Julian's own further direct revision), while
the reluctant tiers (2G-128G) moved straight from the kernel's plain 60
default to 10 at rest (Julian's own real historical data point, the fleet's
old Unraid server), now paired with a PSI-gated relief valve that
temporarily raises swappiness to 60 during genuine, sustained pressure. The
reluctant tiers' resting value is no longer an open sweep target in the
original sense — 10 is a directed data point, not an extrapolation needing
this kind of validation. What remains genuinely open is whether the eager
tiers' 120, or the relief valve's specific thresholds
(`pressureHighThreshold`/`pressureLowThreshold`/`checkIntervalSec`), are
actually optimal on tail latency under sustained pressure.

**Method sketch:** run a fixed memory-pressure workload (e.g. a working set
sized to force sustained swap activity) at a range of swappiness values
around the eager tiers' 120 on an otherwise identical zram configuration,
and compare p50/p99 request latency and PSI stall time; separately, sweep
the relief valve's thresholds and check interval to see whether it
engages/disengages at the right moments under the same workload.

**Status:** open. See
[`docs/rationale.md` \[3\]](../docs/rationale.md#3-vmswappiness-120-256m-1g-10-at-rest--relief-gated-2g-128g-zswap-25).

## 005 — lz4 vs lzo-rle as the fast primary

**Question:** for the redesigned fast-primary + zstd-recompression tiers,
which fast algorithm belongs in the primary slot: `lz4` or `lzo-rle`?

**Hypothesis:** lzo-rle's run-length encoding of zero-runs should make it
denser than lz4 on real memory pages; lz4 should decompress faster. Which
one matters more depends on whether the tier also runs zstd recompression
(density recoverable later → speed matters more for the primary) or not
(density must come from the primary alone).

**Method:** real zram devices (`/dev/zram1`+, never the host's live
`zram0`), `O_DIRECT` writes/reads of real corpora (CPython heap objects,
ELF bytes, text, incompressible control), ratio read from `mm_stat`,
throughput timed directly, byte-identical round-trip verified. See
[`005-lz4-vs-lzo-rle-primary/RESULTS.md`](005-lz4-vs-lzo-rle-primary/RESULTS.md).

**Result:** lzo-rle is 2.8–7.5% denser on every real corpus; lz4
decompresses 12–25% faster on 3 of 4. Recommendation: `lz4` as the uniform
primary on every tier that also runs zstd recompression (density recovered
downstream is worth an order of magnitude more than lzo-rle's edge); the
three tiers without a recompression pass (256M/512M/1G) already point to a
dense `zstd` primary instead, so lzo-rle doesn't get a slot in the
corrected design.

**Status:** closed.

## 006 — 256M's primary: zstd level 1 vs. the documented sweet spot

**Question:** 256M was, at the time this experiment was framed, the one
tier with no recompression pass (that shape has since also come to include
512M and 1G — see experiment 005 and `rationale.md [9]`), so its primary
carries density alone. It shipped with `zstd(level=1)` — is that right, or
does zstd's own documented default (level 3) win, given `rationale.md
[11]`'s claim that zstd decompression speed is roughly level-invariant?

**Method:** real zram device (`/dev/zram1`+, never `zram0`), `O_DIRECT`,
the same five real corpora as experiment 005, levels 1/3/6/9/12 swept, 4
reps each, order shuffled, byte-identical round-trip verified (100/100).
See [`006-256m-primary-zstd-level/RESULTS.md`](006-256m-primary-zstd-level/RESULTS.md).

**Result:** decompression speed is confirmed flat across levels at real
4 KiB granularity (not just borrowed from general-purpose benchmarks) —
level 3 gets a real 1.5-2.8% ratio gain over level 1 on 3 of 4 real
corpora, for a modest 7-16% compression-side cost (off the critical path).
The real cliff sits between level 3 and level 6 (compress throughput drops
~3x for a comparable ratio gain), not at 1-vs-3.

**Status:** closed. 256M's default primary moves from `zstd(level=1)` to
`zstd(level=3)` — the same setting 512M and 1G's zstd-alone primaries
already share now that all three sit on one unified shape (experiment 005,
`rationale.md [9]`). Provides levels 3/6/9/12 data relevant to experiment
004 below but does not close it — 004's hypothesis is specifically about
the optimal-parser cliff at levels ≥13, untested here.

## 004 — idle-tier compression level sweep

**Question:** where does the ratio-per-CPU-second curve actually flatten for
recompressing 4 KiB zram pages with zstd — is `level=12`, nixram's original
default for idle-tier recompression when this experiment was framed, the
right stopping point? The design has since simplified the recompression
default to a uniform `zstd(level=3)` (the same setting also used as
256M/512M/1G's primary) as a deliberate simplification, not a
re-measurement — see `rationale.md [11]` — so whether recompression on
genuinely idle, off-path pages would actually benefit from going denser than
that level=3 default was the open part of this question.

**Method:** a real, ephemeral NixOS VM (`pkgs.testers.nixosTest`, nothing
persists after the build) rather than real hardware — corrected mid-session
after direct feedback that kernel/device experiments belong in a disposable
VM, never a live host. Real scratch `/dev/zram1`, `O_DIRECT`, five real
corpora freshly captured inside the guest, levels 3/6/9/12/15/19 swept, 4
reps each, order double-shuffled, byte-identical round-trip verified
(120/120). See
[`004-idle-tier-compression-level-sweep/RESULTS.md`](004-idle-tier-compression-level-sweep/RESULTS.md).

**Result:** levels 15 and 19 conclusively close off going denser than ~12 —
every real corpus gains under 1% more ratio per step past level 12, while
compress throughput keeps roughly halving each step (confirmed worthless on
the incompressible control, whose ratio stays pinned at 1.000 throughout).
The more useful finding: the CURRENT `zstd(level=3)` recompression default
leaves a real, measured ~5-6% density gap versus level 9-12 on every real
corpus — density recompression could recover for free, since it only runs
when the CPU is already idle (unlike the primary path, where that same cost
is why 006 keeps level=3 there). Recommendation flagged for review: raise
reluctant-tier recompression back toward `zstd(level=12)`, reversing part of
the earlier "uniform level=3" simplification specifically for recompression
— not yet applied.

**Status:** closed. See
[`docs/rationale.md` \[11\]](../docs/rationale.md#11-idle-recompression-zstdlevel3-gated-on-genuine-idleness).
