# RollFor - Auto Round Robin

Hands selected items out in a fixed rotation instead of rolling for them, for
[RollFor](https://github.com/rollfor/rollfor).

Each category (Gems, Marks, Hearts) has its own queue, and taking from one doesn't move you in
another. The order shown is the order items are handed out.

## Requirements

`RollFor`.

## Commands

| Command | What it does |
|---|---|
| `/rf autorobin` | Which items the rotation hands out |
| `/rf autorobin queue` | The queues |
| `/rf autorobin reset` | Clears every queue, asking first if any have players |

## Settings

On this addon's page in RollFor's options window, and in `/rf config`:

| Setting | Default |
|---|---|
| Auto round robin | on |
| Announce awards | on |
| Announce drops the rotation will hand out | off |

When RollForAutoLoot could hand out the same item, whichever is higher in **Loot priority**
in RollFor's options window gets it. Auto-loot starts on top.

## For WeakAuras and other addons

- The event `ROLLFOR_ROUND_ROBIN_QUEUE_UPDATE`, fired with the category whose queue changed.
- The global `RollForApi.round_robin`, with `categories()`, `is_active( category )` and
  `queue( category, limit )`.
