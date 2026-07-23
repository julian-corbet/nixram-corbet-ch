# Rationale

Every tunable nixram sets carries one of three honesty tags (the full taxonomy
lives in `levels.nix`'s header and is summarized in `docs/levels.md`):

- **sourced** — a real upstream distro/kernel-doc default or bound, applied
  as-is, or a formula whose endpoints are sourced.
- **extrapolated** — nixram's own curve, cap, or judgement call standing on
  or between sourced anchors. Reasoned, not measured.
- **default** — the kernel's own computed value, deliberately left
  untouched. Not a nixram opinion at all.

The notes below are numbered `[1]`–`[19]`. The numbering is load-bearing:
`levels.nix` and the `modules/*.nix` files reference these exact numbers in
their comments, so don't renumber without updating both.

## [1] zram disksize curve

**Decision:** the zram-size (disksize, the *ceiling*) is a flat fraction of
`ram` — **plain `ram`** (100%) at the 30%-resident tiers (256M-1G), **`ram
* 75 / 100`** (75%) everywhere else (2G-128G, spanning both the 25%- and
20%-resident groups).

**Derivation — Julian's own formula, worked through exactly, not
approximated.** He gave it hand-wavy: "take the physical ram, multiply by
pi and take the nearest base 2ish value." "Physical ram" here means the
resident-limit budget ([2]), which this project has called "physical" all
along (row 3 of `philosophy.md`). "Base 2ish" means a **3-smooth number**
(OEIS A003586: only 2 and 3 as prime factors — 1, 2, 3, 4, 6, 8, 9, 12, 16,
24, 32, 48, 64, 96, 128...), which is exactly the set of sizes RAM and VPS
tiers actually ship in: 256M, 384M, 512M, 768M, 1G, 1.5G, 2G, 3G, 4G, 6G,
8G, 12G, 16G, 24G, 32G, 48G, 64G, 96G, 128G. (No crisp one-word English
term for this exists; "3-smooth" or "regular number" is the closest formal
name — a real OEIS sequence, not invented for this project. The 3:2 step
specifically has an old name in music theory, "sesquialtera," if a more
evocative word is wanted.)

Working it through: since the resident budget is always a FIXED percentage
of `ram` (30%, 25%, or 20%, depending on tier group — [2]), and the
3-smooth grid is geometrically (multiplicatively) spaced, "nearest
3-smooth number to budget x pi" reduces to "nearest 3-smooth *fraction* to
(percentage x pi)" — a single ratio, the same in every tier within a
group, regardless of that tier's absolute RAM size:

| tier group | budget fraction | budget x pi() | nearest 3-smooth fraction | resulting ceiling formula |
|---|---|---|---|---|
| 256M-1G | 30% | 0.9425 | **1.0** | `ram` |
| 2G-128G | 25% or 20% | 0.7854 / 0.6283 | **0.75** (both) | `ram * 75 / 100` |

This is not a coincidence or an approximation — it's the exact nearest
grid point, computed precisely (see below), and it only comes out this
clean *because* the ratio is fixed per group. A live per-box formula using
fasteval's real `pi()`/`log()`/`round()` built-ins (verified against both
fasteval's own docs and zram-generator's vendored man page) was tried
first and technically works, but is unnecessary complexity once the
reduction above is done — two flat fractions produce the identical result
with none of the runtime branching.

**Checked precisely against Julian's own corrections and worked examples:**

| example | physical budget | budget x pi() | ceiling | Julian's own estimate/correction |
|---|---|---|---|---|
| 256M | 76.8 MiB (30%) | 241.3 MiB | **256 MiB** (ram) | "almost 400M" total (real+virtual) |
| 512M (vultr) | 153.6 MiB (30%) | 482.5 MiB | **512 MiB** (ram) | "maybe 450-500MB virtual RAM" |
| 768M (historical anchor, since removed — [16]) | 230.4 MiB (30%) | 723.8 MiB | **768 MiB** (ram) | "should get 768MB evidently" — exact |
| 1G (e2-micro) | 307.2 MiB (30%) | 965.1 MiB | **1024 MiB** (ram) | "almost a GB" |
| ~128G (server) | ~25.6 GiB (20%) | ~80.4 GiB | **96 GiB** (ram x 0.75) | "96GB is better" — exact |

Two of these (768M, ~128G) are Julian's own direct corrections to an
intermediate pure-power-of-two-only version of this formula, which had
rounded them down to 512 MiB and 64 GiB respectively — both technically
3-smooth-adjacent but the WRONG grid point, since pure powers of two
exclude the ×1.5 family (768 = 1.5 x 512; 96 = 1.5 x 64) that real RAM/VPS
tiers also use.

**Honesty:** extrapolated, own-measured for the underlying ratio
(zstd(level=3)'s real measured compression ratio, experiment 006:
2.09-3.30 across four real corpora, which `pi()` ≈ 3.14159 sits
comfortably inside); directed for the pi()/3-smooth-rounding mechanism
itself and both of its corrections (Julian's own formula and his own two
worked-example fixes).

**Honest side-effect, stated plainly:** because `ram * 75 / 100` applies
uniformly across both the 25%-resident group (2G-16G) and the 20%-resident
group (24G-128G), tiers that used to have visibly different ceilings now
don't — e.g. 16G and 24G both get a 75%-of-RAM ceiling despite a different
resident-limit budget underneath. This is expected, not an error: the
ceiling's only job is to stay generously above the resident limit, and the
resident limit itself still tapers correctly (25% -> 20% at 24G, [2]); the
ceiling fraction landing on the same 0.75 in both groups is a genuine
consequence of the math above, not a place the taper was accidentally
dropped.

**What this changes about the "central conflict":** zram-generator's own
upstream documentation recommends disksize fractions "in the range 0.1-0.5"
of RAM. The new formula still exceeds that at every tier (100% at 256M-1G,
75% at 2G-128G) but with genuinely round, RAM-buyable numbers rather than
an arbitrary 16 GiB cap disconnected from real RAM size. Under nixram's
resident-limit model, disksize is only the *virtual* ceiling; the real
physical budget is `zram-resident-limit` ([2]), which stays inside a
conservative fraction of RAM at every tier. Once a resident limit is doing
the actual safety job, a generous disksize costs nothing but a bit of
virtual address space, and lets compression stretch the same physical
spend further before the medium hits a hard wall. The counterargument is
real, and is exactly why `zram.sizing` defaults to `"both"`, never
`"virtual"` alone: on a host running `sizing = "virtual"` alone, disksize
*is* the only ceiling, and a generous one really can let compression
overhead balloon.

**Source:** the pi()/3-smooth-rounding derivation is Julian's own formula
and his own two corrections to it (768M, ~128G), worked through precisely
using real math, not approximated. The underlying ratio this formula
approximates is this project's own measurement (experiment 006).
Historical context only, no longer load-bearing for the formula itself:
Fedora's F33 "SwapOnZRAM" change shipped `min(ram/2, 4096)`; current
Fedora/zram-generator defaults scale to full RAM capacity capped at 8G;
Pop!_OS ships a 16 GiB ceiling; zram-generator's own upstream docs
recommend the 0.1-0.5 fraction range referenced above.

## [2] zram-resident-limit budget model

**Decision:** `zram-resident-limit` (mem_limit) tapers in three steps:
`ram * 30 / 100` (30%) at 256M-1G, `ram * 25 / 100` (25%) at 2G-16G,
`ram * 20 / 100` (20%) at 24G-128G. Every tier now sets a real physical cap
— none is left unset. **Attribution, precisely:** 20% at ~128G is Julian's
own stated figure ("taking a 20% slice of system RAM here is about 25GB");
30% at 256M-1G is also his (from the e2-micro/vultr/256M walkthrough). The
25% band and — importantly — *where exactly the step to 20% begins*
(24G, not 32G or 64G) are Claude's own extrapolated placement, not
something Julian specified. He gave one data point in the entire 2G-128G
range (20% at ~128G); the rest of the shape was built to connect it to the
30% anchor, and should be read as reasoned, not confirmed.

**Honesty:** mixed. The resident-limit primitive itself is sourced — a
first-class `zram-generator.conf` key that maps directly onto the kernel's
`/sys/block/zramN/mem_limit`. The specific fractions applied at each tier are
nixram's own extrapolated budget model, corrected from an earlier version of
this design (below).

**Reasoning:** disksize alone is a virtual ceiling that can misrepresent the
real physical cost once compression enters the picture. This budget is what
keeps the actual physical spend bounded regardless of what disksize claims —
but the reason for that bound changed, and the correction is Julian's own,
not a re-derivation from new evidence. An earlier version of this design
reasoned the budget as *memory-safety headroom*: `ram / 2` on the smallest
tiers "where headroom is scarce and every MiB has to be accounted for,"
tapering to 35% where "there's more slack," and unset above 64G because
"the disksize formula already caps the virtual ceiling... an additional
physical cap was judged redundant." That reasoning is now understood to be
wrong on two counts: it's the wrong lens (the physical leg is fundamentally
a *CPU-tax* budget — how much RAM may ever be mid-compression-cycle at once
— not a memory-safety backstop redundant with disksize), and it left the two
largest tiers with no physical cap at all, which is a real gap: on a 128 GiB
box with disksize shrunk to a small fixed cap (an old, since-replaced
formula — [1]) and no resident limit behind it, there was nothing bounding
how much of that pool could actually fill with compressed data at once
beyond disksize itself — the exact combination that produced this project's
own fleet's 20% (25 GiB) real-world zram99 sizing on a 125 GiB box that hit
swap-slot exhaustion under a transient compression-ratio collapse (see
`experiments/README.md` for the prior open-question framing this
replaces).

