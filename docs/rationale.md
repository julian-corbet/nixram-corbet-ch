# Rationale

Every tunable nixram sets carries one of three honesty tags (the full taxonomy
lives in `levels.nix`'s header and is summarized in `docs/levels.md`):

- **sourced** — a real upstream distro/kernel-doc default or bound, applied
  as-is, or a formula whose endpoints are sourced.
- **extrapolated** — nixram's own curve, cap, or judgement call standing on
  or between sourced anchors. Reasoned, not measured.
- **default** — the kernel's own computed value, deliberately left
  untouched. Not a nixram opinion at all.

The notes below are numbered `[1]`–`[13]`. The numbering is load-bearing:
`levels.nix` and the `modules/*.nix` files reference these exact numbers in
their comments, so don't renumber without updating both.

## [1] zram disksize curve

**Decision:** the zram-size (disksize) expression scales through the level
table: `ram * 2` below 2G, `ram` at 2G–8G, `min(ram / 2, 16384)` at 10G and
above.

**Honesty:** mixed. The 2G–8G endpoint (`ram`, i.e. 100% of RAM) is sourced.
The `ram * 2` multiplier below 2G is extrapolated. The `ram / 2` taper from
10G up is extrapolated; the 16384 MiB (16 GiB) cap it approaches is sourced.

**Reasoning:** Fedora's F33 "SwapOnZRAM" change shipped a disksize default of
`min(ram / 2, 4096)`. That default was later revised: current Fedora /
zram-generator defaults scale disksize to full RAM capacity, capped at 8G
(`min(ram, 8192)`). Pop!_OS's own default settings ship a 16 GiB ceiling.
zram-generator's own upstream documentation recommends disksize fractions "in
the range 0.1–0.5" of RAM — nixram's curve deliberately exceeds that range on
the small and mid tiers — up to 2x RAM on the smallest levels — before the
10G+ /2 taper and 16 GiB cap bring it back inside (down to ≤25% of RAM by 64G).

This is deliberate, not an oversight. Under nixram's resident-limit model,
disksize is only the *virtual* ceiling; the real physical budget is
`zram-resident-limit` ([2]), which stays inside a conservative fraction of
RAM at every tier. Once a resident limit is doing the actual safety job, a
generous disksize costs nothing but a bit of virtual address space, and lets
compression stretch the same physical spend further before the medium hits a
hard wall. The counterargument is real, and is exactly why `zram.sizing`
defaults to `"both"`, never `"virtual"` alone: on a host running
`sizing = "virtual"` alone, disksize *is* the only ceiling, and a generous one
really can let compression overhead balloon.

**Source:** Fedora SwapOnZRAM change; the later Fedora/zram-generator
full-RAM-scaling default; Pop!_OS default-settings; zram-generator's own
upstream docs (disksize fraction guidance).

## [2] zram-resident-limit budget model

**Decision:** `zram-resident-limit` (mem_limit) is set to `ram / 2` up to 1G,
`ram * 35 / 100` (35%) from 2G to 32G, and left unset from 64G up.

**Honesty:** mixed. The resident-limit primitive itself is sourced — a
first-class `zram-generator.conf` key that maps directly onto the kernel's
`/sys/block/zramN/mem_limit`. The specific fractions applied at each tier are
nixram's own extrapolated budget model.

**Reasoning:** disksize alone is a virtual ceiling that can misrepresent the
real physical cost once compression enters the picture. nixram's own choice
is to keep the actual physical spend inside a conservative fraction of total
RAM at every tier — `ram / 2` on the smallest tiers, where headroom is scarce
and every MiB has to be accounted for, tapering to 35% on multi-GB tiers,
where there's more slack to share between application memory and the
compressed pool. At 64G and above it is deliberately unset: at those anchor sizes the
disksize formula ([1]) already caps the virtual ceiling at ≤25% of RAM on its
own, and an additional physical cap was judged redundant. Note that this
holds AT the anchors — a machine that rounded up into the tier sees a larger
fraction (a 33 GiB box gets a 16 GiB ceiling, ~48% of its RAM, with no
physical cap behind it), which is the rounding caveat in `faq.md`. This is flagged as
an open question, not a settled position — see `experiments/README.md`.

**Source:** zram-generator's own upstream docs (the `zram-resident-limit` /
`mem_limit` key); the kernel's zram sysfs documentation (`mem_limit`).

## [3] vm.swappiness = 180

**Decision:** `vm.swappiness = 180` for zram-backed swap, at every level.

**Honesty:** sourced.

