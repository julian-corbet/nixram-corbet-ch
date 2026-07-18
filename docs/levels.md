# Levels

The reader-facing view of `levels.nix`. Every value here is copied straight
from that file — if the two ever disagree, `levels.nix` is the source of
truth and this page has drifted.

**Legend:** ● sourced · ◐ extrapolated · ○ kernel default

The full citation for every ● and the reasoning behind every ◐ lives in
[`rationale.md`](rationale.md), referenced by number below.

| Level | zram-size | zram-resident-limit | compression | recompression tier | watermark_scale_factor | oomd |
|---|---|---|---|---|---|---|
| 256M | `ram * 2` ◐ | `ram / 2` ◐ | `zstd(level=1)` ◐ | off ◐ | 200 ◐ | off ◐ |
| 512M | `ram * 2` ◐ | `ram / 2` ◐ | `zstd` ● | `zstd(level=12)`, daily ◐ | 200 ◐ | on ◐ |
| 1G | `ram * 2` ◐ | `ram / 2` ◐ | `zstd` ● | `zstd(level=12)`, daily ◐ | 200 ◐ | on ◐ |
| 2G | `ram` ● | `ram * 35 / 100` ◐ | `zstd` ● | `zstd(level=12)`, daily ◐ | 150 ◐ | on ◐ |
| 4G | `ram` ● | `ram * 35 / 100` ◐ | `zstd` ● | `zstd(level=12)`, daily ◐ | 150 ◐ | on ◐ |
| 6G | `ram` ● | `ram * 35 / 100` ◐ | `zstd` ● | `zstd(level=12)`, daily ◐ | 150 ◐ | on ◐ |
| 8G | `ram` ● | `ram * 35 / 100` ◐ | `zstd` ● | `zstd(level=12)`, daily ◐ | 150 ◐ | on ◐ |
| 10G | `min(ram / 2, 16384)` ◐¹ | `ram * 35 / 100` ◐ | `zstd` ● | `zstd(level=12)`, daily ◐ | 125 ● | on ◐ |
| 12G | `min(ram / 2, 16384)` ◐¹ | `ram * 35 / 100` ◐ | `zstd` ● | `zstd(level=12)`, daily ◐ | 125 ● | on ◐ |
| 16G | `min(ram / 2, 16384)` ◐¹ | `ram * 35 / 100` ◐ | `zstd` ● | `zstd(level=12)`, daily ◐ | 125 ● | on ◐ |
| 24G | `min(ram / 2, 16384)` ◐¹ | `ram * 35 / 100` ◐ | `zstd` ● | `zstd(level=12)`, daily ◐ | 125 ● | on ◐ |
| 32G | `min(ram / 2, 16384)` ◐¹ | `ram * 35 / 100` ◐ | `zstd` ● | `zstd(level=12)`, daily ◐ | 125 ● | on ◐ |
| 64G | `min(ram / 2, 16384)` ◐¹ | unset (null) ◐ | `zstd` ● | `zstd(level=12)`, daily ◐ | 100 ◐ | on ◐ |
| 128G | `min(ram / 2, 16384)` ◐¹ | unset (null) ◐ | `zstd` ● | `zstd(level=12)`, daily ◐ | 100 ◐ | on ◐ |

¹ the `/2` taper is extrapolated; the 16384 MiB (16 GiB) cap it approaches is
sourced (Pop!_OS). At 32G the two meet exactly (32 / 2 = 16). See
[rationale.md \[1\]](rationale.md#1-zram-disksize-curve).

`ram` is zram-generator's own variable for total detected RAM in MiB,
evaluated against the machine's real `/proc/meminfo` at boot — not a number
baked in per level at Nix eval time. `oomd` "on"/"off" here is
`oomd.enable`; the PSI thresholds it uses when on are the constants below,
not per-level values.

## Level by level — why each tier is shaped the way it is

Adjacent tiers that share one reasoning share one entry here. Every claim
below is restating `levels.nix` + `rationale.md`; the badges above still
mark what's sourced vs extrapolated.

### 256M — the survival tier

Everything here is rationed twice over: RAM, and the CPU to compress it.
disksize is `ram * 2` because compression is the only headroom this box will
ever have, and the resident limit at half of RAM caps how much of that reach
can ever become physical spend. `zstd(level=1)` instead of plain `zstd`:
every page fault costs CPU on a machine that has almost none to spare.
systemd-oomd stays off — the daemon's own RSS is an unmeasured fraction of a
very small total (experiments 001), so the kernel OOM killer plus the
`OOMScoreAdjust = -900` protection layer stands guard alone. Recompression
off: a pool that tops out around ~512M logical can't repay a second pass.

### 512M — first full-strength tier

The same 2×/½ shape as 256M, but nothing needs rationing twice anymore:
plain `zstd` is affordable, oomd is armed (its RSS is a far smaller fraction
of the box), and the daily idle-recompression pass starts paying — tens of
MB back, on a machine where tens of MB are percent-of-RAM money.

### 1G — the small-box shape holds

The last tier of the small-box shape: double-RAM virtual reach, half-of-RAM
physical budget. From here down the box lives or dies by compression
stretch. `watermark_scale_factor` stays at 200 across all three small tiers:
any fixed percentage of a tiny zone is a tiny absolute number of free pages,
so kswapd must start reclaiming earlier to leave real headroom.

### 2G — the sourced middle begins

disksize drops to plain `ram` — Fedora's own shipped default (full-RAM
scaling), the best-sourced point on the entire curve. The physical budget
tapers from ½ to 35%: with multiple GB present, the compressed pool no
longer needs to be allowed half the machine to be useful. Watermarks relax
to 150.

