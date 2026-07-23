# Levels

The reader-facing view of `levels.nix`. Every value here is copied straight
from that file — if the two ever disagree, `levels.nix` is the source of
truth and this page has drifted.

**Legend:** ● sourced · ◆ directed · ◐ extrapolated · ○ kernel default

The full citation for every ● and ◆, and the reasoning behind every ◐, lives
in [`rationale.md`](rationale.md), referenced by number below.

| Level | zram-size | zram-resident-limit | compression | recompression | swappiness | watermark_scale_factor | oomd |
|---|---|---|---|---|---|---|---|
| 256M | `ram` ◐ | `ram * 30 / 100` ◆ | `zstd(level=3)` ◆ | off | 120 ◆ | 200 ◐ | off ◐ |
| 512M | `ram` ◐ | `ram * 30 / 100` ◆ | `zstd(level=3)` ◆ | off | 120 ◆ | 200 ◐ | on ◐ |
| 1G | `ram` ◐ | `ram * 30 / 100` ◆ | `zstd(level=3)` ◆ | off | 120 ◆ | 200 ◐ | on ◐ |
| 2G | `ram * 75 / 100` ◐ | `ram * 25 / 100` ◐ | `lz4` ◐ | `zstd(level=3)` ◐ | 10 ◆¹ | 150 ◐ | on ◐ |
| 4G | `ram * 75 / 100` ◐ | `ram * 25 / 100` ◐ | `lz4` ◐ | `zstd(level=3)` ◐ | 10 ◆¹ | 150 ◐ | on ◐ |
| 6G | `ram * 75 / 100` ◐ | `ram * 25 / 100` ◐ | `lz4` ◐ | `zstd(level=3)` ◐ | 10 ◆¹ | 150 ◐ | on ◐ |
| 8G | `ram * 75 / 100` ◐ | `ram * 25 / 100` ◐ | `lz4` ◐ | `zstd(level=3)` ◐ | 10 ◆¹ | 150 ◐ | on ◐ |
| 10G | `ram * 75 / 100` ◐ | `ram * 25 / 100` ◐ | `lz4` ◐ | `zstd(level=3)` ◐ | 10 ◆¹ | 125 ● | on ◐ |
| 12G | `ram * 75 / 100` ◐ | `ram * 25 / 100` ◐ | `lz4` ◐ | `zstd(level=3)` ◐ | 10 ◆¹ | 125 ● | on ◐ |
| 16G | `ram * 75 / 100` ◐ | `ram * 25 / 100` ◐ | `lz4` ◐ | `zstd(level=3)` ◐ | 10 ◆¹ | 125 ● | on ◐ |
| 24G | `ram * 75 / 100` ◐ | `ram * 20 / 100` ◐ | `lz4` ◐ | `zstd(level=3)` ◐ | 10 ◆¹ | 125 ● | on ◐ |
| 32G | `ram * 75 / 100` ◐ | `ram * 20 / 100` ◐ | `lz4` ◐ | `zstd(level=3)` ◐ | 10 ◆¹ | 125 ● | on ◐ |
| 64G | `ram * 75 / 100` ◐ | `ram * 20 / 100` ◐ | `lz4` ◐ | `zstd(level=3)` ◐ | 10 ◆¹ | 100 ◐ | on ◐ |
| 128G | `ram * 75 / 100` ◐² | `ram * 20 / 100` ◆ | `lz4` ◆ | `zstd(level=3)` ◐ | 10 ◆¹ | 100 ◐ | on ◐ |

