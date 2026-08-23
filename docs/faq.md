# FAQ

These entries exist because the code comments in `modules/*.nix` and
`levels.nix` point back to them by name. If you're reading a comment that
says "see docs/faq.md", the matching heading is here.

## Why does `level` have no default and no eval-time auto-detection?

Nix evaluation is pure and static: it cannot read a target machine's live
`/proc/meminfo`. A config that silently guessed a RAM level at eval time
would trade a wrong OOM/swap policy for the appearance of convenience —
exactly the kind of footgun nixram's whole level-anchor design exists to
avoid. So `nixram.level` defaults to `null`, and leaving it unset is
a hard evaluation error (an `assertions` entry with a message pointing back
here), not a silent fallback.

Instead, nixram ships a detector as a flake app:

```
nix run <flake>#detect-level
```

Run it *on the target machine*. It reads real `/proc/meminfo`, rounds up to
the nearest anchor, and prints a ready-to-paste
`nixram.level = "...";` line. You paste that into your
configuration and commit it like any other hardware fact.

This is "detect once, paste once" — a manual step you commit, not an
automated pipeline. Be honest with yourself about what that is: it is not
the same guarantee as a tool that materializes and checks in a generated file
automatically as part of a build, and nixram doesn't claim otherwise. It's a
one-time manual step, same as writing down a disk's UUID.

## Why is zram-size larger than upstream's 0.1–0.5 recommendation?

zram-generator's own upstream documentation recommends sizing zram's
disksize to a fraction "in the range 0.1–0.5" of total RAM. nixram exceeds
that range at every tier, by design: two flat fractions, not a taper — 100%
of RAM (`ram`) at 256M/512M/1G, and 75% of RAM (`ram * 75 / 100`) at every
tier from 2G through 128G. Neither fraction ever comes back down inside the
0.1–0.5 band
([rationale.md \[1\]](rationale.md#1-zram-disksize-curve)).

The guidance is conservative and remains a real trade-off. nixram's larger
logical sizes match its worked host policies: full RAM on the dire tiers and
75% on larger hosts. `zram-size` allocates nothing up front, but poorly
compressible pages can eventually consume close to that much real RAM.
systemd-oomd and the kernel's reclaim/OOM paths protect the host under real
pressure. nixram deliberately does not add a second physical cap: Linux's
zram `mem_limit` returns `ENOMEM` from block writes when reached, which turns
into `Write-error on swap-device` rather than graceful reclaim.

## Why aren't `SwapUsedLimit` / `ManagedOOMSwap` configured by default?

Deliberately, at every level. `SwapUsedLimit` and the per-unit
`ManagedOOMSwap=kill` opt-in are both swap-used-over-swap-total percentage
detectors. Under zram, swap-total means logical disksize, while the real RAM
footprint varies with compression ratio and allocator overhead. A percentage
of that logical denominator therefore does not directly describe memory
pressure.

PSI (pressure stall information) has no such blind spot: stall time is
medium-agnostic. It doesn't care whether the swap medium is zram, zswap, or a
disk partition, or how large its nominal capacity is. So on every tier where
systemd-oomd is armed at all, `ManagedOOMMemoryPressure` is what nixram
configures BY DEFAULT. (systemd-oomd itself defaults off at 256M, a separate,
independently-reasoned call about the daemon's own unmeasured RSS cost on the
smallest tier — [rationale.md \[8\]](rationale.md#8-systemd-oomd-disabled-at-256m)
— not a partial adoption of the swap-percentage detectors this entry is
about.)

`SwapUsedLimit` is available as an opt-in escape hatch
(`oomd.swapUsedLimitPercent`) for a host that understands the blind spot above
and wants it anyway as a redundant, defense-in-depth signal alongside PSI —
e.g. migrating an existing incident-tuned config that already relies on it.
`ManagedOOMSwap=kill` (the PER-UNIT equivalent) has no opt-in anywhere; only
the box-wide `SwapUsedLimit` does.

## Why isn't zram+zswap offered as a combination?

Because it would mean double compression for no sourced benefit: a page
would get compressed once into the zswap pool, then compressed again
(effectively) once it lands in zram-backed swap space, or vice versa,
depending on stacking order. Nothing in the sources this project reviewed
recommends running both at once. `nixram.mode` is an enum —
`"zram"`, `"zswap"`, or `"none"` — precisely so this combination can't be
expressed by accident.

## Does nixram's zram device coexist with an existing disk swap device?

Yes — nothing about `mode = "zram"` requires the box to have no other swap.
zram's `swap-priority = 100` ([rationale.md \[12\]](rationale.md#12-swap-priority--100))
is deliberately set above typical disk-swap priorities, so the kernel always
drains zram first when both exist. There is no assertion in nixram that
forbids a disk swap device from being present alongside `mode = "zram"`; it
simply won't be preferred until zram is exhausted.

## When does `mode = "zswap"` actually take effect?

Two things worth knowing before you flip the switch:

1. **It requires a real swap device.** zswap is a compressed cache in front
   of disk-backed swap, not a swap device itself. `nixram.mode =
   "zswap"` asserts that `config.swapDevices` is non-empty; without a real
   backing swap device, `zswap.enabled=1` is inert.
2. **It only takes effect on the next boot.** `zswap.enabled` and its
   siblings are kernel boot parameters (`boot.kernelParams`), off by default
   upstream. Running `nixos-rebuild switch` alone does not retroactively
   enable zswap on an already-running kernel — you need to reboot into the
   new generation. This is a real limitation of going through kernel
   parameters, not a nixram shortcut.

## What happens on a kernel without zram recompression support?

The idle-recompression timer's maintenance script checks for
`/sys/block/zram0/recompress` before doing anything. If it's absent — kernel
older than 6.2, or `CONFIG_ZRAM_MULTI_COMP` not compiled in — the script logs
one line explaining why, and exits cleanly. It is a silent no-op in the sense
that it doesn't fail the timer or the boot; it is not silent in the sense of
leaving no trace, since the log line is there if you go looking.

## In-between RAM sizes round up to the next anchor — is that safe?

Yes. `nix run <flake>#detect-level` rounds a
machine's actual RAM up to the nearest of the fourteen anchors, never down.
That's safe because each level's `diskSizeExpr` is RAM-relative (`ram` or
`ram * 75 / 100`) and zram-generator evaluates it against the real
`/proc/meminfo` at boot, not the anchor's nominal `ramMiB`. A machine with,
say, 20 GiB of RAM that rounds up to the "24G" level gets a 15 GiB logical
zram device, not one sized as if 24 GiB were installed. Physical residency
remains elastic; no level sets a nonzero `mem_limit`.

## Why not the legacy NixOS `zramSwap` module?

NixOS's built-in `zramSwap` module provides fewer controls over algorithms,
recompression, and generator settings. `zram-generator` is the module
nixpkgs itself documents as the intended successor, and it's what nixram wires directly
(`services.zram-generator.settings`). See `studies/README.md` for the fuller
prior-art comparison.

## Is swapping to zram bad?

No — parking cold pages in compressed RAM is the design working as intended,
not a sign of trouble. The instinct to treat "swap is being used" as a red
flag comes from disk-swap intuition, where swapping means slow disk I/O. zram
swap is still RAM; using it is closer to "this data got compressed" than
"this data left memory."

The honest health signals to watch are PSI (stall time — whether processes
are actually blocked waiting on memory) and the OOM-kill rate, not swap-used
percentage. This is the same reasoning behind nixram never configuring
`SwapUsedLimit` (see above) — a swap-used percentage is answering the wrong
question.