### 4G — the reference tier

The most ordinary row in the table — disksize sourced from Fedora, the
standard 35% budget, every shared constant at its normal value. To
understand nixram's model, read this row first: every other tier is this
row with one scarcity turned up or down.

### 6G / 8G — same row, more slack

Nothing changes but the numbers the same expressions resolve to. 8G is the
last tier where a full-RAM disksize is still the right ceiling.

### 10G — the taper begins

disksize switches to `min(ram / 2, 16384)`. The need for swap capacity
stops scaling with RAM: a 10G box under pressure doesn't want 10G of swap,
it wants a bounded absorber and then a timely OOM decision. The `/2` taper
is what binds through 32G (5G of reach here); the 16 GiB cap in the formula
is Pop!_OS's shipped ceiling, waiting to take over. Watermarks reach the
Pop-validated 125.

### 12G / 16G / 24G — the plateau

The `/2` taper walks the ratio down: 6G of reach on a 12G box, 8G on 16G,
12G on 24G — a shrinking fraction of a growing machine, all inside the same
35% physical budget.

### 32G — where taper meets cap

32 / 2 = 16: the one tier where the taper and the 16 GiB cap agree exactly.
Above this line the cap alone rules and RAM size stops mattering to the
absorber entirely.

### 64G — the budget retires

The resident limit is deliberately unset. disksize (16G) is already ≤25% of
RAM — a physical bound tighter than the 35% rule would produce — so a second
cap would be decoration, not protection. Flagged as an open question rather
than proven (rationale [2]). Watermarks ease to 100: kswapd can afford to be
lazy here. For a box running one huge, non-swap-shaped workload, the honest
alternative is `mode = "none"` — oomd and sysctls without any swap medium.

### 128G — the cap is the whole story

16G of absorber on a machine with eight times that much RAM. zram at this
scale is not survival — it's a parking lot for cold pages that would
otherwise squat on hot RAM for months of uptime. Everything else as 64G.

## Constants shared by every level

These don't vary by RAM size — they're properties of the swap medium (zram)
or the reclaim/OOM machinery, not the box:

| Tunable | Value | Honesty |
|---|---|---|
| `vm.swappiness` | 180 | ● [rationale \[3\]](rationale.md#3-vmswappiness--180) |
| `vm.page-cluster` | 0 | ● [rationale \[4\]](rationale.md#4-vmpage-cluster--0) |
| `vm.watermark_boost_factor` | 0 | ● [rationale \[5\]](rationale.md#5-watermarks) |
| `vm.min_free_kbytes` | untouched | ○ [rationale \[6\]](rationale.md#6-vmmin_free_kbytes-untouched) |
| MGLRU `min_ttl_ms` | 1000 | ●, flagged [rationale \[7\]](rationale.md#7-mglru-min_ttl_ms--1000) |
| PSI threshold | 60% / 30s | ● [rationale \[10\]](rationale.md#10-psi-thresholds-60--30s) |
| zram `swap-priority` | 100 | ● [rationale \[12\]](rationale.md#12-swap-priority--100) |

## Zswap profile (`mode = "zswap"`)

A separate, flat profile for laptops/desktops with real disk-backed swap —
see [rationale.md, Zswap profile](rationale.md#zswap-profile) for the full
reasoning behind each value.

| Tunable | Value | Honesty |
|---|---|---|
| `zswap.max_pool_percent` | 20 | ● |
| `zswap.accept_threshold_percent` | 90 | ● |
| `zswap.shrinker_enabled` | on | ◐ (upstream default is off) |
| `zswap.zpool` | zsmalloc | ● (only option left on current kernels) |
| `vm.swappiness` | 120 | ◐ |
| `vm.page-cluster` | 2 (SSD) / 3, untouched (HDD) | ● |
| `vm.watermark_scale_factor` | 125, flat | ● |
