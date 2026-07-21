# nixram

A small NixOS flake module that tunes memory-pressure handling — zram or
zswap, systemd-oomd, and the `vm.*` sysctl layer — from a single declared RAM
level, instead of a dozen loosely-related knobs you have to hand-pick and
hope agree with each other.

The thesis in three sentences: zram's `disksize` is only a cheap, virtual
ceiling, and the real physical cost is bounded separately by
`zram-resident-limit`, kept inside a conservative fraction of RAM at every
tier — so disksize can afford to be generous, and compression gets room to
stretch the same physical spend further before hitting a wall. systemd-oomd
is armed on PSI (pressure stall information), not on swap-used percentage,
because stall time is medium-agnostic and a percentage-of-disksize detector
would be reading the wrong number under nixram's own sizing model. Every
value nixram sets is tagged sourced, extrapolated, or kernel default, so
nothing here is presented as more settled than it actually is.

## Quickstart

```nix
{
  inputs.nixram.url = "github:julian-corbet/nixram-corbet-ch";
}
# in your nixosSystem modules:
imports = [ inputs.nixram.nixosModules.nixram ];
services.nixram = {
  enable = true;
  level = "4G";  # find yours: nix run github:julian-corbet/nixram-corbet-ch#detect-level
};
```

There's no default level and no eval-time auto-detection by design — see
[docs/faq.md](docs/faq.md).

## Options

`services.nixram.*`:

- `enable` — turn the module on.
- `level` — one of the fourteen anchor levels (`256M` … `128G`); no default,
  see [docs/faq.md](docs/faq.md).
- `mode` — `"zram"` (default), `"zswap"`, or `"none"`.
- `zram.sizing` — `"virtual"`, `"physical"`, or `"both"` (default; see
  [docs/rationale.md \[1\]](docs/rationale.md#1-zram-disksize-curve)).
- `zram.diskSizeOverride` — escape hatch for the computed `zram-size`
  expression.
- `zram.residentLimitOverride` — escape hatch for the computed
  `zram-resident-limit` expression (`"0"` for unlimited).
- `zram.priorityOverride` — escape hatch for the swap device priority
  (level default: 100).
- `zram.recompressionAlgorithmOverride` — escape hatch for the idle-tier
  recompression algorithm.
- `zram.recompressionTimer.enable` — toggle idle-page recompression (level
  default varies; off at 256M).
- `zram.recompressionTimer.onCalendar` — cadence for the recompression timer
  (default `"daily"`, unvalidated — see `experiments/README.md`).
- `zswap.maxPoolPercent` — zswap pool ceiling as % of RAM (default 20).
- `zswap.acceptThresholdPercent` — hysteresis band to resume accepting pages
  (default 90).
- `zswap.shrinkerEnabled` — proactive writeback of cold zswap pages (default
  true; off upstream).
- `zswap.diskMedium` — `"ssd"` (default) or `"hdd"`, drives `page-cluster`.
- `oomd.enable` — arm systemd-oomd with PSI thresholds (level default; off
  only at 256M).
- `oomd.protectedUnits` — services given `ManagedOOMPreference = "omit"` +
  `OOMScoreAdjust = -900` (default `["sshd.service"]`).
- `sysctls.enable` — escape hatch to disable the whole sysctl layer (default
  true).
- `minFreeKbytesOverride` — escape hatch only; no level sets this by default
  (see [docs/rationale.md \[6\]](docs/rationale.md#6-vmmin_free_kbytes-untouched)).

## Levels

See [docs/levels.md](docs/levels.md) for the full 14-level table with
sourced/extrapolated/kernel-default badges on every value.

## Non-goals

- No eval-time RAM auto-detection (Nix evaluation is pure and static; see
  [docs/faq.md](docs/faq.md)).
- No zram+zswap stacking (double compression, no sourced benefit).
- No `SwapUsedLimit` / `ManagedOOMSwap` anywhere (see
  [docs/faq.md](docs/faq.md)).
- No universal `min_free_kbytes` formula (none exists in any source this
  project reviewed).
- Not a container/cgroup memory manager — this is host-level `vm.*` and
  swap-medium tuning only.

## Status

Fresh project. Values marked extrapolated (◐) are reasoned, not measured;
`experiments/README.md` tracks what still needs measuring, and results feed
back into `levels.nix` as tag upgrades over time.

## Related projects

nixram is one of several small, independently-usable open-source projects
sharing a common design system: **nixarch** (declarative Arch/CachyOS),
**nixvps** (tiny sub-1GB NixOS VPS profiles),
[nixremote](https://github.com/julian-corbet/nixremote-corbet-ch)
(cross-machine native Wayland app forwarding), and
[nixfish](https://github.com/julian-corbet/nixfish-corbet-ch) (the
safe-adoption pattern for declarative fish shell config). nixram's own niche
is purely memory-pressure tuning — usable alongside any of them, or standalone.

## License

MIT.