The corrected model: 30% at the smallest tiers (256M-1G), 25% in the middle
(2G-16G), 20% from 24G through 128G (bumping down earlier than the
disksize taper's own break point — deliberate, not derived from a
formula). This closes what was previously an open question at 64G/128G
(deliberately unset) — every tier now has a real, bounded physical cap.

A flat 20% from 24G through 128G was briefly revised to a fourth step (15%
at 64G/128G) on an absolute-cache-reservoir argument — 20% of a 128 GiB box
being a much bigger physical budget than 20% of a 24 GiB one. That revision
was **reverted**: Julian gave an explicit, specific figure for the 128G
tier ("taking a 20% slice of system RAM here is about 25GB"), and no
further re-derivation was asked for or warranted there — 20% stands as
stated, at every tier from 24G up.

**Rounding caveat:** both `diskSizeExpr` and `residentLimitExpr` are now
pure percentage formulas ([1]), so a machine that rounds up into a tier
gets exactly that tier's percentages applied to its OWN real RAM, not the
anchor's nominal value — a 33 GiB box that lands in the 64G tier still gets
20% resident-limit and 60% disksize evaluated against its real 33 GiB
(6.6 GiB and 19.8 GiB respectively), not the 64 GiB anchor. Rounding is
safe for both values now, with no fixed-cap distortion left to correct
for. See `faq.md`.

**Source:** zram-generator's own upstream docs (the `zram-resident-limit` /
`mem_limit` key); the kernel's zram sysfs documentation (`mem_limit`). The
specific percentages are nixram's own policy call (Julian's explicit
correction), not sourced from any upstream guidance.

## [3] vm.swappiness: 120 (256M-1G), 10 at rest / relief-gated (2G-128G), zswap 25

**Decision:** `vm.swappiness` for zram-backed swap is **120 at
256M/512M/1G**, **10 at rest from 2G through 128G, flat across all
eleven tiers** (adversarially confirmed, not tapered — see below), with a
PSI-gated relief valve that temporarily raises it to 60 during genuine,
sustained memory pressure — see [17] for the full mechanism and why 60
alone stopped being the right resting value. zswap's own profile uses
**25**.

