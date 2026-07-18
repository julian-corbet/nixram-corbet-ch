# FAQ

These entries exist because the code comments in `modules/*.nix` and
`levels.nix` point back to them by name. If you're reading a comment that
says "see docs/faq.md", the matching heading is here.

## Why does `level` have no default and no eval-time auto-detection?

Nix evaluation is pure and static: it cannot read a target machine's live
`/proc/meminfo`. A config that silently guessed a RAM level at eval time
would trade a wrong OOM/swap policy for the appearance of convenience —
exactly the kind of footgun nixram's whole level-anchor design exists to
avoid. So `services.nixram.level` defaults to `null`, and leaving it unset is
a hard evaluation error (an `assertions` entry with a message pointing back
here), not a silent fallback.

Instead, nixram ships a detector as a flake app:

```
nix run <flake>#detect-level
```

Run it *on the target machine*. It reads real `/proc/meminfo`, rounds up to
the nearest anchor, and prints a ready-to-paste
`services.nixram.level = "...";` line. You paste that into your
configuration and commit it like any other hardware fact.

This is "detect once, paste once" — a manual step you commit, not an
automated pipeline. Be honest with yourself about what that is: it is not
the same guarantee as a tool that materializes and checks in a generated file
automatically as part of a build, and nixram doesn't claim otherwise. It's a
one-time manual step, same as writing down a disk's UUID.

## What's the 0.1–0.5 disksize conflict, and why does nixram ignore it?

zram-generator's own upstream documentation recommends sizing zram's
disksize to a fraction "in the range 0.1–0.5" of total RAM. The small and mid
tiers exceed that range — up to 2x RAM on the smallest ones — while the 10G+
taper and 16 GiB cap bring disksize back inside it (≤25% of RAM by 64G)
([rationale.md \[1\]](rationale.md#1-zram-disksize-curve)).

The short version: that guidance is written for setups where disksize is the
*only* ceiling. nixram's default (`zram.sizing = "both"`) always pairs
disksize with a resident limit (`zram-resident-limit`) that does the actual
physical-safety job, so a generous disksize just gives compression more
virtual room to stretch into before hitting a wall, at no real physical
cost. If you run `zram.sizing = "virtual"` alone, you've stepped outside that
safety net, and the upstream 0.1–0.5 guidance is exactly the caution you
should be re-applying yourself.

## Why aren't `SwapUsedLimit` / `ManagedOOMSwap` configured anywhere?

Deliberately, at every level. `SwapUsedLimit` and the per-unit
`ManagedOOMSwap=kill` opt-in are both swap-used-over-swap-total percentage
detectors. Under nixram's default sizing (`zram.sizing = "both"`), swap-total
means disksize — and disksize is deliberately set beyond the real
physical budget (`zram-resident-limit`), which is the whole point of
[rationale.md \[1\]](rationale.md#1-zram-disksize-curve). A percentage
detector measured against that inflated denominator reads "plenty of
headroom" right up until the resident limit — the actual wall — is hit, at
which point it's already too late for a percentage-of-disksize warning to
have fired early.

PSI (pressure stall information) has no such blind spot: stall time is
medium-agnostic. It doesn't care whether the swap medium is zram, zswap, or a
disk partition, or how large its nominal capacity is. So nixram configures
`ManagedOOMMemoryPressure` and nothing else, on every tier, and never sets
`SwapUsedLimit` or `ManagedOOMSwap=kill` anywhere. This isn't "keep it as a
decorative secondary backstop" — it's not configured at all.

## Why isn't zram+zswap offered as a combination?

Because it would mean double compression for no sourced benefit: a page
would get compressed once into the zswap pool, then compressed again
(effectively) once it lands in zram-backed swap space, or vice versa,
depending on stacking order. Nothing in the sources this project reviewed
recommends running both at once. `services.nixram.mode` is an enum —
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
   of disk-backed swap, not a swap device itself. `services.nixram.mode =
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

Yes, with one honest caveat. `nix run <flake>#detect-level` rounds a
machine's actual RAM up to the nearest of the fourteen anchors, never down.
That's safe because every level's expressions are RAM-*relative* (`ram / 2`,
`ram * 35 / 100`, and so on) — zram-generator evaluates them against the
real `/proc/meminfo` at boot, not against the anchor's nominal `ramMiB`. A
machine with, say, 20 GiB of RAM that rounds up to the "24G" level still gets
disksize and resident-limit expressions computed from its real 20 GiB, not
an imagined 24 GiB.

The one place rounding has a real, honest consequence: rounding *into* the
64G tier drops the resident limit entirely (it's unset from 64G up, see
[rationale.md \[2\]](rationale.md#2-zram-resident-limit-budget-model)). If
you sit just above 32G — say, 33–40 GiB — and specifically want the 35%
resident-limit budget kept rather than dropped, override it explicitly with
`zram.residentLimitOverride` rather than relying on the rounded-up level's
default.

## Why not the legacy NixOS `zramSwap` module?

NixOS's built-in `zramSwap` module only ever controls virtual disksize (via
`memoryPercent` / `memoryMax`) — it has no concept of a physical resident
limit at all, which is the mechanism nixram's whole budget model
([rationale.md \[2\]](rationale.md#2-zram-resident-limit-budget-model))
depends on. `zram-generator` is the module nixpkgs itself documents as the
intended successor, and it's what nixram wires directly
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
