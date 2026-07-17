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