¹ resting value only. A PSI-gated relief valve (`zram.swappinessRelief`, on
by default at every tier in this table) temporarily raises swappiness to
**60** during genuine, sustained memory pressure, then lowers it back to 10
once pressure resolves — see the explanation below the table and
[rationale.md \[17\]](rationale.md#17-reluctant-tier-swappiness-10-at-rest-psi-gated-relief-valve-for-genuine-overflow).
256M/512M/1G don't get this mechanism at all: they're already eager (120),
so there's no low resting baseline to relieve from.

² the formula (`ram * 75 / 100`) is extrapolated, but the two real
worked-example corrections that led to it — most visibly 96 GiB at 128G,
not the 64 GiB an earlier power-of-two-only rounding gave — are Julian's
own direct corrections. See the 128G section below and
[rationale.md \[1\]](rationale.md#1-zram-disksize-curve).

`ram` is zram-generator's own variable for total detected RAM in MiB,
evaluated against the machine's real `/proc/meminfo` at boot — not a number
baked in per level at Nix eval time. `oomd` "on"/"off" here is
`oomd.enable`; the PSI thresholds it uses when on are the constants below,
not per-level values. `swappiness` here is the per-tier `vm.swappiness`
nixram sets when `mode = "zram"` — zswap runs its own separate flat value
(25) shown in the zswap profile table further down.

`recompression`, where it isn't "off", is `zstd(level=3)` run by a rolling
two-phase idle-gated timer, not a fixed calendar job: by default it checks
every 15 minutes (`*:0/15`) whether to act, but only actually marks/
recompresses if CPU PSI (`/proc/pressure/cpu`, the "some" line's `avg10`)
shows the box genuinely idle right now (avg10 < 10%); otherwise it logs and
retries on the next tick. This is a check-frequency default, not a
run-frequency — see [rationale.md \[11\]](rationale.md#11-idle-recompression-zstdlevel3-gated-on-genuine-idleness).
Recompression is "off" wherever the primary is already `zstd(level=3)`
(256M/512M/1G): the firm pairing rule is that a dense primary leaves
nothing for a recompression pass to add, full stop — never mix the two
within one tier.

**The swappiness relief valve, new this round and worth its own
explanation, not just a number change.** The reluctant tiers (2G-128G) used
to sit at a flat, permanently-untuned kernel default (60). That's now
replaced by a genuinely low resting value (10 — Julian's own real
historical data point, the fleet's previous Unraid server) plus a systemd
service+timer pair, `nixram-swappiness-relief` (`modules/zram.nix`), that
watches `/proc/pressure/memory`'s "some" line every
`zram.swappinessRelief.checkIntervalSec` (default 30s) and moves swappiness
between two states:

- **Entering relief** (10 → 60): triggered once `avg10` (the fast,
  10-second average) crosses `zram.swappinessRelief.pressureHighThreshold`
  (default 10%) — a quick response to a real spike.
- **Leaving relief** (60 → 10): triggered only once `avg60` (the slower,
  60-second average) drops below `zram.swappinessRelief.pressureLowThreshold`
  (default 1%) — deliberately the slower signal, so a brief lull in the
  middle of a genuine overflow event doesn't bounce swappiness back down
  before the pressure has actually resolved.

The relief value itself is `zram.swappinessRelief.reliefValue` (default
60 — the same plain kernel default the reluctant tiers used to sit at
permanently, now reserved for confirmed pressure only). State lives in a
small file under `/run`, so a reboot always starts back at the low
baseline. On by default only at 2G-128G (`zram.swappinessRelief.enable`);
256M/512M/1G don't get it — they're already eager by design, with no low
baseline to relieve from in the first place. Full mechanism and the
specific-thresholds caveat (unvalidated starting points, tunable per box):
[rationale.md \[17\]](rationale.md#17-reluctant-tier-swappiness-10-at-rest-psi-gated-relief-valve-for-genuine-overflow).

## Level by level — why each tier is shaped the way it is

Adjacent tiers that share one reasoning share one entry here. Every claim
below is restating `levels.nix` + `rationale.md`; the badges above still
mark what's sourced/directed vs extrapolated.

### 256M, 512M, 1G — the dire shape: lean on zram willingly, dense primary, no second act

All three small tiers now share one architecture: `zstd(level=3)` primary,
**no recompression pass at all**. Julian's own instruction, applied as
stated: "everything up to a GB goes to zstd primary and done." An earlier
version of this design wrongly gave 256M/512M a cheap `lz4`-primary +
recompression shape instead, over-applying a much narrower exception
Julian described for the weakest possible CPU-bound hardware ("even then I
am not sure") to the whole band — that was a real implementation mistake,
caught and reverted, not a design change. `zram-size` is plain `ram` (100%
of RAM) and the resident budget 30% at all three; `watermark_scale_factor`
stays at 200: any fixed percentage of a tiny zone is a tiny absolute number
of free pages, so kswapd must start reclaiming earlier to leave real
headroom.

These three tiers see light, few-user usage with no heavy concurrent
demand competing for CPU, and are genuinely RAM-starved — so paying
`zstd(level=3)`'s cost synchronously, right on the compress path, costs
nothing that's actually needed elsewhere, and grabbing whatever density is
available right now beats waiting for an idle window that may not come.
This is the opposite reasoning from the tiers above 1G, not the same
tradeoff applied more gently — see [rationale.md \[9\]](rationale.md#9-compression-algorithm-zstdlevel3-alone-through-1g-lz4recompression-from-2g-up)
for Julian's own compute-boundedness explanation, generalized across the
whole ladder.

Swappiness is **120** at all three — eager, revised down twice: 180
(Pop!_OS's own zram default) → 130 (adversarially revised: once file cache
is genuinely near-empty, the anon:file scan-target math collapses toward
anon regardless of the exact ratio, so most of the distance up toward 200's
ceiling buys almost nothing on *which* pool gets picked; what it actually
changes is *when* reclaim triggers at all — pure extra compress/decompress
cycles on the class least able to spare the CPU) → **120** (Julian's own
further direct revision, no additional reasoning given beyond the number
itself). No swappiness relief valve here: these tiers are already eager,
with no low resting baseline to relieve from in the first place.

256M alone keeps systemd-oomd off: the daemon's own RSS is an unmeasured
fraction of a very small total (`experiments/README.md`, 001), so the
kernel OOM killer plus the `OOMScoreAdjust = -900` protection layer stands
guard alone. 512M and 1G arm oomd normally.

### 2G — the architecture flips, for a workload reason, not a headroom reason

Above 1G, the shape flips to a cheap primary with recompression behind it:
`lz4` + `zstd(level=3)` idle-gated recompression. This isn't the "lean on
zram out of necessity" story that used to apply to the small tiers — it's
**workload compute-boundedness**, per Julian's own direct explanation:
boxes provisioned at 2G and up increasingly run compute-bound workloads
(LLMs, genAI, many concurrent apps) that compete hard for the same CPU a
synchronous dense primary would consume, so the cheap primary protects that
live demand and the expensive recompression pass is deferred to genuine
idle time instead. **Attribution, precisely:** Julian's own worked
examples are 256M/512M/1G (zstd-alone) and, separately, a ~128G server
(lz4+recompress, for a compute-boundedness reason he gave directly) — two
data points, not a stated numeric cutoff. That the architecture flips back
specifically at 2G, and holds all the way through 128G, is nixram's own
generalization connecting those points — reasonably motivated (2G is the
smallest tier where multiple concurrent services become the realistic norm
rather than the exception) but not something Julian specified tier by
tier.

Alongside the architecture flip, `zram-size` drops to `ram * 75 / 100` and
the resident budget tapers from 30% to 25% — a CPU-tax budget, not a
memory-safety backstop, needing less of a share once multiple GB are
present. Watermarks relax to 150. Swappiness drops to its reluctant resting
value, **10**, with the PSI-gated relief valve active from here through
128G (see above).

### 4G — the reference tier

The most ordinary row in the table — every shared constant at its normal
value, the standard 25% resident budget, the reluctant compression shape.
To understand nixram's model, read this row first: every other tier is
this row with one scarcity turned up or down.

### 6G / 8G — same row, more slack

Nothing changes but the numbers the same expressions resolve to.

### 10G, 12G, 16G — the watermark reaches its sourced anchor

`watermark_scale_factor` steps down to **125** here — the one flat value
Pop!_OS itself actually validated, rather than nixram's own extrapolated
taper either side of it. Everything else continues the 2G/4G shape
unchanged: 25% resident budget, `lz4` + recompression, swappiness resting
at 10 with the relief valve armed.

### 24G — the resident-limit bump starts early

The resident limit steps down to **20%** starting here. **The 20% figure
itself is Julian's own stated number** — he gave it for the ~128G tier
("taking a 20% slice of system RAM here is about 25GB") — **but where the
step down begins is not something he specified.** 24G, rather than 32G or
64G, is nixram's own extrapolated placement connecting his one 20% data
point back to the 25% mid-tier band. Treat this boundary as reasoned, not
confirmed — see [rationale.md \[2\]](rationale.md#2-zram-resident-limit-budget-model).
`zram-size` stays `ram * 75 / 100` (unchanged — see the honest side-effect
noted in rationale.md \[1\]: the ceiling fraction lands on the same 0.75 in
both the 25%- and 20%-resident groups, a consequence of the math, not a
place the taper was dropped). Watermark stays at 125.

### 32G — same budget, no new data point

Nothing changes here that wasn't already true at 24G: same 20% resident
limit, same extrapolated placement, same 125 watermark. Included as its own
row purely because it's one of the fourteen anchors, not because anything
new happens at this size.

### 64G — the same budget, further out

Nothing new happens to the resident limit here — it's been 20% since 24G.
An earlier version of this design left it unset entirely at 64G+, reasoning
`zram-size`'s own (then much smaller) ceiling made a second cap redundant —
that reasoning conflated a memory-safety argument with what this budget
actually is: a CPU-tax bound on how much RAM may be mid-compression-cycle
at once, which doesn't stop mattering just because the virtual ceiling is
generous. 20% also lands exactly on `zswap.maxPoolPercent`'s own directed
value — the same physical leg, applied to two different mechanisms.
Watermarks ease to 100: kswapd can afford to be lazy here. For a box
running one huge, non-swap-shaped workload, the honest alternative is
`mode = "none"` — oomd and sysctls without any swap medium.

### 128G — the cap is Julian's own tier, twice over

This is the one large tier where two separate values are Julian's own
directly stated examples, not a borrowed placement like 24G/32G/64G: the
**20% resident-limit** figure ("taking a 20% slice of system RAM here is
about 25GB") and the **`lz4` + recompression** architecture ("we should use
lz4 and then zstd"), given even though he described this box as
*reluctant* — the same compute-boundedness distinction covered in the 2G
section above, not a contradiction.

`zram-size` here is **96 GiB** (`ram * 75 / 100` evaluated against 131072
MiB), not 64 GiB — Julian's own direct correction to an earlier,
power-of-two-only version of the rounding rule that had rounded this tier
down to the wrong grid point ("96GB is better"). The derivation: take the
20% resident budget, multiply by pi() (Julian's own formula — "take the
physical ram, multiply by pi and take the nearest base 2ish value"), and
round to the nearest 3-smooth number (OEIS A003586 — the sizes RAM/VPS
tiers actually ship in, which includes the ×1.5 family like 96 = 1.5 × 64,
not just plain powers of two). 20% × pi() ≈ 0.628, and the nearest
3-smooth *fraction* to that is 0.75 — which is why this collapses to the
same flat `ram * 75 / 100` used at every tier from 2G up, not a
per-tier-computed value. Full derivation and the worked-example table
checking it against every one of Julian's real corrections:
[rationale.md \[1\]](rationale.md#1-zram-disksize-curve).

zram at this scale is not survival — it's a parking lot for cold pages
that would otherwise squat on hot RAM for months of uptime. Everything
else as 64G.

## Constants shared by every level

These don't vary by RAM size — they're properties of the swap medium (zram)
or the reclaim/OOM machinery, not the box. `vm.swappiness` is **not** among
them any more: it splits by tier (120 eager, flat, at 256M-1G / 10-at-rest
with a PSI-gated relief valve to 60 for 2G-128G, a separate flat 25 for
zswap) — see the `swappiness` column in the table above, and the zswap
profile table below.

| Tunable | Value | Honesty |
|---|---|---|
| `vm.page-cluster` | 0 | ● [rationale \[4\]](rationale.md#4-vmpage-cluster--0) |
| `vm.watermark_boost_factor` | 0 | ● [rationale \[5\]](rationale.md#5-watermarks) |
| `vm.min_free_kbytes` | untouched | ○ [rationale \[6\]](rationale.md#6-vmmin_free_kbytes-untouched) |
| MGLRU `min_ttl_ms` | 1000 | ●, flagged [rationale \[7\]](rationale.md#7-mglru-min_ttl_ms--1000) |
| PSI threshold (oomd, zram mode) | 60% / 30s | ● [rationale \[10\]](rationale.md#10-psi-thresholds-60--30s) |
| zram `swap-priority` | 100 | ● [rationale \[12\]](rationale.md#12-swap-priority--100) |

## Zswap profile (`mode = "zswap"`)

A separate, flat profile for laptops/desktops with real disk-backed swap.
Several of these values were revised this round specifically to match
Elitebook's real, live, incident-tested production zswap config, rather
than the untested upstream/Pop!_OS defaults nixram shipped before — see
[rationale.md, Zswap profile](rationale.md#zswap-profile) for the full
reasoning behind each value.

| Tunable | Value | Honesty |
|---|---|---|
| `zswap.max_pool_percent` | 30 | ◆ (kernel default is 20; Elitebook really runs 30 in production) |
| `zswap.accept_threshold_percent` | 90 | ● |
| `zswap.shrinker_enabled` | on | ◐ (kernel ships this off by default; nixram turns it on as its own reasoned choice, not a sourced recommendation) |
| `zswap.zpool` | zsmalloc | ● (only option left on current kernels) |
| `vm.swappiness` | 25 | ◆ (Julian's own figure — this project's one real production data point, the elitebook's live zswap config) |
| `vm.page-cluster` | 2 (SSD) / 3, untouched (HDD) | ● |
| `vm.watermark_scale_factor` | 50, flat | ◆ (was 125, a plausible-sounding but unverified Pop!_OS number; Elitebook really runs 50 in production, halved from an earlier 100 after a real incident where 100 amplified a reclaim feedback loop under CPU contention) |
| systemd-oomd pressure duration | 3s (zswap only; limit % unchanged at 60%) | ◆ (Elitebook's real production oomd config, tied to a heavy/bursty compute workload; the shared zram/zswap default elsewhere is 30s) |

`zswap.max_pool_percent`, `vm.watermark_scale_factor`, and the oomd
pressure duration are the three zswap-mode values that changed this round.
`vm.swappiness` (25) was already matched to Elitebook and is unchanged.
