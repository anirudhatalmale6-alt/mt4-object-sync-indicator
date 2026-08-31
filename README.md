# ObjectSync — MT4 multi-chart object sync

Draw a trendline (or rectangle, fibo, text, arrow…) on one chart and it appears
on every other chart running this indicator. Move it, recolour it or delete it
anywhere and every copy follows.

Built to sit alongside a running EA without touching it.

---

## Install

1. Copy `ObjectSync.mq4` into `MQL4/Indicators/`
2. In MT4: **File → Open Data Folder → MQL4 → Indicators**, paste it there
3. Back in MT4, right-click **Navigator → Refresh**
4. Press **F7** on the file in MetaEditor to compile (or it compiles on refresh)
5. Drag **ObjectSync** onto every chart you want kept in sync
6. Tick **Allow DLL imports** is NOT needed. Nothing external is used.

That is it. No settings need changing for the normal case.

---

## Will it interfere with my EA?

No, and by design rather than by luck. Three separate guards:

1. **It is an indicator.** It has no `OrderSend`, `OrderModify`, `OrderClose` or
   `OrderDelete` anywhere in it. It cannot open, change or close a trade even
   if it wanted to.
2. **It only ever takes over objects you touch by hand.** An object joins the
   sync when you draw it, drag it, or edit it in the properties dialog. A new
   object additionally has to appear while the mouse is active on that chart,
   so an object an EA drops on the chart during a tick is not picked up.
3. **Ignore list.** Anything whose name starts with an entry in
   `Never sync names starting with` is skipped completely.

Objects outside that set are never created, never moved and never deleted.

If you run an EA that *does* draw on the chart, add its object name prefix to
the ignore list and it is excluded outright.

---

## Settings

### Sync scope

| Setting | Default | What it does |
|---|---|---|
| Sync Channel Name | `ObjSync` | Charts sharing a channel name sync together. Change it to run two independent groups. |
| Keep every symbol separate | `true` | **Leave this on.** EURUSD charts sync with EURUSD charts only, GBPUSD with GBPUSD, and so on — across all timeframes of that symbol. It does *not* restrict syncing between timeframes. Turning it off puts every symbol into one shared pool, so a line drawn on EURUSD will also appear on GBPUSD. |
| Share between separate MT4 terminals | `false` | Uses the shared `Common` folder so two MT4 installations can sync. |

### Behaviour

| Setting | Default | What it does |
|---|---|---|
| Refresh interval | `400` ms | How often charts check for changes. |
| Deleting an object deletes it on all charts | `true` | Turn off and a delete only affects the chart you did it on. |
| Adopt objects already on the chart at load | `false` | On by default would sweep up whatever is already drawn, including things you may not want shared. |
| Make copied objects non-selectable | `false` | On = copies are view-only and can only be edited on the chart you drew them. |
| Keep delete records for N hours | `24` | How long a deletion is remembered, so a chart that was closed still picks it up when it reopens. |

### Appearance

| Setting | Default | What it does |
|---|---|---|
| Keep synced objects behind panels and dashboards | `true` | Puts every synced object in the chart background, so lines and boxes pass *behind* a dashboard or note panel instead of over the top of it. MT4 has no z-order for chart objects — background or foreground is the only control it gives you, and this sets it on every synced object so you never have to do it by hand. |
| Use the per timeframe colours below | `true` | Master switch for the colour and thickness table. Off = objects keep the colour you drew them with. |
| Colour follows | *Timeframe of the chart it is shown on* | **Timeframe of the chart it is shown on** — every object on your H4 chart is the H4 colour, on the D1 chart the D1 colour. The colour tells you which chart you are looking at. **Timeframe it was drawn on** — an object keeps the colour of the timeframe you drew it on, on every chart. The colour tells you which timeframe a level came from. |
| Also recolour Fibo / Gann level lines | `false` | Off by default, so the standard Fibonacci level colours survive. On = the level lines take the timeframe colour too. |
| M1 … MN colour | see below | One colour per timeframe. Set a colour to **None** to leave objects drawn on that timeframe in whatever colour you drew them. |
| M1 … MN thickness | 1–3 | One line thickness per timeframe, in pixels, 1 to 5. Set it to `0` to leave the thickness alone. |

Defaults: M1 grey, M5 silver, M15 aqua, M30 deep sky blue, H1 lime, H4 yellow,
D1 orange, W1 red, MN magenta. Thickness 1 up to H1, 2 for H4 and D1, 3 for W1
and MN.

While this is on, the timeframe colour replaces the colour you drew with, on
the original as well as the copies. Turn it off, or set that timeframe's colour
to None, to pick colours by hand instead.

The colour is a per-chart decision, applied after a change arrives from another
chart. Two charts can therefore show the same object in two different colours
without fighting each other over it — dragging a line on H4 moves it on every
chart without pushing H4's colour anywhere.

### Safety

