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
| Sync only between charts of the SAME symbol | `true` | EURUSD charts sync with EURUSD charts only. Turn off to sync everything. |
| Share between separate MT4 terminals | `false` | Uses the shared `Common` folder so two MT4 installations can sync. |

### Behaviour

| Setting | Default | What it does |
|---|---|---|
| Refresh interval | `400` ms | How often charts check for changes. |
| Deleting an object deletes it on all charts | `true` | Turn off and a delete only affects the chart you did it on. |
| Adopt objects already on the chart at load | `false` | On by default would sweep up whatever is already drawn, including things you may not want shared. |
| Make copied objects non-selectable | `false` | On = copies are view-only and can only be edited on the chart you drew them. |
| Keep delete records for N hours | `24` | How long a deletion is remembered, so a chart that was closed still picks it up when it reopens. |

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
level values, colours and captions come across.

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

Copies are named `OSync_<chart id>@<original name>` so it is always obvious in
the object list (Ctrl+B) which chart an object came from.

Deleting the copy on any chart deletes the original too — a delete is recorded
as a tombstone so charts that were closed at the time still catch up when they
reopen.

---

## If something looks off

* **Nothing syncs at all** — the indicator has to be on *both* charts, and the
  Sync Channel Name must match.
* **Charts on different symbols do not sync** — that is the default. Turn off
  *Sync only between charts of the SAME symbol*.
* **A leftover copy is stuck on a chart** — Ctrl+B, delete anything starting
  with `OSync_`, then reload the indicator.
* **Anything else** — turn on *Write detail to the Experts log*, reproduce it,
  and send me the Experts tab contents.

---

Version 1.01

## Changelog

**1.01** - fixed two compile errors: an object type constant that only exists in MT5 (`OBJ_ARROWED_LINE` - MT4 has no arrowed line tool), and the Gann/Fibo `OBJPROP_SCALE` property being read and written as an integer when MT4 defines it as a double.

**1.00** - first release.