**Reasoning:** the kernel extended the swappiness range from the historical
0–100 to 0–200, with a documented IO-cost model behind the extension: values
above 100 are explicitly sanctioned for cases where swapping a page in is
cheaper than reading the equivalent data back from a filesystem cache miss.
That is exactly the situation with in-RAM compressed swap — a page fault
against zram costs a memcpy plus decompression, not a disk seek. Pop!_OS
ships 180 as its own default for zram-backed systems.

**Source:** kernel vm sysctl docs (swappiness 0–200 range, IO-cost
rationale); Pop!_OS default-settings (PR #163 lineage).

## [4] vm.page-cluster = 0

**Decision:** `vm.page-cluster = 0` for zram-backed swap, at every level.

**Honesty:** sourced.

**Reasoning:** page-cluster controls how many pages (as a power of two) are
read ahead on a single swap-in fault — a setting whose entire justification
is amortizing a disk seek's fixed cost. zram has no seek cost at all: every
page fault against it is a flat-cost memory operation, so reading ahead only
adds latency and wasted decompression work for pages that may never be
touched.

**Source:** kernel vm sysctl docs (page-cluster); Pop!_OS default-settings
(ships 0 for zram).

## [5] Watermarks

**Decision:** `vm.watermark_boost_factor = 0` at every level.
`vm.watermark_scale_factor` tapers 200 (≤1G) / 150 (2G–8G) / 125 (10G–32G) /
100 (≥64G).

**Honesty:** mixed, and worth being precise about which piece is which.
`watermark_boost_factor = 0` is sourced (Pop!_OS ships 0). Of the four
`watermark_scale_factor` values, only **125** is sourced — it's the one flat
value Pop!_OS itself validated. The other three (200, 150, 100) are nixram's
own extrapolated taper connecting to that sourced anchor.

**Reasoning:** watermark_scale_factor controls how much earlier kswapd wakes
relative to a zone's free-page thresholds. Pop!_OS validated 125 across its
own (desktop/laptop-scale) hardware range. nixram's reasoning for tapering
rather than shipping 125 everywhere: on very small tiers, the absolute
free-page slack implied by any fixed percentage is tiny in absolute terms, so
kswapd needs to wake earlier (a higher scale factor) to leave enough real
headroom; on very large tiers the opposite is true, and 100 is enough. The
taper itself is a judgment call, not a sourced curve — only its 125 midpoint
is validated.

**Source:** Pop!_OS default-settings (`watermark_boost_factor=0`,
`watermark_scale_factor=125`).

## [6] vm.min_free_kbytes: untouched

**Decision:** `vm.min_free_kbytes` is left at the kernel's own computed value
at every level; `minFreeKbytesOverride` exists only as a manual escape hatch.

**Honesty:** kernel default — not a nixram opinion at all.

**Reasoning:** no distro default or kernel documentation reviewed for this
project offers a universal per-GB (or per-tier) formula for
`min_free_kbytes` that would generalize across nixram's 256M–128G range.
Rather than invent one, nixram declines to have an opinion here and leaves
the kernel's own computed value in place at every level. The override option
exists for operators who have measured their own workload's needs; nothing
in nixram sets it by default.

**Source:** none — deliberately the kernel's own computed default, not a
sourced or extrapolated nixram value.

## [7] MGLRU min_ttl_ms = 1000

**Decision:** `min_ttl_ms = 1000` under `/sys/kernel/mm/lru_gen/`, applied via
a systemd-tmpfiles `w` rule (not a sysctl — MGLRU's tunables live outside
`/proc/sys`), at every level regardless of `mode`.

**Honesty:** sourced, flagged. The value and the thrash-prevention rationale
come from the kernel's own MGLRU admin-guide documentation, which offers 1000
as its example value. The flag: the kernel docs frame this knob as guidance
"for users who do not have oomd" running — nixram runs it *alongside* oomd as
a complementary layer instead, and its interaction with oomd under real,
months-long uptime is unmeasured.

**Reasoning:** MGLRU (multi-gen LRU) can, under pressure, evict pages fast
enough to cause thrashing before the reclaim algorithm's own generational
aging has gathered enough signal; `min_ttl_ms` enforces a minimum dwell time
per generation to prevent that. The kernel doc's example value is 1000ms.
nixram applies it everywhere as a second, complementary layer alongside
PSI-driven oomd, not as a replacement for it.

**Source:** kernel MGLRU admin-guide (`min_ttl_ms`, thrash-prevention
guidance, example value).

## [8] systemd-oomd disabled at 256M

**Decision:** systemd-oomd is armed (PSI thresholds, [10]) at every level
except 256M, where it defaults off.

**Honesty:** mixed. The 60%/30s PSI thresholds themselves are sourced ([10]).
The 256M opt-out is extrapolated and deliberate.

**Reasoning:** systemd-oomd itself carries a daemon-resident RSS cost, and on
a 256M box that cost is a meaningfully larger fraction of total memory than
on any larger tier. nixram has not measured that cost (see
`experiments/README.md`, 001) and judged that an unmeasured overhead is not a
safe default to carry on the one tier that can least afford to spare it. The
kernel's own last-resort OOM killer, plus `OOMScoreAdjust = -900` on
protected units, stays active at every level including 256M — disabling
systemd-oomd removes the PSI-based early-warning layer, not the kernel's OOM
killer itself.

**Source:** none for the opt-out itself (nixram's own judgment call); the PSI
thresholds it would otherwise use are systemd-oomd's own upstream defaults
([10]).

## [9] Compression algorithm: zstd, zstd(level=1) at 256M

**Decision:** zstd at every level; 256M specifically uses `zstd(level=1)`
rather than plain `zstd`.

**Honesty:** mixed. Choosing zstd as the modern default compressor is
sourced. The `level=1` choice specifically for the 256M tier is extrapolated.

**Reasoning:** zstd is the compression algorithm Fedora ships as its own zram
default, and it's the algorithm zram-generator's own documentation uses as
its worked example — a reasonable proxy for "the modern default choice"
across the ecosystem. At every level above 256M, nixram uses plain `zstd` (its
default compression level). At 256M, the tier is as CPU-constrained as it is
memory-constrained, so nixram switches to zstd's cheapest mode (`level=1`) as
a reasoned tradeoff: less compression ratio in exchange for less CPU spent on
every page fault, on the one tier that can least afford to burn cycles on
compression.

**Source:** Fedora (zstd as zram default); zram-generator's own upstream docs
(zstd as documented example algorithm).

## [10] PSI thresholds: 60% / 30s

**Decision:** `ManagedOOMMemoryPressureLimit = 60%`,
`ManagedOOMMemoryPressureDurationSec = 30s`, at every level (dormant wherever
oomd itself is disabled).

**Honesty:** sourced.

**Reasoning:** these are not nixram inventions — they are systemd-oomd's own
upstream defaults, unmodified. nixram sets them explicitly, rather than
relying on the built-in `enableSystemSlice` / `enableUserSlices` helpers
(which hardcode an 80% limit with no duration control), purely so a future
per-level tuning of these numbers is possible. Today, every level uses the
same, stock values.

**Source:** `oomd.conf(5)` (`DefaultMemoryPressureLimit=60%`,
`DefaultMemoryPressureDurationSec=30s`).

## [11] Idle recompression

**Decision:** a rolling two-phase systemd timer drives zram idle-page
recompression: each run recompresses whatever the *previous* run idle-marked
and that has stayed untouched since, then marks the current resident set
idle for the *next* run to act on. Default cadence "daily"; idle-tier
algorithm `zstd(level=12)`; off by default at 256M.

**Honesty:** mixed. The kernel primitive is sourced: kernel ≥6.2 with
`CONFIG_ZRAM_MULTI_COMP` exposes `recompress` and `idle` controls under
`/sys/block/zramN/`, but the kernel never triggers recompression on its own —
userspace has to drive it. The two-phase timer design, the "daily" cadence,
and the `zstd(level=12)` idle-tier choice are all nixram's own extrapolated
design.

**Reasoning:** a naive "mark idle, then immediately recompress what's marked
idle" in a single run would recompress the entire device every single time,
because every resident page looks idle in the instant right after being
marked — the kernel clears a page's idle flag the moment it's written again,
so idle-ness only means anything after a real dwell period has passed.
nixram's design splits marking and recompressing across two separate timer
firings, so "idle" actually reflects one full interval of non-use before a
page is judged a good recompression candidate. "Daily" is an unvalidated
starting point for that interval, not a measured cadence (see
`experiments/README.md`, 002).

`zstd(level=12)` for the idle tier: idle pages are, by definition, off the
hot path (and zstd's decompression speed is essentially level-independent,
so a denser idle tier never slows down faulting a page back in), which
justifies spending *more* CPU per page here than on the primary algorithm —
but not unboundedly more. Two limits argue against going higher: zram
compresses 4 KiB pages individually, and zstd's very high levels earn their
cost through long-range match-finding that a 4 KiB input cannot benefit
from, so the ratio gained above the low teens collapses to roughly nothing;
and at level 13 zstd switches to its optimal-parser strategies, a several-fold
compression-cost cliff. Level 12 — the densest setting below that cliff — is
nixram's pick, extrapolated: no source recommends a specific idle-tier level
(that measurement is `experiments/README.md`, 004), and it's tunable via
`zram.recompressionAlgorithmOverride`. The timer defaults off at 256M: the
whole compressed pool tops out around ~512M at that tier, and a denser idle
pass doesn't pay for itself there.

**Source:** kernel zram admin-guide / sysfs docs (`recompress`, `idle`
controls, multi-compression support).

## [12] swap-priority = 100

**Decision:** `swap-priority = 100` on the zram device, at every level.

**Honesty:** sourced.

**Reasoning:** 100 is zram-generator's own upstream default, deliberately set
higher than typical disk-swap priorities so that when both a zram device and
a disk-backed swap device exist on the same box, the kernel always prefers
zram first. nixram doesn't change this value; it ships it as-is at every
level, with an escape hatch (`zram.priorityOverride`) for operators who need a
different ordering.

**Source:** zram-generator's own upstream docs (swap-priority default).

## [13] Recompression on ≥64G boxes

**Decision:** the idle-recompression timer stays on by default at 64G and
128G, same as every tier from 512M up.

**Honesty:** extrapolated.

**Reasoning:** at these tiers the marginal value of idle recompression is
genuinely low — the disksize formula already caps the pool at 16 GiB
regardless of how much RAM the box has, and RAM itself is plentiful, so
there's little pressure motivating the extra CPU spend. nixram leaves it on
anyway, for consistency with every other level rather than carving out a
special case: the cost is bounded (a nice-19, CPU-weight-10, idle-IO-class
oneshot service), and the honest reason is consistency, not measurement. The
documented alternative for a box running one large, non-swap-shaped workload
is `services.nixram.mode = "none"`, which turns off the whole zram/zswap
layer (not just recompression) and leaves only the oomd and sysctl layers
running.

**Source:** none — nixram's own judgment call, stated as such.

## Zswap profile

nixram's `mode = "zswap"` path is a distinct profile from the zram path
above: zswap is a compressed *cache* in front of a real disk-backed swap
device, not a swap device itself, so its tuning targets a different set of
trade-offs — laptops and desktops with real disk swap, rather than servers
with none.

### Pool size: max_pool_percent / accept_threshold_percent

**Honesty:** sourced.

nixram leaves `zswap.max_pool_percent` at 20 and
`zswap.accept_threshold_percent` at 90 — both are the kernel's own upstream
defaults, deliberately not raised. Unlike zram's disksize ([1]), the zswap
pool competes directly with the same RAM that running applications use, not
with disk I/O time; a bigger pool has a real, immediate opportunity cost that
the zram case doesn't share, so nixram doesn't extrapolate beyond the sourced
value here. `accept_threshold_percent` is the hysteresis band the pool must
drain back to (as a percentage of `max_pool_percent`) before it resumes
accepting compressed pages once full — also the stock kernel default.

### Shrinker: shrinker_enabled

**Honesty:** reasoned choice — a deliberate deviation from upstream's own
default.

The zswap shrinker (kernel ≥6.8) proactively writes back cold zswap pages to
the real backing disk swap under pressure, rather than waiting for the pool
to fill and block. It ships off by default upstream; nixram turns it on.
This is a reasoned choice, not a sourced recommendation to enable it — the
kernel's own default is off.

### Zpool: zsmalloc only

**Honesty:** sourced, by omission.

nixram hardcodes `zswap.zpool=zsmalloc` and does not expose a selector.
z3fold and zbud have been removed from current kernels; zsmalloc is the only
zpool implementation zswap has left. Offering a choice here would only offer
dead configuration.

### Swappiness: 120

**Honesty:** extrapolated.

zram gets a flat 180 ([3]) because it's a uniformly cheap medium — no seek
cost, ever. zswap is only partially cheap: a cache hit is RAM-speed
decompression, but a cache miss falls through to a real disk read, with all
of a disk's usual cost. nixram's zswap profile sits between the plain-disk
kernel default (60) and zram's medium-justified 180, at 120 — a reasoned
midpoint, not a value verified against any upstream benchmark.

### Page-cluster: SSD vs HDD

**Honesty:** sourced (Pop!_OS's own distinction).

zram uses page-cluster=0 unconditionally ([4]) because it has no seek cost to
amortize. zswap's backing medium is a real disk, so that logic doesn't
transfer once a page actually misses the cache. nixram follows Pop!_OS's own
distinction here: page-cluster=2 when the backing swap medium is SSD
(`zswap.diskMedium = "ssd"`, the default), and the kernel's own default (3)
left untouched when it's HDD.

### Watermark scale factor: flat 125

**Honesty:** sourced.

The zram/server table tapers watermark_scale_factor by RAM size ([5]) because
the reasoning behind that taper is about absorbing sustained pressure bursts
on long-running server workloads. A laptop or desktop's memory-pressure
episodes are typically shorter-lived and interactive rather than sustained,
so that taper's justification doesn't apply. nixram's zswap profile instead
uses the flat 125 that Pop!_OS itself validated, at every RAM size, rather
than tapering it.