| Setting | Default | What it does |
|---|---|---|
| Never sync names starting with | `BtnGrid_,NotePanel_,EA_,#,__` | Comma separated prefixes, excluded outright. |
| New objects only count as manual within N ms of mouse activity | `3000` | The EA guard described above. `0` switches the check off. |
| Write detail to the Experts log | `false` | Turn on if something looks wrong and send me the log. |

---

## What syncs

Trendlines, horizontal and vertical lines, rays, rectangles, triangles,
ellipses, channels (equidistant, standard deviation, linear regression),
all the Fibonacci tools, Gann tools, Andrews pitchfork, cycle lines, text and
every arrow type.

Position, colour, style, width, ray settings, fill, text, font and all Fibo
level values, colours and captions come across. Colour and thickness are then
overridden per timeframe if that option is on — see *Appearance* below.

**Not synced:** screen-anchored things — labels, buttons, edit boxes, panels
and bitmaps. Those are pinned to pixels rather than to a price and a time, so
copying them between charts is meaningless. This is also what keeps the button
grid and note panel indicators out of the way.

---

## How it works

Each chart keeps a small text register in `MQL4/Files/ObjSync_<SYMBOL>.csv`
listing every synced object with a revision number. When you change something,
that chart bumps the revision and writes it; the other charts notice a higher
revision and apply it. A lock file makes sure two charts never write at once.

Copies are named `OSync_<symbol>#<chart id>@<original name>` so it is always
obvious in the object list (Ctrl+B) which symbol and which chart an object came
from. The symbol is part of the id itself, so a chart can never re-label
another chart's object with its own symbol.

Any object starting with `OSync_` that the register no longer accounts for is
removed automatically, so stray copies clean themselves up.

Deleting the copy on any chart deletes the original too — a delete is recorded
as a tombstone so charts that were closed at the time still catch up when they
reopen.

---

## If something looks off

* **Nothing syncs at all** — the indicator has to be on *both* charts, and the
  Sync Channel Name must match.
* **An object appears on a chart of a different symbol** — *Keep every symbol
  separate* has been switched off. Turn it back on, on every chart. Any copies
  already sitting on the wrong charts are cleared automatically within a second
  of reloading.
* **I want different symbols to share objects** — turn *Keep every symbol
  separate* off. That is what it is for.
* **A leftover copy is stuck on a chart** — reload the indicator, it is removed
  automatically. Otherwise Ctrl+B and delete anything starting with `OSync_`.
* **Two of every line after a restart** — that was version 1.03 and earlier;
  1.04 fixes the cause. Doubles already created do not clean themselves up:
  remove the indicator from every chart, delete `MQL4/Files/ObjSync_*.csv`,
  delete the spare lines by hand, then put the indicator back.
* **An object is drawn over the top of my dashboard** — turn on *Keep synced
  objects behind panels and dashboards*. Objects only move behind once the
  indicator has seen them, so give it a second, or reload it.
* **An object drawn by hand keeps changing colour** — that is *Colour /
  thickness by the timeframe drawn on*. Turn it off to keep your own colours,
  or set just that timeframe's colour to None.
* **Anything else** — turn on *Write detail to the Experts log*, reproduce it,
  and send me the Experts tab contents.

---

Version 1.04

## Changelog

**1.04** - objects now survive a restart of MT4 or of the computer without doubling up. Ownership of an object used to be re-established through MT4's chart id, but MT4 issues fresh chart ids every time the terminal starts, so after a restart a chart no longer recognised its own objects and built a copy of each one alongside the original, once per restart, leaving the original unsynced. Ownership is now decided by the object name, which the chart keeps across a restart. Also added a choice for what the timeframe colour means: the timeframe of the chart the object is shown on (new default - every object on your H4 chart is the H4 colour), or the timeframe it was drawn on (1.03 behaviour).

**1.03** - two additions. Synced objects can be forced into the chart background so they pass behind a dashboard or panel instead of over the top of it, which is the only control MT4 gives for that and previously had to be set object by object. And each timeframe now has its own colour and line thickness: an object takes the colour of the timeframe it was drawn on, on every chart, so an H1 level looks the same on your D1 chart as it does on H1. The timeframe travels with the object in the register rather than being read off whichever chart is showing it, so all charts agree on the colour. Register lines written by 1.02 are still read - objects from them simply keep the colour they were drawn with.

**1.02** - symbol separation hardened. The origin symbol is now part of the object id itself and travels with the object, so a chart holding a copy can no longer re-stamp it with its own symbol - that was the one path by which an object could spread to another symbol. The symbol filter now trusts the id rather than the register column, symbol names are made file-name safe, and copies the register no longer accounts for are swept off the chart automatically, which clears any strays left by an earlier version. The register file format is unchanged.

**1.01** - fixed two compile errors: an object type constant that only exists in MT5 (`OBJ_ARROWED_LINE` - MT4 has no arrowed line tool), and the Gann/Fibo `OBJPROP_SCALE` property being read and written as an integer when MT4 defines it as a double.

**1.00** - first release.
