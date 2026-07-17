# nixram

nixram is one small NixOS module: declare a RAM level, get coherent
zram/zswap, systemd-oomd, and `vm.*` sysctl tuning derived from it. Instead
of hand-picking a dozen loosely-related knobs and hoping they agree with each
other, you set `services.nixram.level` once and the rest follows from a
single table (`levels.nix`).

## Who it's for

Two distinct audiences, one module:

- **Long-uptime servers and VMs jammed into small RAM** — anywhere from a
  256M cloud instance up through a 128G workstation-class box, running with
  no real disk swap. This is the `mode = "zram"` path (the default): an
  in-RAM compressed swap device, sized and bounded per level, with
  systemd-oomd armed on PSI (pressure stall information) so the box degrades
  before it OOM-kills blindly.
- **Laptops and desktops with real disk swap** — a `mode = "zswap"` profile:
  a compressed cache in front of an existing swap file or partition, tuned
  for interactive, bursty pressure rather than sustained server load.

## The design in five minutes

- **Level anchors, not per-machine guessing.** Fourteen RAM sizes, 256M
  through 128G, each with a complete, coherent set of values. See
  [levels.md](levels.md).
- **Budget the physical, not just the virtual.** zram's `disksize` is a
  cheap, generous virtual ceiling; `zram-resident-limit` is the real
  physical spend, kept inside a conservative fraction of RAM at every tier.
  This is nixram's central thesis — see
  [rationale.md \[1\]](rationale.md#1-zram-disksize-curve) and
  [faq.md](faq.md) for the upstream guidance it deliberately departs from.
- **PSI-only OOM detection.** systemd-oomd is armed on memory-pressure
  stall time, never on swap-used percentage — see
  [faq.md](faq.md#why-arent-swapusedlimit--managedoomswap-configured-anywhere)
  for why the latter is actively misleading under nixram's own sizing model.
- **An honesty taxonomy, not a wall of opinions.** Every value is tagged
  sourced (●), extrapolated (◐), or kernel default (○). Extrapolated values
  are reasoned, not measured, and said so out loud — see
  [rationale.md](rationale.md).
- **An escape hatch on every layer.** Every computed value — disksize,
  resident limit, priority, recompression algorithm, oomd, sysctls,
  min_free_kbytes — has an override option. Nothing here is load-bearing in
  a way you can't turn off.

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

There is no default level and no eval-time auto-detection — see
[faq.md](faq.md#why-does-level-have-no-default-and-no-eval-time-auto-detection)
for why that's a deliberate design choice, not a missing convenience.

## Further reading

- [levels.md](levels.md) — the full 14-level table, every value with its
  honesty badge.
- [rationale.md](rationale.md) — the numbered reasoning and citations behind
  every tunable.
- [faq.md](faq.md) — the questions the code comments point back to.