**120, not 130 — Julian's own further revision, directed.** The value
went through three stages: 180 (Pop!_OS's own zram default) -> 130
(adversarially revised down, reasoning below) -> **120** (Julian's own
further revision, stated directly, no additional reasoning given beyond
the number itself). Applied as-is at every eager tier.

**Boundary moved from 1G/2G to 1G joining the eager group — a real
correction, not a rename.** An earlier version of this note put the
eager/reluctant split at 1G/2G, reasoning 1G had "enough true RAM to be
reluctant." That was undone once Julian explained the actual distinguishing
factor between his small-tier and large-tier examples directly ([9]):
"with 1GB RAM, you need to get whatever you can" describes urgency, the
same "light usage, RAM-desperate" story that justifies 256M/512M's eager
value — not "enough RAM to comfortably wait" the old 60 value was reasoned
from. Swappiness now groups with the compression-architecture split (row
4 / [9]) rather than cutting across it.

**Honesty:** mixed. The kernel's IO-cost model and the 0-200 range
extension are sourced. 180 as a value is sourced (Pop!_OS), but this
project no longer uses 180 anywhere — see the correction below. zswap's 25
is directed — Julian's own stated figure, sourced from the elitebook's real
production config (see the zswap-profile note below). 120 (the eager
tiers' final value) is also directed — Julian's own explicit revision.
The reluctant tiers' resting value, 10, is likewise directed — Julian's
own real historical data point (the fleet's previous Unraid server), given
directly when he questioned whether 60 was still too high. The tier split
itself (dire tiers eager, reluctant tiers low-at-rest) generalizes Julian's
qualitative direction ("swappiness should be low, and super low for
zswap... only push very cold pages there voluntarily"), and where the
eager/reluctant line falls is Claude's own policy call — but neither final
resting number is just reasoned anymore: the eager value went through an
adversarially-revised intermediate stage (130, down from an initial 180,
Claude's own call) then a further revision to 120 (Julian's own number);
the reluctant value went from a plausible-sounding but unchecked 60
straight to Julian's own real data point, 10. The PSI-relief mechanism
built around that 10 ([17]) is Claude's own design, not something Julian
specified beyond the intent behind it.

**Reasoning:** the kernel extended the swappiness range from the historical
0-100 to 0-200, with a documented IO-cost model behind the extension: values
above 100 are explicitly sanctioned for cases where swapping a page in is
cheaper than reading the equivalent data back from a filesystem cache miss.
That is exactly the situation with in-RAM compressed swap — a page fault
against zram costs a memcpy plus decompression, not a disk seek. This part
of the reasoning is scale-invariant: the medium-cost ratio doesn't change
with RAM size.

**But that isn't the only real consideration, and it used to be treated as
though it were.** A second, separate axis matters: how much true RAM
remains behind the physical leg, and how much file-backed page cache a box
has available to sacrifice before ever touching anonymous memory at all.
These genuinely change with RAM size, in a way the medium-cost ratio
doesn't — a box with little true RAM and little file cache (256M-1G) has
no real alternative to leaning on zram; a box with more of both (2G and up)
can afford to be reluctant, waiting for pages to actually prove cold before
compressing them at all.

**Why not Pop!_OS's 180 — an adversarial correction, then a further
directed revision.** The eager tiers' value was originally set at 180,
matching Pop!_OS's own zram default, on the theory that maximizing the
anon:file scan-target ratio maximizes how readily the kernel leans on
zram. That reasoning has a real hole: swappiness's ratio only matters
*once reclaim is scanning both LRU lists* — but on a box where file cache
is already near-empty (true here by construction), the file list's scan
target collapses toward zero regardless of the swappiness weight, because
the kernel scales targets by each list's *actual size*, not the ratio
alone. So most of the distance between 180 and a more moderate value buys
almost nothing in "which pool gets picked" — the choice was already forced
onto anon by the empty file list. What the high value *does* change is a
different thing entirely: *when* reclaim starts treating swap as available
at all — real observed behavior puts zram activation around ~85% memory
used at swappiness=200, vs. ~95% at swappiness=10. Higher swappiness
therefore means earlier and more frequent reclaim cycles, i.e. more total
compress/decompress traffic — real CPU cost that buys no offsetting
benefit on a box where the pool preference was already decided by cache
size, not the ratio. Pop!_OS's 180 was validated for desktop/handheld
contexts (SteamDeck, Bazzite) with CPU headroom to spare; transplanted
onto a fractional-vCPU cloud tier (256M-1G's realistic CPU profile for the
smallest of these), the same number sits at the worst point of that curve
— high trigger-frequency cost, with the pool-selection benefit already
exhausted. This reasoning brought the value to 130 — still well above the
reluctant tiers' resting value, still clearly on the "lean into zram" side,
without paying for the last, most expensive stretch of ceiling for no
measurable gain. Julian then revised it further, directly, to **120** — no
additional mechanism given, and none needed: this is his own number,
applied as stated, not a further derivation from the reasoning above.

**Why the reluctant tiers no longer just sit at the kernel's plain
default — this was revised again, and the revision is real, not
cosmetic.** This note previously argued a single flat 60 across 2G-128G
was "mechanism-correct, not lazy," on the reasoning that no precedent
tapers swappiness by RAM size the way `watermark_scale_factor` is tapered.
That argument still holds for the SHAPE (flat, not tapered by size) — but
60 itself turned out to be the wrong resting value once Julian directly
questioned it: "60 is still very high. The old unraid server had 10, the
elitebook has 25." 60 was never chosen *for* this tier group — it's simply
the kernel's own plain, untuned default, inherited by not picking anything
else. It was never checked against this project's own real, historical
fleet data until asked directly. Once it was: 10 (a real prior production
value, not a guess) and 25 (a different real production value, on a
different medium/mode) both sit well below 60. The reluctant tiers now
rest at **10**, with a PSI-gated relief valve (60 while pressure is
genuinely elevated) restoring exactly the behavior 60 used to provide
permanently — see [17]. Kernel/distro-guide precedent for a flat,
non-tapered shape across 2G-128G still stands; the specific resting NUMBER
does not, and 10 is directed, not a further derivation.

**A real limitation of the RAM-size-only tiering, stated rather than left
silent:** "bigger boxes accumulate proportionally more file cache" is a
correlation for a *typical multi-service host*, not a physical law — it
breaks for specialized, anonymous-memory-heavy workloads at any RAM size
(an in-memory database or a large single-process cache can hold nearly all
its resident RAM as anonymous pages, with little file cache to sacrifice
regardless of box size). nixram's tiering has no workload signal, only RAM
size — a 2G+ box running one such anon-heavy service will still get the
"comfortable, reluctant" treatment (10 at rest, relief-gated) its actual
cache profile may not support. This is a scope limitation, not a bug:
nixram's per-level defaults assume a typical multi-service host. A box
that doesn't fit that profile should override `swappiness` (and
`zram.residentLimitOverride`) directly rather than expecting the level
default to reason about workload shape it cannot see.

**zswap (25, down from 120):** a cache miss here is a REAL disk read —
worse than the reluctant zram case's worst case — so it should be more
reluctant still, not less. This is no longer a reasoned midpoint: it's
sourced from this project's own fleet. The elitebook runs zswap in
production and independently converged on 25 for exactly this reason (a
mixed LLM+browser workload that needs anonymous memory to stay resident,
not get evicted to a disk-backed cache). Nothing in the adversarial review
found reason to revise this one — it's the single best-sourced value in
this whole note.

**Source:** kernel vm sysctl docs (swappiness 0-200 range, IO-cost
rationale, `get_scan_count()`'s list-size-weighted scan targets); Pop!_OS
default-settings (PR #163 lineage) for the original 180 anchor, now revised
down; this project's own fleet (the previous Unraid server's real,
historical 10; elitebook's real, production-tuned 25 for zswap) for the
two directed resting values; Julian's own direct revision for the final
120 value. The tier split, the intermediate 130 revision, and the
reasoning connecting it to file-cache availability are nixram's own policy
call, not sourced from any upstream guidance — confirmed by an adversarial
research pass that no upstream precedent tapers swappiness by RAM size at
all.

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

**A live counter-example worth naming, not because it changes the decision
but because it was momentarily mis-stated:** vultr (real zram,
confirmed via its own `zram-generator.conf`) runs `page-cluster=3`. A first
pass called this "the correct kernel default for HDD swap" — wrong on two
counts: zram is never HDD-backed (it's always RAM), and 3 there isn't a
deliberately-chosen resting value at all, just the untouched kernel default
on a box that doesn't run nixram (or any equivalent tuning) at all. It's
evidence of a real, fixable inefficiency on that specific box, not a
counter-example to this note's reasoning — the reasoning above (no seek
cost on zram, read-ahead is pure waste) applies to it exactly as much as to
any other zram device.

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
The 256M opt-out is extrapolated, deliberate, and now own-measured (see
below) rather than unmeasured.

**Reasoning:** systemd-oomd itself carries a daemon-resident RSS cost, and on
a 256M box that cost is a meaningfully larger fraction of total memory than
on any larger tier. The kernel's own last-resort OOM killer, plus
`OOMScoreAdjust = -900` on protected units, stays active at every level
including 256M — disabling systemd-oomd removes the PSI-based early-warning
layer, not the kernel's OOM killer itself.

**Measured (experiments/README.md, 001):** a real ephemeral NixOS VM at the
256M level with `oomd.enable` force-overridden to `true` put `systemd-oomd`'s
real idle `VmRSS` at 4.77 MiB — 1.86% of total RAM, 6.2% of this tier's own
resident-limit budget. Real and measurable, not negligible, but the more
striking number from that same measurement: the box was already at 51.5%
idle memory usage before oomd was even added. On a box where more than half
of RAM is already baseline overhead at idle, oomd's own ~2% permanent tax is
a real subtraction from the exact headroom it exists to protect — this
result supports the existing 256M opt-out, now for a sharper, data-backed
reason than the original unmeasured judgment call.

**Source:** the 4.77 MiB / 1.86% figure is this project's own real
measurement (experiments/001); the PSI thresholds systemd-oomd would
otherwise use are its own upstream defaults ([10]).

## [9] Compression algorithm: zstd(level=3) alone through 1G, lz4+recompression from 2G up

**Decision:** two different architectures, split at the 1G/2G boundary, not
a single formula:

- **256M, 512M, and 1G:** `zstd(level=3)` primary, **no recompression
  pass at all**.
- **2G through 128G:** `lz4` primary, paired with `zstd(level=3)`
  recompression ([11]).

This is a firm pairing rule, not a size-derived threshold: whenever the
primary is already zstd(level=3), recompression is off, full stop; whenever
it isn't, a `zstd(level=3)` recompression pass runs behind it. Never mix
architectures within one tier.

**Correction history — this design has been wrong twice in opposite
directions, worth stating plainly rather than glossing over.** An early
version put 256M/512M in the zstd-only bucket alongside 1G with no
recompression. That was revised, reasoning that the dire tiers must "lean
on zram willingly" and needed a cheap primary — but this revision
over-applied Julian's own explicit instruction, which actually said the
opposite: "make sure that everything up to a GB goes to zstd primary and
done... IF we encounter such a weak specimen we go for lz4 probably AND
then recompress to zstd. But this is only for the weakest of weak CPU
bound machines. And even then I am not sure." The "lz4 then recompress"
path was a narrow, uncertain exception for the weakest possible hardware —
not the default for the whole 256M-768M band. Giving 256M/512M/768M the
lz4+recompress architecture was a real implementation mistake, caught and
reverted back to the original instruction: 256M through 1G all use
zstd(level=3) alone.

**Honesty:** directed for the architecture split itself (Julian's explicit
instruction, quoted above) — 256M-1G go zstd-alone, 2G+ go lz4+recompress.
Extrapolated for the specific compression settings within that split
(`zstd(level=3)` rather than another level, `lz4` rather than `lzo-rle`),
backed by this project's own measurements (experiments 005 and 006).

**Reasoning, the pairing rule:** recompression's entire job is recovering
density that a cheap primary traded away for speed. Pair it with a primary
that's already dense (zstd) and there is nothing left for it to add — it
would just burn CPU re-compressing pages that are already about as dense as
that pass would make them. This is why an earlier version of this design
(plain `zstd` as primary at *every* level above 256M, still running
recompression behind it) was a real mistake, not a stylistic choice: it paid
zstd's slower decompression on every page fault while gaining almost nothing
from the recompression pass riding along behind it. The fix is not "tune the
level," it's "never pair the two."

**Attribution, precisely — this matters here more than usual.** Julian's
own worked examples, in his own words: "everything up to a GB goes to zstd
primary and done" (256M/512M/1G, zstd-alone); the ~128G server uses
lz4-then-zstd ("we should use lz4 and then zstd"), while being explicitly
described as *reluctant* ("reluctant to take stuff to swap and only use it
for cold stuff"). He then asked for this to be generalized ("generalize
them... each story is an example of the more general story"). The firm
pairing rule and the account of *why* the two groups differ are Claude's
attempt at that generalization; the architecture split itself (where the
line falls) is his.

**Resolved, directly by Julian — an earlier "reluctance" framing was wrong,
not just incomplete.** Before this correction, an earlier version of this
note (when 256M/512M/768M still wrongly had the lz4+recompress
architecture) tried to explain why 1G alone was zstd-only using a
true-RAM-headroom/reluctance argument, found that story directly
contradicted by the ~128G example (also reluctant, yet keeping
lz4+recompression), and left it as an open, unresolved tension. Asked
directly why 1G and ~128G differ, Julian's answer wasn't a headroom
argument at all — it's a **workload compute-boundedness** argument, and it
turns out to explain the *real* split (256M-1G vs. 2G-128G) cleanly,
because it's about workload profile, not a single tier's headroom:

> "The difference is: With 1GB RAM, you need to get whatever you can. With
> the big box you can wait for it later. The bigger box is also more
> compute bound than the smaller one. The small ones see few users, light
> usage and the challenge is to keep apps hot / in RAM. For the big box
> with LLMs and genAI and stuff on top of oodles of Apps it is compute and
> RAM that matters."

Unpacked: 256M-1G-class boxes see light, few-user usage — there's no heavy
concurrent demand competing for their CPU, so paying zstd's cost directly
and synchronously, right on the compress path, doesn't rob anything that's
actually needed elsewhere. And because RAM is genuinely tight at this
scale, the right move is to grab whatever density is available immediately
rather than defer and hope an idle window shows up — "you need to get
whatever you can." The 2G-and-up class, by contrast, increasingly runs
actively compute-bound workloads (LLMs, genAI, oodles of concurrent apps)
that compete hard for the exact same CPU a synchronous dense primary would
consume — so the cheap lz4 primary protects that live compute demand on
the hot path, and the expensive zstd recompression pass is deferred to
whenever the box is genuinely idle instead, which a heavily-multiplexed
machine at that scale reliably has ("you can wait for it later"). Every
tier from 1G up is "reluctant" in the swappiness sense (waiting for pages
to prove cold before touching them — [3]), but that's a separate axis from
*how much it costs to compress a page once it's chosen* — and it's this
second axis, not swappiness, that decides primary-vs-recompression
architecture.

This is genuinely new information, not a refinement of the earlier
headroom-only story — it should be read as **directed** (Julian's own
explanation for the 1G-vs-~128G question), generalized by Claude to the
1G/2G split itself: he described the two ends (1G, light usage; ~128G,
compute-bound), and the placement of the actual boundary at 1G/2G rather
than somewhere else in between is Claude's own inference, reasonably
motivated (2G is the smallest tier where multiple concurrent
services/workloads become the realistic norm rather than the exception)
but not something he specified tier by tier.

**Reasoning, lz4 as the fast primary (every tier that pairs with
recompression):** this project's own experiment
(`experiments/005-lz4-vs-lzo-rle-primary/`) measured `lz4` against `lzo-rle`
(the kernel's actual zero-run-aware LZO backend, not the plain `lzo1x_1` a
userspace library would silently substitute) on real zram devices with real
corpora: lzo-rle is 2.8-7.5% denser on every corpus tested, but lz4
decompresses 12-25% faster on 3 of 4. Since decompression latency is the one
primary-slot cost recompression can never help with (paid synchronously on
every page fault), lz4 wins uniformly whenever a recompression pass exists
behind it — which, under the corrected shape above, is every tier from 2G
up (256M-1G run zstd(level=3) alone with no recompression pass at all).

**Reasoning, zstd(level=3) as both the dense primary (256M-1G) and the
recompression target (everywhere else) — one setting, not two.** Rather
than a separate exotic recompression level (an earlier version of this
design used `zstd(level=12)`), the same `zstd(level=3)` used as 1G's primary
is now also the recompression algorithm everywhere else: one dense
reference point in the whole system, not several. The level question itself
was measured directly rather than assumed: zstd's own docs claim
decompression speed is "roughly the same at all settings," which would mean
the level choice only costs on the compression (reclaim-time) side, not the
synchronous page-fault path that matters most — but that claim comes from
zstd's own general-purpose, large-file benchmarks, not validated at zram's
actual 4 KiB-page granularity, and this project already learned the cost of
trusting the wrong benchmark once (the `lzo1x_1`-vs-`lzo-rle` trap in
experiment 005). So it was measured: real zram device, real corpora, levels
1/3/6/9/12, 100/100 trials integrity-verified
(`experiments/006-256m-primary-zstd-level/RESULTS.md`). Result: decompression
really is flat across levels at 4 KiB granularity too (~440-540 MB/s on
every real corpus regardless of level); level 3 gets a real 1.5-2.8% ratio
gain over level 1 on 3 of 4 real corpora for a modest 7-16% compression-side
cost; the real cost cliff sits between level 3 and level 6 (compress
throughput drops roughly 3x for a comparable ratio gain), not between 1 and
3, and level 9 is nearly pure waste over level 6. **Level 3 is the floor —
never step down to level=1 as a fallback.**

**Source:** the lz4-vs-lzo-rle primary choice is this project's own measured
experiment (`experiments/005-lz4-vs-lzo-rle-primary/RESULTS.md`); the level
choice is this project's own measured experiment
(`experiments/006-256m-primary-zstd-level/RESULTS.md`); which tiers get
which architecture is nixram's own policy call, not sourced from any
upstream default — Fedora and zram-generator's own docs both use plain zstd
as their worked example, which
is exactly the primary/recompression conflation the pairing rule fixes.

## [10] PSI thresholds: 60% / 30s

**Decision:** `ManagedOOMMemoryPressureLimit = 60%`,
`ManagedOOMMemoryPressureDurationSec = 30s`, at every level (dormant wherever
oomd itself is disabled) — **except `mode = "zswap"`, where the duration
drops to 3s system-wide; the 60% limit is unchanged.** See the zswap-profile
note below for why.

**Honesty:** mixed. The 60%/30s baseline is sourced. The `mode = "zswap"`
duration override (3s) is directed — see the zswap-profile note below.

**Reasoning:** the 60%/30s baseline values are not nixram inventions — they
are systemd-oomd's own upstream defaults, unmodified. nixram sets them
explicitly, rather than relying on the built-in `enableSystemSlice` /
`enableUserSlices` helpers (which hardcode an 80% limit with no duration
control), purely so per-mode/per-level tuning of these numbers is possible.
Every zram tier uses the same, stock values; `mode = "zswap"` is the one
place that tuning knob has actually been used, cutting the duration to 3s
(see below) while leaving the limit percentage untouched.

**Source:** `oomd.conf(5)` (`DefaultMemoryPressureLimit=60%`,
`DefaultMemoryPressureDurationSec=30s`).

**Verified against the mechanism, not just convention.** `avg10` of the
`memory.pressure` "full" line (confirmed against `oomd-manager.c` source: it
compares literally against `ctx->memory_pressure.avg10`) is the metric
`ManagedOOMMemoryPressureLimit`/`...DurationSec` actually monitor. It is a
pure ratio -- blocked-wall-clock-time over elapsed-wall-clock-time, with no
RAM or byte term anywhere in its computation -- so a 60%-for-30s reading
means the same thing (every runnable task blocked, three seconds in five,
for half a minute) on a 256M box and a 128G box. This is why nixram ships
the same flat value at every level rather than tapering it: there is no
mechanism-level reason to taper a scale-invariant ratio. Prior art agrees:
systemd-oomd and Meta's own oomd (the C++ project it's a from-scratch
reimplementation of the ideas from) both ship one flat number fleet-wide,
with zero size-tiering guidance in either project's documentation.

One correction this surfaced: NixOS's own `systemd.oomd` module
(`enableSystemSlice`/`enableUserSlices`) defaults to an 80% limit, and its
source comment cites Fedora as the origin -- but Fedora's actual shipped
values are 50%/20s on `user@.service`, not 80% at all. Neither 80% nor its
claimed origin holds up; nixram's 60%/30s is the real compiled-in
systemd-oomd upstream default (`DEFAULT_MEM_PRESSURE_LIMIT_PERCENT=60`,
`DEFAULT_MEM_PRESSURE_DURATION_USEC=30s` in systemd's own source), the most
solidly-anchored choice available -- this is why nixram sets the two slices
itself rather than using the NixOS helpers, per the comment in
`modules/oomd.nix`.

**The one place RAM size legitimately still enters this mechanism** is not
the threshold value -- it's whether to run the daemon at all. A threshold is
a ratio (scale-invariant by construction); a daemon's resident memory is an
absolute byte quantity, and bytes-over-total-RAM is definitionally
size-dependent -- a few-MB daemon costs a much larger slice of 256M than of
128G. That is a resource-budget question ("can this tier afford to run the
monitor"), categorically different from the detection-scale question
("what ratio means thrashing") the threshold answers -- see [8]. The 256M
opt-out should be settled by measuring that cost (experiment 001), never by
retuning 60%/30s itself.

**zram and zswap share this threshold, not the severity behind it.**
`memory.pressure`'s "full" line is an aggregate: the fraction of time
*all* non-idle tasks were blocked, with no information about the size or
variance of the individual stalls that sum to it. zram's stalls are
CPU-bound decompression, microseconds each, bounded, no block layer
involved -- severity scales roughly linearly with the percentage. zswap's
cache hits look the same, but a miss falls through to a real, possibly slow
disk, and the miss rate rises exactly as pressure rises -- so the same 60%
reading can be built from far fewer, far larger stalls, each individually
much more perceptible, and zswap misses register on `io.pressure` at the
same time. oomd itself has no way to AND two pressure signals into one kill
rule, so this can't be fixed by changing the trigger -- nixram instead logs
`io.pressure` alongside `memory.pressure` as a corroborating diagnostic on
`mode = "zswap"` (never wired into the kill decision itself), so a pressure
episode can be told apart as CPU-bound or disk-bound after the fact. See
`oomd.pressureDiagnostics.*` in `modules/default.nix` and
`modules/oomd.nix`.

This paragraph is about the 60% *limit* specifically, which zram and zswap
still do share unmodified. The *duration* half of the pair no longer is:
`mode = "zswap"` cuts it to 3s (above), a directed correction made once the
real fleet data point behind it was actually checked, not a further
consequence of the severity argument here.

## [11] Idle recompression: zstd(level=3), gated on genuine idleness

**Decision:** a rolling two-phase systemd timer drives zram idle-page
recompression: each run recompresses whatever the *previous* idle run
idle-marked and that has stayed untouched since, then marks the current
resident set idle for the *next* idle run to act on. The timer fires
frequently (default every 15 minutes) but only acts if CPU PSI shows the
box is genuinely quiet right now — cadence is "whenever there is idle
time" (Julian's explicit correction), not a fixed calendar interval.
Recompression algorithm is `zstd(level=3)` (down from an earlier
`zstd(level=12)`) — the same dense setting used as 256M-1G's primary, not a
separate exotic level. Off at 256M, 512M, and 1G, where the primary
is already `zstd(level=3)` and [9]'s pairing rule applies; on from 2G up.

**Honesty:** mixed. The kernel primitive is sourced: kernel ≥6.2 with
`CONFIG_ZRAM_MULTI_COMP` exposes `recompress` and `idle` controls under
`/sys/block/zramN/`, but the kernel never triggers recompression on its own,
and has no native "run when idle" unit type — userspace has to drive both.
The two-phase timer design, the idle-gating mechanism, the check-frequency
default, and the `zstd(level=3)` choice are all nixram's own policy
(Julian's explicit direction where noted).

**Reasoning, the two-phase design:** a naive "mark idle, then immediately
recompress what's marked idle" in a single run would recompress the entire
device every single time, because every resident page looks idle in the
instant right after being marked — the kernel clears a page's idle flag the
moment it's written again, so idle-ness only means anything after a real
dwell period has passed. nixram's design splits marking and recompressing
across two separate idle-run firings, so "idle" actually reflects one full
interval of non-use before a page is judged a good recompression candidate.

**Reasoning, idle-gated cadence instead of a fixed calendar:** a fixed
"daily" run has two real failure modes a busy box and a quiet box both hit.
On a box that's busy at exactly the scheduled time, "daily" forces
low-priority background work into contention with real load regardless —
exactly the interference this maintenance job exists to avoid. On a box
with real idle windows (nights, low-traffic periods), "daily" wastes them:
it only gets ONE chance a day to mark and recompress, when it could have
gotten several. The fix: check often (every 15 minutes by default, tunable
via `zram.recompressionTimer.onCalendar`, which is now a check-FREQUENCY,
not a run-frequency), and gate the actual work on CPU PSI's "some" avg10
line being low (a quiet box proceeds; a busy one logs a line and waits for
the next tick). A box under sustained, genuine load may simply never get a
window to recompress at all — which is the CORRECT behavior for a job whose
entire premise is "only touch this when nothing else needs the CPU," not a
bug to work around.

**Reasoning, `zstd(level=3)` instead of `zstd(level=12)`:** an earlier
version of this design reasoned that idle pages, being off the hot path,
justified spending far more CPU per page than the primary (levels up to 12,
just short of zstd's optimal-parser cost cliff at 13). That reasoning
wasn't wrong about level 12 being *affordable* in isolation — but it
treated the recompression level as its own separate design question, when
the simpler, equally-defensible policy is to reuse the SAME dense setting
already established as correct for 1G's primary (`zstd(level=3)`, measured
in experiment 006: real density gain over level 1, at a modest cost, well
short of the level-6 cliff where compress throughput craters roughly 3x for
comparable ratio gain) — one dense reference point in the whole system
instead of two. This is a simplification, not a re-measurement: whether
`zstd(level=3)` recovers as much absolute density as `level=12` did on
genuinely idle, off-path pages remains open (`experiments/README.md`, 004,
still unmeasured for the higher levels specifically) — tunable via
`zram.recompressionAlgorithmOverride` if a measurement later argues for
going denser again.

**Reasoning, off at 256M/512M, same as 1G:** an earlier version of
this design gave 256M/512M the lz4+recompression architecture,
reasoning they were forced to "lean on zram willingly" and needed a cheap
primary with recompression behind it. That was a real implementation
mistake — Julian's own instruction was "everything up to a GB goes to zstd
primary and done," with lz4-then-recompress reserved as a narrow, uncertain
exception for the weakest possible hardware, not the default for the whole
band (see [9]'s correction history). With that fixed, recompression has
nothing to add at these tiers for the same reason it has nothing to add at
1G: the primary is already dense.

**Source:** kernel zram admin-guide / sysfs docs (`recompress`, `idle`
controls, multi-compression support); kernel PSI docs (`/proc/pressure/cpu`,
the "some" line's definition — see the OOM-backstop research behind [10]
for the fuller PSI mechanics this reuses).

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

## [13] Recompression on 64G and 128G boxes

**Decision:** the idle-recompression timer stays on by default at 64G and
128G, same as every tier from 2G up.

**Honesty:** extrapolated for it staying on specifically at these two
tiers; directed for the underlying reason recompression runs from 2G up at
all (workload compute-boundedness, [9]).

**Reasoning:** these tiers are exactly the ones [9]'s compute-boundedness
argument describes directly — machines this large increasingly run
LLMs/genAI/many concurrent apps competing for CPU, so the cheap-primary-
plus-deferred-recompression shape is the intended fit, not just consistency
for its own sake. The marginal value is still genuinely modest in absolute
terms once the physical resident-limit budget (20% of RAM, [2]) is already
large, but the mechanism itself — protect live compute demand on the hot
path, recover density later when idle — is exactly what these boxes need,
not a leftover default. The documented alternative for a box running one
large, non-swap-shaped workload that ISN'T actually compute-bound in the
sense above is `services.nixram.mode = "none"`, which turns off the whole
zram/zswap layer (not just recompression) and leaves only the oomd and
sysctl layers running.

**Source:** none for the specific choice to leave it on at these two tiers
— nixram's own judgment call; the underlying compute-boundedness reasoning
is Julian's own, quoted in full in [9].

## [14] PSI pressure diagnostics on zswap tiers

**Decision:** `oomd.pressureDiagnostics.enable` defaults to true only when
`mode = "zswap"` (false for `zram`/`none`); when on, a systemd timer
(default `onCalendar = "minutely"`) logs one journal line combining
`memory.pressure` and `io.pressure`'s "full" lines. Diagnostic only, never
wired into any kill decision.

**Honesty:** extrapolated. No upstream precedent for this specific
combination exists — it's nixram's own addition — but it's grounded in
verified PSI/oomd research, not a guess: see the extended note under [10]
for why zram and zswap can share the same PSI threshold value without
sharing the same real severity behind a given reading, and why oomd itself
has no mechanism to combine two pressure signals into one kill rule, which
is what makes an independent, out-of-band diagnostic the only way to
recover that lost distinction after the fact.

**Reasoning:** zswap cache misses fall through to a real disk device, and
the miss rate rises exactly as pressure rises, so a sustained
`memory.pressure` reading on a zswap tier can hide much worse per-stall
latency than the identical reading on zram, which never touches a disk at
all. `io.pressure` rises alongside `memory.pressure` specifically during
disk-fallthrough misses, making it a free corroborating signal — but only
on zswap tiers; on zram, `io.pressure` would sit near zero regardless of
severity and add nothing. The interval (`minutely`) is deliberately coarse:
this is forensic logging for after-the-fact correlation, not a detection
mechanism competing with oomd's own 1-second internal poll, so log volume
was weighted over responsiveness.

**Source:** none for the specific combination — nixram's own addition,
reasoned from the PSI/oomd research behind [10].

## [15] Primary-algorithm override: immediate density vs. average density over time

**Decision:** `zram.compressionAlgorithmOverride` exists as a per-box escape
hatch for the primary algorithm, alongside the level defaults set in [9]
(`zstd(level=3)`/no recompression at 256M-1G, `lz4`+recompression from 2G
up). No level's default changes because of this — it is a documented
override pattern, not a new tier.

**Honesty:** extrapolated — this is nixram's own addition, not an upstream
recommendation, and the case it's for is deliberately narrow.

**Reasoning:** [9]'s "lz4 wins uniformly on every tier that also runs
recompression" argument was built entirely on a CPU-cost lens (lz4 vs.
lzo-rle, experiment 005) — it was never checked against a different,
real tradeoff: recompression is idle/dwell-triggered on a systemd timer,
never pressure-triggered, so it structurally cannot help during an acute
spike. A page written seconds before a box goes tight sits at whatever
density the primary gave it, full stop, regardless of RAM tier. On a box
with real slack this doesn't matter — lz4's speed plus the recompression
pass catching up later (as designed) is still the better trade. On a box
running with almost no `zram-resident-limit` headroom, it can matter a
great deal: worse density under a fast-but-thin primary means the fixed
physical budget fills up sooner under the same pressure event, independent
of decompression speed entirely. Hitting that limit is a hard wall, not a
soft degrade — a 2014 kernel fix (`SWAP_FULL`, Minchan Kim) exists
specifically because, before it, the VM kept trying to reclaim onto an
already-full zram device and the system hung; the fix made the VM recognize
"full" and route to the OOM killer instead. So the failure mode at the
resident limit is real and immediate, not hypothetical.

This is genuinely a different axis from CPU cost, and was tempting to
generalize into a formal "CPU class" dimension crossing the whole RAM
ladder — investigated and rejected. RAM tier does not reliably predict CPU
headroom (a small-RAM container on a many-core host and the same RAM tier
on a single shared/burstable vCPU cloud instance are nothing alike), so
the instinct behind wanting a second axis is sound. But unlike RAM — which
has a stable, checkable ground truth (`/proc/meminfo`, the `detect-level`
tool) — CPU class has no equivalent, and for anything containerized it
isn't even a *stable* property: a noisy neighbor co-scheduled onto the same
node changes the real picture with no config change at all, silently
invalidating a declared value. A formal axis would also have needed to
separate two properties a simple "shared vs. dedicated" label conflates —
raw per-core speed (what actually governs decompression latency, since
swap-in decompresses synchronously in the faulting thread, confirmed via
kernel source — other cores are irrelevant to that one fault) versus
contention/steal-time unpredictability (what "shared" actually risks) — a
dedicated-but-slow core is still slow. Given every other zram tunable
already has a per-box override (`diskSizeOverride`, `residentLimitOverride`,
`priorityOverride`, `recompressionAlgorithmOverride`), adding the one that
was missing and stating the wanted outcome directly per box is more honest
than inventing a taxonomy standing on an unstable, poorly-defined axis.

With [9]'s current shape (256M/512M/1G already default to zstd/no
recompression), this override's practical direction runs the other way from
how it first read: not "flip to zstd for a CPU-starved box," but the
tentative escape for a box too CPU-starved even for `zstd(level=3)` — flip
that one box back to `lz4` + a recompression pass turned on via
`recompressionTimer.enable`/`recompressionAlgorithmOverride`, the shape 2G+
already uses by default. See [9] for the full statement; kept brief here
since [9] is now the canonical version.

**Source:** the density-vs-budget mechanism is confirmed (kernel source,
`SWAP_FULL` history); the recommendation to use the override instead of a
new axis is nixram's own judgment, reasoned through and adversarially
checked, not sourced from any upstream guidance — no real system was found
that conditions compression-algorithm choice on CPU class at all.

## [16] The 768M anchor: added, then removed once fully redundant

**Decision:** there is no `768M` anchor. One existed briefly this session
(a fifteenth anchor between `512M` and `1G`) but was removed once two
subsequent corrections made it provably identical, in every formula, to
its neighbors. Fourteen anchors, `256M` through `128G`, once again.

**Honesty:** extrapolated — nixram's own addition and its own later
removal, neither sourced from any upstream anchor scheme, though the real
RAM sizes that motivated adding it are sourced (see below).

**Why it was added:** `1G`'s zram *architecture* (dense primary, no
recompression) once differed from `512M`'s (cheap primary plus
recompression), and a 768 MiB box rounds up into `1G` by default —
silently inheriting the wrong architecture, not just a slightly-off
percentage. Real gap, not hypothetical: budget/OpenVZ VPS resellers
(RackNerd and others) commonly ship 768 MiB tiers, and legacy AWS/GCP
micro instances (`t1.micro` ~613 MiB, `f1-micro` ~614 MiB) land in the
same band.

**Why it was removed:** two later, independent corrections closed the gap
it existed to bridge. First, 256M-1G were unified onto one zram
architecture (`zstd(level=3)` alone, no recompression — [9]), closing the
architecture gap directly. Second, 1G's swappiness was unified into the
eager group too ([3]), after Julian's own compute-boundedness explanation
put 1G with the dire tiers rather than the reluctant ones — closing the
one remaining gap (swappiness) the anchor had been keeping separate.
Checked directly: `512M` and `1G` are now identical in every formula —
`residentLimitExpr = ram * 30 / 100`, `diskSizeExpr = ram` ([1]),
`compressionAlgorithm = zstd(level=3)` with no recompression ([9]),
`swappiness = 120` ([3]), `watermarkScaleFactor = 200`,
`oomd.enable = true`. A 768 MiB box rounding up to `1G` gets byte-for-byte
the same treatment a dedicated `768M` anchor would have given it — the
anchor had stopped changing anything. Keeping a fifteenth, fully inert
anchor around serves no purpose beyond a documentation footnote, and costs
a tier's worth of tests, comments, and reader-facing table rows to
maintain — removed as part of a full-project prune once the redundancy was
confirmed, not left as a "maybe keep it" compromise.

**The general lesson, worth keeping even though the anchor itself is
gone:** a continuous input rounded into a discrete bucket, where the
resulting policy is *not* monotonic across buckets, is a documented
failure class under other names in other fields (boundary value analysis
in software testing; "benefit cliff" in public-policy economics). If a
future correction ever reintroduces a real discrete-policy difference
between two adjacent anchors again, this is the shape to watch for: check
whether every RAM size in the gap between them actually supports whichever
side it silently rounds into.

## [17] Reluctant-tier swappiness: 10 at rest, PSI-gated relief valve for genuine overflow

**Decision:** the reluctant tiers (2G-128G) drop from swappiness=60 (the
plain kernel default) to **10** at rest. A new PSI-gated mechanism
(`zram.swappinessRelief`, on by default only on these tiers) temporarily
raises swappiness to 60 while memory pressure is genuinely, sustainedly
elevated, then lowers it back to 10 once the pressure has actually
resolved.

**Honesty:** directed for both the direction and the anchor values — 10
is Julian's own real historical data point (the fleet's previous Unraid
server ran swappiness=10), given directly when questioning whether 60 was
still too high. The relief mechanism's existence and its purpose ("swap is
for overflow when upgrades run or whatever, or for icecold pages") are
also his, stated directly. The specific thresholds and check cadence
below are Claude's own implementation, reasoned but unvalidated — a real
VM test now exercises the mechanism at least once (see below), which is
progress, not the same thing as a settled validation.

**Why 60 was wrong for this tier group, restated plainly.** 60 is simply
the ordinary, un-tuned kernel default — it was never chosen *for* a
reluctant, server-class tier, it was just what was left after ruling out
the eager tiers' higher values. It doesn't refuse to touch anon memory;
it just doesn't prefer it strongly. On a box that legitimately runs "full"
as its normal operating state (many resident services, not much
reclaimable cache to begin with), 60 gives the kernel real license to
reach for swap during entirely ordinary fluctuation — not because
anything is actually wrong, just because the ratio permits it once
reclaim happens to trigger at all. That's precisely the failure mode
Julian flagged: "we don't want them to start swapping just because."

**Why a single lower number isn't enough on its own.** A flat, very low
swappiness (10, or even lower) makes swap-touching rare — but it doesn't
distinguish "routine fullness" from "a genuine overflow event" (a deploy
spike, a real burst of load) where the kernel *should* actually be allowed
to lean on swap. A permanently low number handles the "don't swap just
because" half of the request but not the "swap is for overflow" half —
overflow still needs the valve to open when it's actually happening, not
stay shut always. Hence a two-state design, not a single static value.

**The mechanism, precisely — mirrors the CPU-PSI idle-gate pattern already
used for recompression ([11]), applied to a different signal:**

- Reads `/proc/pressure/memory`'s "some" line every `checkIntervalSec`
  (default 30s — pressure can build far faster than the 15-minute cadence
  used for CPU-idle checks, since this is about *reacting to* pressure,
  not waiting for *idleness*).
- **Entering relief** (baseline -> 60): triggered by `avg10` (the 10-second
  average) crossing `pressureHighThreshold` (default 10%) — a fast signal,
  so a real spike gets a response within roughly one check interval.
- **Leaving relief** (60 -> baseline): triggered by `avg60` (the 60-second
  average) dropping below `pressureLowThreshold` (default 1%) —
  deliberately the SLOWER-moving signal, so a brief lull in the middle of
  a real overflow event doesn't bounce swappiness back down before the
  event has actually resolved. This asymmetry (fast entry, slow exit) is
  the same shape as the CPU-PSI idle gate's own logic, applied in reverse:
  there, a fast "some" avg10 check must show LOW load before proceeding;
  here, a fast avg10 check triggers on HIGH pressure, but a slower avg60
  check is required to stand down.
- State is tracked in a small file under `/run` (cleared every reboot, so
  a fresh boot always starts at the low baseline, never stuck in relief
  from a previous session).
- Missing PSI (no `CONFIG_PSI`, or `psi=0` on the kernel command line) is
  handled the same way as the recompression script: log and leave
  swappiness at its boot-time baseline rather than fail.

**Why the relief value defaults to 60, specifically:** the plain kernel
default is a reasonable anchor for "how should the box behave under real,
confirmed pressure" — no need to invent a new number for that state when
the exact one being moved away from at rest already describes ordinary,
untuned kernel behavior.

**Why dire tiers (256M/512M/1G) don't get this at all:** they're already
eager by design (120, [3]) — there's no low baseline to relieve *from* in
the first place. A relief valve only makes sense where the resting state
is deliberately reluctant.

**What's still unvalidated, stated plainly:** the specific numbers (10s/
60s pressure windows, 10%/1% thresholds, 30-second check interval, and 60
as the relief value) are Claude's own reasoned starting points, not
measured against a real workload. They're tunable per-box via the
`zram.swappinessRelief.*` options; treat them as a first cut, not a
settled result.

**A real VM test exists now — precise about what it has and hasn't
shown.** Everything above was, until recently, eval-only:
`checks/default.nix` confirms the module *renders* the right systemd
units, but says nothing about whether the PSI-gated hysteresis logic
actually *behaves* as designed under real pressure.
`checks/swappiness-relief-vm-test.nix` closes that gap for the core round
trip — it boots a real, ephemeral NixOS VM (`pkgs.testers.nixosTest`,
nothing persists after the build) and exercises the real systemd timer
against real `/proc/pressure/memory` readings, driven by concurrent
`stress-ng` workers (a single serial allocator was tried first and ruled
out — see below) wrapped in an external safety net and, critically, a
retry loop: roughly a dozen real VM-boot attempts made while building
this test showed the SAME workload configuration genuinely bifurcates
run to run between a gradual climb that clears the entry threshold and an
occasional hard kernel OOM-kill of the workload unit itself (kswapd
invoking the OOM killer directly, too fast for any external monitor to
react to). No percentage tuning found eliminates the hard-OOM outcome
without also eliminating pressure generation entirely — so rather than
chase a single lucky run, the test retries with a fresh workload instance
on either failure mode (up to 5 attempts) and only fails if every attempt
in that budget comes up empty, which would be a genuine signal, not
noise. See the test file's own top-level comment for the full empirical
record this design is based on.

Building this test caught three real, pre-existing bugs nothing else in
the repo had ever exercised at runtime — none specific to the relief
valve alone, but all necessary for it (or any zram tier) to function at
all:

- `services.zram-generator.enable` was never set — upstream's own module
  gates its ENTIRE config (the systemd units,
  `/etc/systemd/zram-generator.conf` itself) behind that flag, so `mode =
  "zram"` silently produced no zram device at all, with no error. Fixed in
  `modules/zram.nix`.
- The PSI-reading shell scripts (recompression, swappiness-relief,
  pressure diagnostics) use `awk` with no explicit systemd-service PATH
  dependency. Fixed via `path = [ pkgs.gawk ];` on all three affected
  services.
- systemd's own default `AccuracySec` (1 minute) silently coalesces any
  timer firing more often than that, defeating a short `checkIntervalSec`
  entirely — including the real 30s default above. Fixed with an explicit
  `AccuracySec = "1s"` on the relief-valve timer.

These are real, previously-invisible bugs that existed since near the
module's inception, caught only by booting a real VM — none of them would
ever have surfaced in an eval-only test.

On the specific behavioral question this note exists to answer — does the
valve actually flip swappiness to 60 under real, sustained pressure, and
back to 10 once it genuinely passes — the mechanism's own code path is now
confirmed correct with exact matching production log lines for BOTH
transitions: entry ("memory pressure rising (some avg10=10.74% >= 10%) --
entering relief, swappiness -> 60") and exit ("memory pressure resolved
(some avg60=0.97% < 1%) -- leaving relief, swappiness -> 10"), reproduced
across multiple real VM boots. What building this test surfaced is a real
structural finding about the WORKLOAD, not the mechanism: at swappiness=10
(this tier group's own resting baseline), the kernel resists reclaiming
anon memory almost entirely until very close to genuine exhaustion, so a
synthetic attempt to generate sustained pressure sits on a narrow, sharp
edge — most runs climb gently over ~25-30 seconds and clear the entry
threshold, but a real minority instead overshoot straight into a hard
kernel OOM-kill of the test workload, too fast for any external monitor to
head off. That bifurcation is now handled explicitly (retry with a fresh
workload rather than pretend a single attempt is reliable — see above),
which is what makes the test's pass/fail outcome trustworthy despite the
underlying workload being inherently flaky. It also carries a real,
production-relevant caution worth stating plainly: a sufficiently ABRUPT
real memory spike could plausibly outrun this mechanism's reaction time
the same way it outran this test's monitor, independent of
`checkIntervalSec` — the relief valve is well-suited to a pressure event
that builds over seconds-to-minutes (the plausible common case: a deploy
spike, a burst of legitimate load), but nothing here proves it can react
to a demand spike fast enough to matter if free memory collapses in a
fraction of a second. This is not a flaw unique to the relief valve —
`systemd-oomd`'s own PSI-based kill decisions ([10]) carry the identical
limitation — but it is a real, undemonstrated edge the specific threshold
numbers above should be read alongside.

**Source:** the direction (low at rest, relief valve for overflow) and the
10 anchor are Julian's own, stated directly. The mechanism's shape reuses
the already-verified PSI file format and awk-parsing approach from the
recompression script ([11]); the specific thresholds are this project's
own unvalidated judgment call. The runtime behavior described above — as
far as it has actually been checked — comes from this project's own VM
test (`checks/swappiness-relief-vm-test.nix`), not from any upstream
precedent or further word from Julian.

## [18] vm.vfs_cache_pressure = 200, dire tiers only (256M/512M/1G)

**Decision:** dire tiers set `vm.vfs_cache_pressure = 200` (kernel default
100); reluctant tiers (2G-128G) leave it untouched.

**Honesty:** own-measured, real production evidence — stronger than a first
pass gave it credit for. Verified live (SSH) against three real fleet boxes
running zram, none of them nixram itself (all three via a separate,
hand-rolled `zram-generator.conf`): a real 128G-class server, e2-micro
(1G), vultr (512M). e2-micro runs `vfs_cache_pressure=200` in
production — a first read of this called it "a stale leftover default,"
which was wrong and got corrected by actually reading the source: it's
"Step 5" of a documented, red-teamed hardening bisection (infra
`modules/nixos/profiles/base.nix`), specifically chosen to evict
inode/dentry caches aggressively once a 1G box's memory genuinely tightens.
The 128G-class server and vultr both sit at the plain kernel default
(100) for this sysctl — no file in their config sets it at all.

**Reasoning:** this is the zswap profile's own `vfs_cache_pressure=80` note
([see the Zswap profile section below]) pointed in the opposite direction,
for the opposite reason — and that contrast is the point, not a
contradiction. Elitebook (desktop, interactive, benefits from warm
directory/file caches for repeated re-reads) wants LOWER pressure; a
memory-desperate 1G server (nothing to spare, no interactive user watching
for stutter) wants HIGHER pressure, evicting non-essential caches
aggressively rather than holding onto them. Scoped to dire tiers only
(256M/512M/1G) because that's exactly where the one real data point sits,
and because dire tiers already share this "shed everything non-essential
willingly" ethos via their own eager swappiness ([3]). Reluctant tiers have
no comparable evidence either direction, so they stay at the untouched
kernel default rather than guess.

**Source:** e2-micro's own real, live, bisection-tested production config
(`modules/nixos/profiles/base.nix`, "Step 5" of a documented hardening
process, 2026-05-26).

## [19] vm.overcommit_memory = 1, reluctant tiers only (2G-128G)

**Decision:** reluctant tiers set `vm.overcommit_memory = 1` ("always
overcommit," kernel default is 0, the heuristic "guess" mode); dire tiers
leave it untouched.

**Honesty:** extrapolated, and deliberately hedged rather than overclaimed.
A first pass at this presented a real 128G-class server's real, live
`overcommit_memory=1` as if it were confirming evidence for a clean
eager/reluctant split, alongside e2-micro and vultr both sitting
at the kernel default (0) — a pattern that looked clean across all three
real boxes checked. It doesn't hold up as CAUSAL evidence under closer
scrutiny: grepping that server's own infra repo top to bottom finds no
file that sets `overcommit_memory` for it at all — it is plausibly just a
k3s/Kubernetes convention (kubelet preflight commonly wants this) riding
along for a reason unrelated to memory-pressure design, not proof anyone
was deliberately reasoning about zram-tier overcommit policy. Neither
e2-micro nor vultr set this sysctl deliberately either (both are
just the plain kernel default). So the real evidence here is much thinner
than the vfs_cache_pressure case above — directionally suggestive, not
confirmed by the fleet sample it happened to be checked against.

**Reasoning, on its own mechanistic merits (independent of how any real box
actually got its current value):** `overcommit_memory=1` disables the
kernel's own allocation-rejection heuristic entirely, relying on reactive
mechanisms (PSI, oomd, the swappiness relief valve, compression) to catch
real fallout instead of rejecting a request upfront. Reluctant tiers already
carry exactly that reactive machinery by design — the PSI-gated swappiness
relief valve ([17]) exists specifically to let the kernel lean on swap
during genuine overflow rather than routine fullness, the same "permissive
now, react later" posture this sysctl extends one step further. Dire tiers
have almost no slack to begin with; a clean, upfront `ENOMEM` from the
kernel's own heuristic check plausibly serves them better than a permissive
stance banking entirely on reactive machinery to catch a much smaller
margin of error. Left untouched (kernel default 0) there, for exactly that
reason — not because of a lack of an opinion, but because the desperate
tiers' whole design already leans the other way.

**Source:** the mechanism argument is this project's own reasoning; the
"reluctant tiers already lean this way" observation draws on the real
128G-class server's real live value, explicitly flagged above as weak, not
confirming, evidence for the specific number.

## Zswap profile

nixram's `mode = "zswap"` path is a distinct profile from the zram path
above: zswap is a compressed *cache* in front of a real disk-backed swap
device, not a swap device itself, so its tuning targets a different set of
trade-offs — laptops and desktops with real disk swap, rather than servers
with none.

### Pool size: max_pool_percent / accept_threshold_percent

**Honesty:** mixed. `accept_threshold_percent` is sourced. `max_pool_percent`
is directed — raised from the kernel's own upstream default.

`zswap.accept_threshold_percent` stays at 90, the stock kernel default: the
hysteresis band the pool must drain back to (as a percentage of
`max_pool_percent`) before it resumes accepting compressed pages once full.
`zswap.max_pool_percent` is **30**, raised from the kernel's own upstream
default of 20. Unlike zram's disksize ([1]), the zswap pool competes
directly with the same RAM that running applications use, not with disk I/O
time — a bigger pool has a real, immediate opportunity cost that the zram
case doesn't share, so this isn't a value nixram would extrapolate past on
its own reasoning. But it isn't nixram's own reasoning here: 30 is the
elitebook's real production figure (raised from an intermediate 25), on the
logic that the pool should be treated as a hot cache that churns freely
under bursty activity rather than a conservative reservation held back from
running applications. Directed — adapted to match the real deployment
rather than left at the untested upstream default.

### Pressure duration: 3s (down from the shared 30s default)

**Honesty:** directed — Julian's own instruction ("for the elitebook at
least adapt to what it has now"), sourced from the elitebook's real
production config.

`mode = "zswap"` shortens `ManagedOOMMemoryPressureDurationSec` to 3s,
system-wide, from the 30s value every other tier and mode shares ([10]).
The 60% limit percentage is unchanged — only the duration was cut, so oomd
reacts to sustained pressure roughly ten times faster on the one real zswap
box this project has, tuned for a bursty compute (LLM-load) workload where
waiting a full 30 seconds to confirm pressure is real costs more than it
protects against. This is the one place nixram's "zram and zswap share the
same PSI threshold" stance ([10]) turned out not to hold up against the
real fleet data point it's supposed to be grounded in: 30s was carried over
by default, never independently checked against elitebook's actual
production config until asked directly. Flagged as possibly workload-specific
rather than a general zswap-laptop fact — the real config ties it to a
heavy-compute use case, not to "zswap" as a category — adapted here rather
than left unverified.

### Shrinker: shrinker_enabled

**Honesty:** reasoned choice — a deliberate deviation from upstream's own
default.

The zswap shrinker (kernel ≥6.8) proactively writes back cold zswap pages to
the real backing disk swap under pressure, rather than waiting for the pool
to fill and block. It ships off by default upstream; nixram turns it on.
This is a reasoned choice, not a sourced recommendation to enable it — the
kernel's own default is off.

### Recompression: not applicable

**Honesty:** sourced, by omission — architectural, not a missing feature.

zram's recompression ([11]) has no zswap equivalent, and can't: each zswap
pool is bound to one compressor for its entire lifetime
(`zswap_pool_create()`); there is no sysfs `recompress`/`idle` mechanism, and
changing `zswap.compressor` at runtime never retroactively recompresses
already-resident entries — they stay under their original algorithm until
read back or written out, and the old pool is only freed once fully
drained (confirmed against `mm/zswap.c` source, not just
`Documentation/admin-guide/mm/zswap.rst`, which is stale on an adjacent
point — see below). When the pool fills, two independent things happen:
the incoming page that doesn't fit is rejected and falls through to the
backing device **uncompressed** (not compressed-worse, skipped entirely),
while a separate background worker (`shrink_worker`) evicts cold existing
entries to drain the pool back under `accept_threshold_percent` — eviction
here means decompress-then-write-plain to the real disk device, since the
backing swap device only understands the standard swap format. `shrinker_enabled`
above is a third, genuinely independent path (ordinary kernel memory
pressure, not pool occupancy) — not a duplicate of either.

One documentation-vs-source mismatch worth knowing: `zswap.rst` still
describes a same-filled-page optimization (storing all-zero pages without
invoking the compressor), but that code was fully removed from the kernel
in 2024, replaced by a shared "zeromap" bitmap mechanism zram and zswap
both now use. The kernel's own doc lags its own code here.

**Source:** `mm/zswap.c` (`zswap_pool_create`, `zswap_check_limits`,
`zswap_store`, `shrink_worker`, `zswap_writeback_entry`,
`zswap_compressor_param_set`); `Documentation/admin-guide/mm/zswap.rst`
(flagged stale re: same-filled pages).

### Zpool: zsmalloc only

**Honesty:** sourced, by omission.

nixram hardcodes `zswap.zpool=zsmalloc` and does not expose a selector.
z3fold and zbud have been removed from current kernels; zsmalloc is the only
zpool implementation zswap has left. Offering a choice here would only offer
dead configuration.

### Swappiness: 25

**Honesty:** directed — Julian's own stated figure, sourced from the
elitebook's real production zswap config ("the only zswap box is
elitebook").

An earlier version of this profile used 120 — a reasoned midpoint between
the plain-disk kernel default (60) and zram's eager tiers' value at the
time (130) — but that was never verified against any real deployment. 25
replaced it: this project's real, sourced fleet data point. The elitebook
runs zswap in production under a mixed LLM+browser workload that needs
anon memory to stay resident rather than get pushed to a disk-backed
cache, and independently converged on 25 for exactly that reason.

**An honest tension, exposed by the [3] revision, not resolved here:** the
original reasoning for 25 argued zswap should be MORE reluctant than
zram's reluctant tiers, since a zswap miss is a real disk read — worse
than anything zram faces. That argument implicitly assumed zram's
reluctant floor was 60; 25 comfortably sits below that. Since [3] dropped
zram's reluctant resting value to 10, 25 is now numerically ABOVE zram's
floor, not below it — the ordering the original reasoning wanted no longer
holds. This isn't being patched by inventing a lower zswap number: 25 is
Julian's own real, measured production value, and the resting comparison
point it was reasoned against (zram's old 60) is simply gone. Whether
zswap "should" reason from zram's NEW resting value, or from its own
relief-valve value (60, coincidentally the same number zram now uses as
its overflow ceiling — see [17]), or continues to stand on its own
real-data-point sourcing regardless of what zram does, is an open
question, not a decided one. 25 is not changed here on the strength of an
argument this project would be making unprompted. See [3], [17].

### Page-cluster: SSD vs HDD

**Honesty:** sourced (Pop!_OS's own distinction).

zram uses page-cluster=0 unconditionally ([4]) because it has no seek cost to
amortize. zswap's backing medium is a real disk, so that logic doesn't
transfer once a page actually misses the cache. nixram follows Pop!_OS's own
distinction here: page-cluster=2 when the backing swap medium is SSD
(`zswap.diskMedium = "ssd"`, the default), and the kernel's own default (3)
left untouched when it's HDD.

### Watermark scale factor: 50

**Honesty:** directed — Julian: "for the elitebook at least adapt to what
it has now." Elitebook's real production config runs 50, halved from an
earlier 100 after a real incident (100 amplified a reclaim feedback loop
under CPU contention).

An earlier version of this profile reused the flat 125 that Pop!_OS itself
validated, reasoning that the zram/server table's RAM-size taper ([5]) is
justified by absorbing sustained pressure bursts on long-running server
workloads — a laptop/desktop's shorter-lived, interactive pressure pattern
doesn't fit that justification, so a flat value made sense. That reasoning
about the SHAPE (flat, not tapered) still holds, but the specific NUMBER was
never actually checked against this project's own real zswap box until
asked directly — 125 was a plausible-sounding substitute, not a measured
one. 50 is what elitebook actually runs. See docs/rationale.md [5] for the
zram-side taper this profile deliberately does NOT use.

### vfs_cache_pressure: 80

**Honesty:** directed — elitebook's real production value (kernel default
is 100, the "fair rate with respect to pagecache/swapcache" point).

Lower means the kernel prefers to retain dentry/inode caches rather than
reclaim them at the same rate as ordinary page cache — elitebook's own
reasoning: keep some directory-structure cache warm for repeated re-reads,
let page cache take the reclaim hit slightly first. Pairs with swappiness
([3]) in the same "which cache gets sacrificed first" family, but is a
narrower, independent knob (dentry/inode reclaim rate specifically, not
anon-vs-file balance).

Zswap-only, no zram-mode equivalent: this is the only real production data
point this project has for this sysctl at all, so it stays scoped to the
one mode with an actual measurement behind it rather than guessed at for a
server workload with nothing comparable to check it against.

**Source:** elitebook's own real, live production config (`vm.vfs_cache_pressure`
in its `99-swappiness.conf`).

### Overcommit memory: 1 ("always overcommit")

**Honesty:** directed — elitebook's real production value (kernel default
is 0, the "guess" heuristic). Verified against kernel source, not just the
prose docs (see below) — worth the extra step, since it changes what this
setting actually means for the project's own design stance.

`vm.overcommit_memory=1` tells the kernel to skip its own
allocation-rejection heuristic entirely and let (almost) every allocation
request succeed, relying on reactive mechanisms — PSI, oomd, the
compression layer, the OOM killer — to handle the fallout if the system
genuinely runs out. This is not just "a milder version of the kernel
default," and it's not an incidental value either: it is directly aligned
with nixram's own central thesis (permissive allocation, reactive
protection after the fact, not upfront rejection) applied to one more
lever, not just zram/zswap sizing.

**Zswap-only, deliberately not extended to zram-mode tiers.** No comparable
real data point exists for a zram-mode server workload, and the tradeoff
genuinely differs by context: a desktop with an interactive user watching
for a stuck app is a very different failure mode than an unattended server,
where letting a request succeed and relying entirely on reactive mechanisms
to catch the fallout later may be worse than a clean, upfront `ENOMEM` from
the kernel's own heuristic check (mode 0, left untouched at every zram
tier). This is a real, open design question for the zram/server side of
this project, not something to silently decide by copying a desktop's
value across every tier.

**A companion finding, worth stating plainly since it directly bears on
whether to extend this further:** elitebook's own live config ALSO sets
`vm.admin_reserve_kbytes` and `vm.user_reserve_kbytes` (both 128 MiB,
raised from kernel defaults of 8 MiB and a dynamic min(3%, 128 MiB) cap
respectively) — but verified directly against the kernel's own
`__vm_enough_memory` accounting function (`mm/util.c`): under
`OVERCOMMIT_ALWAYS` (this setting), the function returns success
unconditionally, before either reserve value is ever read. Both sysctls
are consulted ONLY under `overcommit_memory=2` ("never overcommit") — under
elitebook's own live `overcommit_memory=1`, they are currently real,
harmless, but completely inert configuration. Nixram deliberately does NOT
set either reserve value anywhere, for exactly this reason: this project
has no `overcommit_memory=2` use case, so propagating either would be
cargo-culting a number that does nothing under nixram's own stance. See
`modules/sysctls.nix`'s header comment for the same note where it's
actually load-bearing (i.e. where a reader might otherwise reach for it).

**Source:** elitebook's own real, live production config
(`vm.overcommit_memory` in its `99-overcommit.conf`); the mode-consultation
behavior is verified directly against `mm/util.c`'s `__vm_enough_memory`,
not just `Documentation/admin-guide/sysctl/vm.rst` (whose prose is a little
looser than the code on exactly which mode consults
`admin_reserve_kbytes`).
