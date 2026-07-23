# 001 — systemd-oomd idle RSS on a 256M box

**Question:** is disabling `oomd.enable` at the 256M level actually the right
trade? `rationale.md [8]` called this "extrapolated, DELIBERATE -- a reasoned
tradeoff, not a measured number... oomd's idle RSS on a 256M box is
UNMEASURED."

**Method:** a real, ephemeral NixOS VM (`pkgs.testers.nixosTest`, nothing
persists after the build) booted at nixram's "256M" level with `oomd.enable`
force-overridden to `true` (the tier's own default is `false` -- this
measures the cost being traded away). 256 MiB VM RAM, 1 vCPU, 30s idle settle
window after reaching `multi-user.target`, then `systemd-oomd`'s real
`VmRSS` read directly from `/proc/<pid>/status`. See `vm-measure.nix`.

## Result

```
systemd-oomd VmRSS = 4884 kB (4.77 MiB) on a 256 MiB box = 1.863% of total RAM
system idle MemTotal=214272kB MemAvailable=104012kB (used=110260kB, 51.5% of total)
```

## Reading it

**The daemon's own footprint is real, not negligible, but also not huge in
absolute terms.** 4.77 MiB is about 6.2% of this tier's own resident-limit
safety budget (`residentLimitExpr = ram * 30 / 100` ≈ 76.8 MiB), and 1.86% of
total system RAM. Whether that counts as "worth it" is still a judgment call
-- but it's now a judgment call against a real number, not a guess.

**The more striking number is the baseline itself: this box is already at
51.5% idle memory usage before `oomd` is even added.** A 256 MiB box spends
over half its RAM on baseline OS/systemd overhead doing essentially nothing --
the tier this project already calls "as CPU-constrained as it is
memory-constrained" is exactly as memory-starved as that framing assumes.
Layering oomd's own 4.77 MiB on top of that pushes idle usage to roughly
53.7% before a single real workload byte is allocated.

**What this means for the design:** the measurement supports the existing
default (`oomd.enable = false` at 256M), but for a sharper reason than before
-- not "the cost is probably too high" but "on a box where more than half of
RAM is already baseline overhead at idle, an additional ~2% permanent tax for
a protective daemon whose entire job is to intervene when memory gets tight
is a real, non-trivial subtraction from the very headroom it exists to
protect." The 256M tier's other levers (aggressive swappiness, no
recompression pass, a wide watermark_scale_factor) already lean toward
"survive by any means available" rather than "run a supervisory daemon" -- this
result is consistent with that same posture, not a contradiction of it.

**Status:** closed. `levels.nix`'s 256M `oomd.enable = false` note upgrades
from "extrapolated, DELIBERATE, unmeasured" to "extrapolated, DELIBERATE,
own-measured" -- the reasoning was always a real tradeoff argument, and it now
has a real number behind both sides of that tradeoff (4.77 MiB cost vs. a box
already 51.5% consumed at idle).
