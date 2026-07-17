# Experiments

The ledger of open questions behind nixram's extrapolated (◐) values. Every
entry here corresponds to a judgment call flagged in `levels.nix` and
`docs/rationale.md` as reasoned-but-unmeasured. Results feed back into
`levels.nix` as tag upgrades — extrapolated becomes measured (or sourced,
if the measurement confirms an existing upstream number) once an experiment
closes.

Status is `open` for every entry below; none of this has been run yet.

## 001 — systemd-oomd idle RSS on a 256M box

**Question:** is disabling `oomd.enable` at the 256M level actually the
right trade?

**Hypothesis:** systemd-oomd's own idle resident-memory footprint on a 256M
box is large enough, relative to total RAM, that running it costs more
headroom than its PSI-based early-warning protection is worth at that tier.

**Method sketch:** boot a 256M-class instance with `oomd.enable` forced on,
measure the daemon's steady-state RSS via `systemd-cgtop` / `/proc/<pid>/status`
over a representative idle and loaded period, and compare that overhead
against the amount of headroom the 256M level's other tunables (zram
resident limit, watermark tuning) are trying to protect.

**Status:** open. See
[`docs/rationale.md` \[8\]](../docs/rationale.md#8-systemd-oomd-disabled-at-256m).

## 002 — idle-recompression cadence

**Question:** what dwell period between the "mark idle" and "recompress"
phases of nixram's zram idle-recompression timer maximizes recompressed
bytes reclaimed without wasting CPU on pages that get touched again before
they'd have been recompressed anyway?

**Hypothesis:** "daily" (the current default) is a guess, not a measured
optimum — it may be too long (leaving compressible-but-touched pages
un-recompressed for a needless stretch) or too short (recompressing pages
that see reuse shortly after) depending on workload.

**Method sketch:** instrument the recompression script to log bytes
recompressed per run against `zram0/mm_stat`, sweep `onCalendar` across a
range (hourly, every 6h, daily, every 3 days) on a representative sustained
workload, and compare recompressed-bytes-per-CPU-second across cadences.

**Status:** open. See
[`docs/rationale.md` \[11\]](../docs/rationale.md#11-idle-recompression).

## 003 — swappiness sweep on a jampacked server

**Question:** does `vm.swappiness = 180` actually beat 100 or 150 on
tail-latency (p99) under steady memory pressure, for a long-uptime server
tier?

**Hypothesis:** the kernel's IO-cost model justifies values above 100 for
zram specifically, and Pop!_OS validated 180 for its own (desktop) use case
— but that hasn't been independently confirmed for nixram's
server/long-uptime target profile, where the pressure pattern is sustained
rather than bursty.

**Method sketch:** run a fixed memory-pressure workload (e.g. a working set
sized to force sustained swap activity) at swappiness 100/150/180 on an
otherwise identical zram configuration, and compare p50/p99 request latency
and PSI stall time across the three.

**Status:** open. See
[`docs/rationale.md` \[3\]](../docs/rationale.md#3-vmswappiness--180).

## 004 — idle-tier compression level sweep

**Question:** where does the ratio-per-CPU-second curve actually flatten for
recompressing 4 KiB zram pages with zstd — is `level=12` (the current
default) the right stopping point?

**Hypothesis:** on 4 KiB inputs the compression-ratio gain above roughly the
low teens collapses (no long-range matching to exploit), and level 13's
switch to zstd's optimal-parser strategies is a several-fold cost cliff for
near-zero gain — so 12 should sit at or near the knee. But this is reasoned
from zstd's design, not measured on real zram page populations.

**Method sketch:** capture a representative resident zram page set under a
sustained workload, recompress it at zstd levels 3/6/9/12/15/19 (via
`zram.recompressionAlgorithmOverride`), and compare bytes saved per
CPU-second across levels using `zram0/mm_stat` before/after each pass.

**Status:** open. See
[`docs/rationale.md` \[11\]](../docs/rationale.md#11-idle-recompression).
