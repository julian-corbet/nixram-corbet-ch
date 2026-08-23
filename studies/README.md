# Prior art

Why build nixram instead of adopting something that already exists. Each
entry below is a real mechanism or profile nixram's design draws on or was
compared against; none of them, on their own, cover the same ground.

## zram-generator (upstream)

The mechanism nixram builds directly on top of — `services.zram-generator`
can wire `zram-size`, `compression-algorithm`, and `swap-priority` for a
single zram device. It also exposes `zram-resident-limit`, but nixram
deliberately does not use that key: Linux turns the corresponding nonzero
`mem_limit` into a hard block-write failure boundary, so nixram refuses it.
Upstream ships sensible generic defaults and documents the
disksize-fraction guidance nixram departs from
([docs/rationale.md \[1\]](../docs/rationale.md#1-zram-disksize-curve)), but
it has no per-RAM-level opinions of its own, and no notion of oomd or
sysctl coherence — it's a mechanism, not a policy.

## Fedora SwapOnZRAM

A one-size default (`min(ram/2, 4096)`, later revised to full-RAM scaling
capped at 8G) shipped as Fedora's own distro-wide zram policy. No RAM-level
tiering and no attempt at oomd/sysctl coherence — a single good default for
one distribution, not a reusable module across RAM sizes.

## Pop!_OS default-settings

The richest sourced tunable set nixram draws on: swappiness 180,
page-cluster 0, watermark_boost_factor 0, watermark_scale_factor 125, a
16 GiB zram disksize ceiling, and the SSD/HDD page-cluster distinction for
zswap. Desktop-focused and validated for that use case, but shipped as a
fixed set of values for one target class of hardware, not as an importable,
level-parameterized module usable across a 256M cloud instance through a
128G server.

## NixOS legacy `zramSwap` module

The built-in NixOS module (`memoryPercent` / `memoryMax`). It controls the
logical disksize only, which is also nixram's safe capacity primitive, but
does not provide nixram's RAM-level compression, oomd, and sysctl policy.
nixpkgs itself documents zram-generator as the intended successor.

## tuned (RHEL)

RHEL's `tuned` ships named profiles tuned for throughput or latency goals
(e.g. `throughput-performance`, `latency-performance`), but those profiles
aren't organized around RAM size or zram/zswap capacity at all — they're a
different axis (workload shape) entirely.

## srvos / nixos-hardware

Community NixOS module collections for server defaults and hardware-quirk
workarounds respectively. Neither has a memory-pressure or swap-tuning story
at all; they solve adjacent problems (server baseline config, hardware
enablement) that don't overlap with what nixram does.

## earlyoom / nohang

Userspace OOM killers that watch available memory/swap and kill processes
before the kernel's own OOM killer would. These overlap only with nixram's
`oomd` layer (a different implementation of roughly the same idea,
systemd-oomd instead), and neither one has any opinion about zram sizing,
zswap, or the sysctl layer — no coherence across the whole memory-pressure
stack.

## Verdict

None of the above is a coherent, importable, per-RAM-level combination of
zram/zswap sizing + systemd-oomd + sysctl tuning. Each piece exists
somewhere — a mechanism here, a validated constant there, a policy for one
specific hardware class elsewhere — but assembling them into one small,
level-anchored NixOS module, with an explicit accounting of what's sourced
versus extrapolated, didn't exist. Hence nixram.
