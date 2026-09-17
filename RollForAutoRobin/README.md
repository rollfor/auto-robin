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
| `/rf autorobin` | Opens this addon's page in RollFor's options window, on the **General** tab |
| `/rf autorobin loot` | Opens the same page on the **Loot** tab, where you tick which items the rotation hands out |
| `/rf autorobin [hearts\|marks\|gems\|trash]` | Opens the same page on that queue's tab: **Hearts/Marks** or **Gems/Trash**. Each tab shows its two queues side by side, each with a search box |
| `/rf autorobin reset` | Clears every queue, asking first if any have players |

## Settings

On the **General** tab of this addon's page in RollFor's options window, and in `/rf config`:

| Setting | Default |
|---|---|
| Auto round robin | on |
| Announce awards | on |
| Announce drops the rotation will hand out | off |
| Remove non-core players from queues on new group | on |

When RollForAutoLoot could hand out the same item, whichever is higher in **Loot priority**
in RollFor's options window gets it. Auto-loot starts on top.

## For WeakAuras and other addons

- The event `ROLLFOR_ROUND_ROBIN_QUEUE_UPDATE`, fired with the category whose queue changed.
- The global `RollForApi.round_robin`, with `categories()`, `is_active( category )` and
  `queue( category, limit )`.
