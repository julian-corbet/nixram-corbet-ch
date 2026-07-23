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
value nixram sets is tagged sourced, directed, extrapolated, or kernel
default, so nothing here is presented as more settled than it actually is.

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
- `zram.compressionAlgorithmOverride` — escape hatch for the primary
  (synchronous, write-path) compression algorithm.
- `zram.recompressionTimer.enable` — toggle idle-page recompression (level
  default varies; off at 256M/512M/1G, on from 2G up).
- `zram.recompressionTimer.onCalendar` — cadence for the recompression timer
  (default `"*:0/15"`, checks every 15 minutes and only acts if CPU PSI shows
  genuine idleness; unvalidated cadence — see `experiments/README.md`).
- `zram.swappinessRelief.enable` — arm a PSI-gated relief valve that
  temporarily raises `vm.swappiness` during genuine, sustained memory
  pressure and lowers it back once pressure resolves (level default; on for
  the reluctant tiers 2G–128G, off at 256M/512M/1G which are already eager).
- `zram.swappinessRelief.reliefValue` — swappiness applied while in relief
  (default 60).
- `zram.swappinessRelief.pressureHighThreshold` — memory PSI "some" avg10 %
  at/above which relief engages (default 10).
- `zram.swappinessRelief.pressureLowThreshold` — memory PSI "some" avg60 %
  below which relief disengages (default 1; deliberately the slower signal
  so a brief lull doesn't bounce swappiness back down early).
- `zram.swappinessRelief.checkIntervalSec` — how often the relief timer
  checks memory PSI (default 30).
- `zswap.maxPoolPercent` — zswap pool ceiling as % of RAM (default 30; the
  kernel's own default is 20, raised to match this project's real
  production zswap box).
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

## Non-NixOS hosts (CachyOS / Arch, via system-manager)

`nixosModules.nixram` needs a real NixOS host. For a non-NixOS Linux box
(CachyOS, Arch — anything applying config with
[numtide/system-manager](https://github.com/numtide/system-manager) instead
of a NixOS rebuild), import `systemManagerModules.nixram` instead:

```nix
{
  inputs.nixram.url = "github:julian-corbet/nixram-corbet-ch";
}
# in your system-manager modules:
imports = [ inputs.nixram.systemManagerModules.nixram ];
services.nixram = {
  enable = true;
  level = "24G";
  mode = "zswap"; # the only mode this backend supports besides "none"
};
```

Same `services.nixram.*` option names and level table, rendered onto
system-manager's smaller, real option surface instead of NixOS's:

- `mode = "zram"` is **not supported** here — it needs
  `services.zram-generator`, a NixOS-specific systemd-generator integration
  system-manager doesn't have. Use the NixOS module for a zram target, or
  `mode = "zswap"` / `"none"` here.
- The `vm.*` sysctls (swappiness, watermarks, page-cluster, `vfs_cache_pressure`,
  `overcommit_memory` — the last two directed from elitebook's real
  production config, see [docs/rationale.md](docs/rationale.md#vfs_cache_pressure-80))
  are applied via a plain `/etc/sysctl.d/60-nixram.conf` file plus a
  re-apply bridge unit, since system-manager has no `boot.kernel.sysctl`
  abstraction — same real effect, different mechanism.
- systemd-oomd's PSI slice configuration ports over almost unchanged
  (`systemd.slices` renders through the identical code NixOS itself uses);
  toggling whether the `systemd-oomd` **daemon** runs at all isn't
  manageable here, and is assumed already on via the distro's own defaults.
- **Zswap's kernel-module parameters (`zswap.enabled`, `max_pool_percent`,
  `shrinker_enabled`) are set via the kernel command line, which
  system-manager categorically cannot touch** (it never manages the
  bootloader). This is a one-time, manual step — same "detect once, paste
  once" spirit as `nixram.level` itself — and activation actively verifies
  those values against `/sys/module/zswap/parameters/*` before proceeding,
  failing with the exact cmdline params to add (and a note about the
  CachyOS-specific udev rule that silently disables zswap whenever a zram
  device is present) if they don't match, rather than silently deploying
  sysctls on top of an inactive zswap.

See `system-manager/default.nix` for the full accounting of what ports over
unchanged versus what had to be rendered differently.

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
