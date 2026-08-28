//+------------------------------------------------------------------+
//|                                                   ObjectSync.mq4 |
//|              Multi-chart drawing object synchronisation for MT4   |
//|                                                                  |
//|  Draw / drag / edit an object on ONE chart and the same object    |
//|  appears on every other chart running this indicator.             |
//|                                                                  |
//|  SAFE FOR RUNNING EAs - three independent guards:                 |
//|   1. This is an indicator. It never places, modifies or closes    |
//|      any order and never touches a trading function.               |
//|   2. An object is only taken over when you act on it by hand:      |
//|      draw it, drag it, or edit it in the properties dialog. New    |
//|      objects are additionally only accepted if the mouse has been  |
//|      moving on this chart in the last few seconds, so objects an   |
//|      EA draws on a tick are not picked up.                         |
//|   3. Anything matching the ignore prefix list is skipped outright. |
//|                                                                   |
//|  Nothing outside that set is ever created, moved or deleted.       |
//+------------------------------------------------------------------+
#property copyright "Custom Indicator"
#property link      ""
#property version   "1.02"
#property strict
#property indicator_chart_window

//+------------------------------------------------------------------+
//| SYNC SCOPE                                                        |
//+------------------------------------------------------------------+
input string InpChannelName        = "ObjSync";   // Sync Channel Name (must match on all charts)
input bool   InpSameSymbolOnly     = true;        // Keep every symbol separate (leave TRUE)
input bool   InpUseCommonFolder    = false;       // Share between separate MT4 terminals

//+------------------------------------------------------------------+
//| BEHAVIOUR                                                         |
//+------------------------------------------------------------------+
input int    InpTimerMs            = 400;         // Refresh interval (milliseconds)
input bool   InpSyncDeletions      = true;        // Deleting an object deletes it on all charts
input bool   InpAdoptExistingOnLoad= false;       // Adopt objects already on the chart at load
input bool   InpLockMirrors        = false;       // Make copied objects non-selectable (read only)
input int    InpTombstoneHours     = 24;          // Keep delete records for N hours

//+------------------------------------------------------------------+
//| SAFETY                                                            |
//+------------------------------------------------------------------+
input string InpIgnorePrefixes     = "BtnGrid_,NotePanel_,EA_,#,__";  // Never sync names starting with (comma separated)
input int    InpManualWindowMs     = 3000;        // New objects only count as manual within N ms of mouse activity (0 = off)
input bool   InpVerboseLog         = false;       // Write detail to the Experts log

//+------------------------------------------------------------------+
//| INTERNALS                                                         |
//+------------------------------------------------------------------+
#define MIRROR_PREFIX  "OSync_"
#define MAX_LEVELS     32
#define FIELD_SEP      ";"

// One entry per object this indicator manages on THIS chart
struct ManagedObj
{
   string uid;         // channel-wide unique id
   string localName;   // object name on this chart
   string sig;         // last known property signature
   long   rev;         // last known revision
   bool   isMirror;    // true = copy of an object owned by another chart
   string originSym;   // symbol of the chart the object was DRAWN on
};

ManagedObj g_mgd[];
int        g_mgdCount = 0;

string     g_regFile;          // registry file
string     g_lockFile;         // lock file
int        g_fileFlagCommon;   // FILE_COMMON or 0
string     g_ignore[];         // parsed ignore prefixes
int        g_ignoreCount = 0;
long       g_chartId;
bool       g_shuttingDown = false;
bool       g_busy         = false;
int        g_lockHandle   = INVALID_HANDLE;

// Objects deleted on this chart while deletion sync is switched off.
// They stay on the other charts but must not come back on this one.
string     g_suppress[];
int        g_suppressCount = 0;

// Last time the mouse moved over this chart, used to tell a hand-drawn
// object apart from one an EA dropped on the chart during a tick
uint       g_lastMouseMs = 0;

//+------------------------------------------------------------------+
//| Custom indicator initialization function                          |
//+------------------------------------------------------------------+
int OnInit()
{
   g_chartId        = ChartID();
   g_fileFlagCommon = InpUseCommonFolder ? FILE_COMMON : 0;

   // Registry lives per channel, and per symbol when symbol scoping is on.
   // The symbol goes through SafeFile() because some brokers use characters
   // in symbol names that are not legal in a file name.
   string scope = InpSameSymbolOnly ? SafeFile(Symbol()) : "ALL";
   g_regFile    = InpChannelName + "_" + scope + ".csv";
   g_lockFile   = InpChannelName + "_" + scope + ".lck";

   ParseIgnoreList();

   // MT4 does NOT deliver object create/delete notifications unless the
   // chart is asked for them. Without this the indicator would only ever
   // notice an object once you dragged it.
   ChartSetInteger(0, CHART_EVENT_OBJECT_CREATE, true);
   ChartSetInteger(0, CHART_EVENT_OBJECT_DELETE, true);
   ChartSetInteger(0, CHART_EVENT_MOUSE_MOVE,    true);

   ArrayResize(g_mgd, 0);
   g_mgdCount = 0;

   // Optionally take over objects that are already sitting on this chart
   if(InpAdoptExistingOnLoad)
      AdoptExistingObjects();

   // First pass: pull whatever is already in the registry onto this chart
   SyncCycle();

   int ms = InpTimerMs;
   if(ms < 100)  ms = 100;
   if(ms > 5000) ms = 5000;
   EventSetMillisecondTimer(ms);

   Print("ObjectSync: started on ", Symbol(), " ", TimeframeString(),
         "  channel=", InpChannelName, "  registry=", g_regFile,
         "  scope=", (InpSameSymbolOnly ? "THIS SYMBOL ONLY" : "ALL SYMBOLS SHARED"));

   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Custom indicator deinitialization function                        |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   g_shuttingDown = true;
   EventKillTimer();
   ReleaseLock();   // in case we are torn down mid cycle

   // Remove only the copies WE created. Objects you drew on this chart
   // yourself are left untouched, and no delete is propagated.
   for(int i = 0; i < g_mgdCount; i++)
   {
      if(g_mgd[i].isMirror && ObjectFind(0, g_mgd[i].localName) >= 0)
         ObjectDelete(0, g_mgd[i].localName);
   }

   // The chart event flags are deliberately LEFT ENABLED. Switching them
   // back off could silence another indicator on the same chart that also
   // needs them, and having them on costs nothing.

   ChartRedraw(0);
}

//+------------------------------------------------------------------+
//| Custom indicator iteration function                               |
//+------------------------------------------------------------------+
int OnCalculate(const int rates_total,
                const int prev_calculated,
                const datetime &time[],
                const double &open[],
                const double &high[],
                const double &low[],
                const double &close[],
                const long &tick_volume[],
                const long &volume[],
                const int &spread[])
{
   return(rates_total);
}

//+------------------------------------------------------------------+
//| Periodic sync                                                     |
//+------------------------------------------------------------------+
void OnTimer()
{
   SyncCycle();
}

//+------------------------------------------------------------------+
//| Chart events - this is the ONLY place an object is taken over.    |
//|                                                                   |
//| A drag or a properties edit can only come from you. A create      |
//| event can in principle also be raised by another program, so it   |
//| additionally has to pass the recent-mouse-activity check.         |
//+------------------------------------------------------------------+
void OnChartEvent(const int id,
                  const long &lparam,
                  const double &dparam,
                  const string &sparam)
{
   // Track mouse activity - this is what tells a hand-drawn object apart
   // from one an EA created during a tick
   if(id == CHARTEVENT_MOUSE_MOVE)
   {
      g_lastMouseMs = GetTickCount();
      return;
   }

   // A drag or a properties-dialog edit is always a manual action
   if(id == CHARTEVENT_OBJECT_DRAG || id == CHARTEVENT_OBJECT_CHANGE)
   {
      g_lastMouseMs = GetTickCount();

      if(IsEligible(sparam) && FindManagedByLocal(sparam) < 0)
         Adopt(sparam);

      SyncCycle();
      return;
   }

   // A newly created object is only taken over if the mouse has been busy
   // on this chart just now. An EA drawing on a tick will not qualify.
   if(id == CHARTEVENT_OBJECT_CREATE)
   {
      if(!LooksManual())
      {
         if(InpVerboseLog)
            Print("ObjectSync: ignoring ", sparam, " - no mouse activity, not hand drawn");
         return;
      }

      if(IsEligible(sparam) && FindManagedByLocal(sparam) < 0)
         Adopt(sparam);

      SyncCycle();
      return;
   }

   if(id == CHARTEVENT_OBJECT_DELETE)
   {
      // The sync cycle notices the object is gone and handles it
      SyncCycle();
      return;
   }
}

//+------------------------------------------------------------------+
//| MAIN SYNC CYCLE                                                   |
//+------------------------------------------------------------------+
void SyncCycle()
{
   if(g_shuttingDown) return;
   if(g_busy)         return;   // re-entry guard (event fired mid-cycle)
   g_busy = true;

   // ---- 1. what changed on THIS chart since last time ----------------
   //
   // Nothing is committed to the managed list in this pass. If the shared
   // registry turns out to be locked by another chart we simply bail out
   // and the very same differences are picked up again next tick.
   //
   string pendUid[];
   string pendLine[];
   string pendSig[];
   long   pendRev[];
   bool   pendDel[];
   int    pendCount = 0;

   ArrayResize(pendUid,  g_mgdCount + 1);
   ArrayResize(pendLine, g_mgdCount + 1);
   ArrayResize(pendSig,  g_mgdCount + 1);
   ArrayResize(pendRev,  g_mgdCount + 1);
   ArrayResize(pendDel,  g_mgdCount + 1);

   for(int i = 0; i < g_mgdCount; i++)
   {
      string name = g_mgd[i].localName;

      // --- object no longer on the chart ---
      if(ObjectFind(0, name) < 0)
      {
         pendUid[pendCount]  = g_mgd[i].uid;
         pendSig[pendCount]  = "";
         pendRev[pendCount]  = g_mgd[i].rev + 1;
         pendDel[pendCount]  = true;
         pendLine[pendCount] = BuildRegistryLine(g_mgd[i].uid, true, g_mgd[i].rev + 1, "",
                                                g_mgd[i].originSym);
         pendCount++;
         continue;
      }

      // --- object still there, did it move or change? ---
      string sig = BuildSignature(name);
      if(sig == "" || sig == g_mgd[i].sig)
         continue;

      pendUid[pendCount]  = g_mgd[i].uid;
      pendSig[pendCount]  = sig;
      pendRev[pendCount]  = g_mgd[i].rev + 1;
      pendDel[pendCount]  = false;
      pendLine[pendCount] = BuildRegistryLine(g_mgd[i].uid, false, g_mgd[i].rev + 1, sig,
                                              g_mgd[i].originSym);
      pendCount++;
   }

   // ---- 2. merge into the shared registry under a lock ---------------
   string lines[];
   int    lineCount = 0;

   if(!AcquireLock())
   {
      // Another chart is mid-write. Try again on the next tick.
      g_busy = false;
      return;
   }

   lineCount = ReadRegistry(lines);

   bool dirty = false;

   for(int p = 0; p < pendCount; p++)
   {
      // A local delete is only published when deletion sync is enabled
      if(pendDel[p] && !InpSyncDeletions)
         continue;

      int idx = FindLineByUid(lines, lineCount, pendUid[p]);
      if(idx >= 0)
      {
         lines[idx] = pendLine[p];
      }
      else
      {
         ArrayResize(lines, lineCount + 1);
         lines[lineCount] = pendLine[p];
         lineCount++;
      }
      dirty = true;
   }

   if(PruneTombstones(lines, lineCount))
      dirty = true;

   if(dirty)
      WriteRegistry(lines, lineCount);

   ReleaseLock();

   // ---- 2b. the write went through, now commit locally ---------------
   for(int p = 0; p < pendCount; p++)
   {
      int m = FindManagedByUid(pendUid[p]);
      if(m < 0) continue;

      if(pendDel[p])
      {
         if(!InpSyncDeletions)
            AddSuppress(pendUid[p]);   // gone here, left alone elsewhere

         if(InpVerboseLog) Print("ObjectSync: local delete -> ", pendUid[p]);
         RemoveManagedAt(m);
      }
      else
      {
         g_mgd[m].sig = pendSig[p];
         g_mgd[m].rev = pendRev[p];
         if(InpVerboseLog) Print("ObjectSync: local change -> ", pendUid[p]);
      }
   }

   // ---- 3. apply everything from the registry to this chart ----------
   bool touched = ApplyRegistry(lines, lineCount);

   // ---- 4. sweep up copies that no longer belong on this chart -------
   if(PurgeOrphanMirrors())
      touched = true;

   if(touched || dirty)
      ChartRedraw(0);

   g_busy = false;
}

//+------------------------------------------------------------------+
//| Delete copies sitting on this chart that the registry no longer    |
//| accounts for - a copy of another symbol's object left behind by an |
//| earlier version, or a leftover from a chart that has since closed. |
//|                                                                   |
//| Only ever touches objects named with the OSync_ prefix, which are  |
//| created by this indicator and by nothing else.                     |
//+------------------------------------------------------------------+
bool PurgeOrphanMirrors()
{
   bool removed = false;

   int total = ObjectsTotal(0, -1, -1);
   for(int i = total - 1; i >= 0; i--)
   {
      string name = ObjectName(0, i);

      if(StringFind(name, MIRROR_PREFIX) != 0)  continue;   // not one of ours
      if(FindManagedByLocal(name) >= 0)         continue;   // still accounted for

      ObjectDelete(0, name);
      removed = true;

      if(InpVerboseLog)
         Print("ObjectSync: removed stray copy ", name, " - not for ", Symbol());
   }

   return removed;
}

//+------------------------------------------------------------------+
//| Apply registry entries to this chart                              |
//+------------------------------------------------------------------+
bool ApplyRegistry(string &lines[], const int lineCount)
{
   bool touched = false;

   for(int i = 0; i < lineCount; i++)
   {
      string parts[];
      int n = StringSplit(lines[i], (ushort)StringGetCharacter(FIELD_SEP, 0), parts);
      if(n < 6) continue;

      string uid     = parts[0];
      string symbol  = parts[1];
      bool   deleted = (parts[2] == "1");
      long   rev     = StringToInteger(parts[3]);

      // Origin symbol: prefer the one baked into the uid, because that one
      // cannot be rewritten by another chart. Fall back to the symbol column
      // for registry lines written by version 1.01 and earlier.
      string uidSym = SymbolFromUid(uid);
      if(uidSym != "") symbol = uidSym;

      if(InpSameSymbolOnly && symbol != Symbol())
         continue;

      int m = FindManagedByUid(uid);

      // ---------- not currently managed here ----------
      if(m < 0)
      {
         if(deleted)
         {
            DropSuppress(uid);
            continue;
         }

         // Deleted here on purpose while deletion sync was off
         if(IsSuppressed(uid)) continue;

         // Was this object originally drawn on THIS chart? After a reload
         // the original is still on the chart but no longer registered,
         // so re-attach to it instead of making a duplicate copy.
         //
         // The origin comes from the uid, not from the owner field - owner
         // is whoever wrote the line last, which may be a different chart
         // if somebody dragged the copy over there.
         if(OriginChartFromUid(uid) == g_chartId)
         {
            string original = OriginalNameFromUid(uid);
            if(original != "" && ObjectFind(0, original) >= 0)
            {
               // rev 0 so that whatever is in the registry wins on the next
               // pass - the other charts may have moved it while we were off
               AddManaged(uid, original, BuildSignature(original), 0, false, symbol);
               continue;
            }
         }

         // Build a copy of somebody else's object
         string mirror = MirrorNameFor(uid);
         if(ApplyLine(mirror, parts, n, true))
         {
            AddManaged(uid, mirror, BuildSignature(mirror), rev, true, symbol);
            touched = true;
            if(InpVerboseLog) Print("ObjectSync: created copy ", mirror);
         }
         continue;
      }

      // ---------- already managed, newer revision arrived ----------
      if(rev <= g_mgd[m].rev)
         continue;

      if(deleted)
      {
         if(ObjectFind(0, g_mgd[m].localName) >= 0)
            ObjectDelete(0, g_mgd[m].localName);
         if(InpVerboseLog) Print("ObjectSync: remote delete applied ", g_mgd[m].localName);
         RemoveManagedAt(m);
         touched = true;
         continue;
      }

      if(ApplyLine(g_mgd[m].localName, parts, n, g_mgd[m].isMirror))
      {
         g_mgd[m].rev = rev;
         g_mgd[m].sig = BuildSignature(g_mgd[m].localName);
         touched = true;
         if(InpVerboseLog) Print("ObjectSync: remote update applied ", g_mgd[m].localName);
      }
   }

   return touched;
}

//+------------------------------------------------------------------+
//| Create / update a local object from a registry line               |
//+------------------------------------------------------------------+
bool ApplyLine(const string name, string &parts[], const int n, const bool isMirror)
{
   int f = 6;                                   // first property field
   if(n <= f + 1) return false;

   int type   = (int)StringToInteger(parts[f]);   f++;
   int pivots = (int)StringToInteger(parts[f]);   f++;

   if(PivotCount(type) != pivots || pivots <= 0) return false;
   if(n < f + pivots * 2 + 12)                   return false;

   datetime tt[3];
   double   pp[3];
   for(int i = 0; i < pivots; i++)
   {
      tt[i] = (datetime)StringToInteger(parts[f]); f++;
      pp[i] = StringToDouble(parts[f]);            f++;
   }

   // Create it if it isn't there yet (or is there with the wrong type)
   if(ObjectFind(0, name) < 0)
   {
      if(!ObjectCreate(0, name, (ENUM_OBJECT)type, 0, tt[0], pp[0]))
      {
         Print("ObjectSync: could not create ", name, " type=", type,
               " err=", GetLastError());
         return false;
      }
   }
   else if((int)ObjectGetInteger(0, name, OBJPROP_TYPE) != type)
   {
      ObjectDelete(0, name);
      if(!ObjectCreate(0, name, (ENUM_OBJECT)type, 0, tt[0], pp[0]))
         return false;
   }

   for(int i = 0; i < pivots; i++)
      ObjectMove(0, name, i, tt[i], pp[i]);

   int    clr    = (int)StringToInteger(parts[f]); f++;
   int    style  = (int)StringToInteger(parts[f]); f++;
   int    width  = (int)StringToInteger(parts[f]); f++;
   int    ray    = (int)StringToInteger(parts[f]); f++;
   int    fill   = (int)StringToInteger(parts[f]); f++;
   int    back   = (int)StringToInteger(parts[f]); f++;
   int    anchor = (int)StringToInteger(parts[f]); f++;
   double angle  = StringToDouble(parts[f]);       f++;
   double dev    = StringToDouble(parts[f]);       f++;
   double scale  = StringToDouble(parts[f]);       f++;   // Gann/Fibo scale is a DOUBLE property
   int    arrow  = (int)StringToInteger(parts[f]); f++;
   int    fsize  = (int)StringToInteger(parts[f]); f++;
   string font   = (f < n) ? Unescape(parts[f]) : "Arial";  f++;
   string text   = (f < n) ? Unescape(parts[f]) : "";       f++;

   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_STYLE, style);
   ObjectSetInteger(0, name, OBJPROP_WIDTH, width);
   ObjectSetInteger(0, name, OBJPROP_BACK, back != 0);

   // Selection flags are only forced on copies. An object you drew on this
   // chart keeps whatever selection state you gave it - otherwise a remote
   // update could deselect it while you are still working on it.
   if(isMirror)
   {
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE, !InpLockMirrors);
      ObjectSetInteger(0, name, OBJPROP_SELECTED, false);
      ObjectSetInteger(0, name, OBJPROP_HIDDEN, false);
   }

   if(HasRay(type))
      ObjectSetInteger(0, name, OBJPROP_RAY_RIGHT, ray != 0);

   if(CanFill(type))
      ObjectSetInteger(0, name, OBJPROP_FILL, fill != 0);

   if(type == OBJ_TEXT || IsArrowType(type))
      ObjectSetInteger(0, name, OBJPROP_ANCHOR, anchor);

   if(type == OBJ_TEXT || type == OBJ_TRENDBYANGLE)
      ObjectSetDouble(0, name, OBJPROP_ANGLE, angle);

   if(type == OBJ_STDDEVCHANNEL)
      ObjectSetDouble(0, name, OBJPROP_DEVIATION, dev);

   if(HasScale(type))
      ObjectSetDouble(0, name, OBJPROP_SCALE, scale);

   if(IsArrowType(type))
      ObjectSetInteger(0, name, OBJPROP_ARROWCODE, arrow);

   if(type == OBJ_TEXT)
   {
      ObjectSetString(0, name, OBJPROP_FONT, font);
      ObjectSetInteger(0, name, OBJPROP_FONTSIZE, fsize);
   }

   ObjectSetString(0, name, OBJPROP_TEXT, text);

   // ---- levels (fibo family, gann, channels) ----
   if(f < n)
   {
      int nlev = (int)StringToInteger(parts[f]); f++;
      if(nlev < 0)          nlev = 0;
      if(nlev > MAX_LEVELS) nlev = MAX_LEVELS;

      if(nlev > 0 && n >= f + nlev * 5)
      {
         ObjectSetInteger(0, name, OBJPROP_LEVELS, nlev);
         for(int L = 0; L < nlev; L++)
         {
            double lv = StringToDouble(parts[f]);        f++;
            int    lc = (int)StringToInteger(parts[f]);   f++;
            int    ls = (int)StringToInteger(parts[f]);   f++;
            int    lw = (int)StringToInteger(parts[f]);   f++;
            string lt = Unescape(parts[f]);               f++;

            ObjectSetDouble(0, name, OBJPROP_LEVELVALUE, L, lv);
            ObjectSetInteger(0, name, OBJPROP_LEVELCOLOR, L, lc);
            ObjectSetInteger(0, name, OBJPROP_LEVELSTYLE, L, ls);
            ObjectSetInteger(0, name, OBJPROP_LEVELWIDTH, L, lw);
            ObjectSetString(0, name, OBJPROP_LEVELTEXT, L, lt);
         }
      }
   }

   ResetLastError();
   return true;
}

//+------------------------------------------------------------------+
//| Build the property signature of a local object                    |
//| (this doubles as the payload written to the registry)             |
//+------------------------------------------------------------------+
string BuildSignature(const string name)
{
   if(ObjectFind(0, name) < 0) return "";

   int type   = (int)ObjectGetInteger(0, name, OBJPROP_TYPE);
   int pivots = PivotCount(type);
   if(pivots <= 0) return "";

   string s = IntegerToString(type) + FIELD_SEP + IntegerToString(pivots);

   for(int i = 0; i < pivots; i++)
   {
      long   t = ObjectGetInteger(0, name, OBJPROP_TIME, i);
      double p = ObjectGetDouble(0, name, OBJPROP_PRICE, i);
      s += FIELD_SEP + IntegerToString(t) + FIELD_SEP + DoubleToString(p, 8);
   }

   s += FIELD_SEP + IntegerToString(ObjectGetInteger(0, name, OBJPROP_COLOR));
   s += FIELD_SEP + IntegerToString(ObjectGetInteger(0, name, OBJPROP_STYLE));
   s += FIELD_SEP + IntegerToString(ObjectGetInteger(0, name, OBJPROP_WIDTH));
   s += FIELD_SEP + IntegerToString(HasRay(type)  ? ObjectGetInteger(0, name, OBJPROP_RAY_RIGHT) : 0);
   s += FIELD_SEP + IntegerToString(CanFill(type) ? ObjectGetInteger(0, name, OBJPROP_FILL)      : 0);
   s += FIELD_SEP + IntegerToString(ObjectGetInteger(0, name, OBJPROP_BACK));
   s += FIELD_SEP + IntegerToString((type == OBJ_TEXT || IsArrowType(type))
                                    ? ObjectGetInteger(0, name, OBJPROP_ANCHOR) : 0);
   s += FIELD_SEP + DoubleToString((type == OBJ_TEXT || type == OBJ_TRENDBYANGLE)
                                    ? ObjectGetDouble(0, name, OBJPROP_ANGLE) : 0.0, 4);
   s += FIELD_SEP + DoubleToString((type == OBJ_STDDEVCHANNEL)
                                    ? ObjectGetDouble(0, name, OBJPROP_DEVIATION) : 0.0, 4);
   s += FIELD_SEP + DoubleToString(HasScale(type)
                                    ? ObjectGetDouble(0, name, OBJPROP_SCALE) : 0.0, 4);
   s += FIELD_SEP + IntegerToString(IsArrowType(type)
                                    ? ObjectGetInteger(0, name, OBJPROP_ARROWCODE) : 0);
   s += FIELD_SEP + IntegerToString((type == OBJ_TEXT)
                                    ? ObjectGetInteger(0, name, OBJPROP_FONTSIZE) : 0);
   s += FIELD_SEP + Escape((type == OBJ_TEXT) ? ObjectGetString(0, name, OBJPROP_FONT) : "Arial");
   s += FIELD_SEP + Escape(ObjectGetString(0, name, OBJPROP_TEXT));

   int nlev = (int)ObjectGetInteger(0, name, OBJPROP_LEVELS);
   if(nlev < 0)          nlev = 0;
   if(nlev > MAX_LEVELS) nlev = MAX_LEVELS;

   s += FIELD_SEP + IntegerToString(nlev);
   for(int L = 0; L < nlev; L++)
   {
      s += FIELD_SEP + DoubleToString(ObjectGetDouble(0, name, OBJPROP_LEVELVALUE, L), 8);
      s += FIELD_SEP + IntegerToString(ObjectGetInteger(0, name, OBJPROP_LEVELCOLOR, L));
      s += FIELD_SEP + IntegerToString(ObjectGetInteger(0, name, OBJPROP_LEVELSTYLE, L));
      s += FIELD_SEP + IntegerToString(ObjectGetInteger(0, name, OBJPROP_LEVELWIDTH, L));
      s += FIELD_SEP + Escape(ObjectGetString(0, name, OBJPROP_LEVELTEXT, L));
   }

   ResetLastError();
   return s;
}

//+------------------------------------------------------------------+
//| Compose a full registry line                                      |
//+------------------------------------------------------------------+
string BuildRegistryLine(const string uid, const bool deleted,
                         const long rev, const string payload,
                         const string originSym)
{
   // The symbol written here is the symbol of the chart the object was DRAWN
   // on, never Symbol() of whoever happens to be republishing it. A chart
   // holding a copy must not be able to re-label somebody else's object with
   // its own symbol - that is what used to let an object leak across symbols.
   string sym = (originSym == "" ? Symbol() : originSym);

   string line = uid
               + FIELD_SEP + sym
               + FIELD_SEP + (deleted ? "1" : "0")
               + FIELD_SEP + IntegerToString(rev)
               + FIELD_SEP + IntegerToString((long)TimeCurrent())
               + FIELD_SEP + IntegerToString(g_chartId);

   if(deleted)
      line += FIELD_SEP + "0" + FIELD_SEP + "0";   // placeholder type/pivots
   else
      line += FIELD_SEP + payload;

   return line;
}

//+------------------------------------------------------------------+
//| REGISTRY FILE I/O                                                 |
//+------------------------------------------------------------------+
bool AcquireLock()
{
   // Opened without FILE_SHARE_* flags, so only one chart can hold it
   int h = FileOpen(g_lockFile, FILE_WRITE|FILE_BIN|g_fileFlagCommon);
   if(h == INVALID_HANDLE)
      return false;

   FileWriteInteger(h, (int)g_chartId, INT_VALUE);
   g_lockHandle = h;
   return true;
}

void ReleaseLock()
{
   if(g_lockHandle != INVALID_HANDLE)
   {
      FileClose(g_lockHandle);
      g_lockHandle = INVALID_HANDLE;
   }
}

int ReadRegistry(string &lines[])
{
   ArrayResize(lines, 0);
   int count = 0;

   if(!FileIsExist(g_regFile, g_fileFlagCommon))
      return 0;

   int h = FileOpen(g_regFile, FILE_READ|FILE_TXT|FILE_ANSI|
                               FILE_SHARE_READ|FILE_SHARE_WRITE|g_fileFlagCommon);
   if(h == INVALID_HANDLE)
      return 0;

   while(!FileIsEnding(h))
   {
      string line = FileReadString(h);
      StringTrimLeft(line);
      StringTrimRight(line);
      if(StringLen(line) < 6) continue;

      ArrayResize(lines, count + 1);
      lines[count] = line;
      count++;
   }

   FileClose(h);
   return count;
}

void WriteRegistry(string &lines[], const int count)
{
   int h = FileOpen(g_regFile, FILE_WRITE|FILE_TXT|FILE_ANSI|
                               FILE_SHARE_READ|FILE_SHARE_WRITE|g_fileFlagCommon);
   if(h == INVALID_HANDLE)
   {
      Print("ObjectSync: cannot write registry ", g_regFile, " err=", GetLastError());
      return;
   }

   for(int i = 0; i < count; i++)
      FileWriteString(h, lines[i] + "\r\n");

   FileClose(h);
}

//+------------------------------------------------------------------+
//| Drop delete records once they are old enough                      |
//+------------------------------------------------------------------+
bool PruneTombstones(string &lines[], int &count)
{
   if(InpTombstoneHours <= 0) return false;

   long cutoff  = (long)TimeCurrent() - (long)InpTombstoneHours * 3600;
   bool changed = false;

   for(int i = count - 1; i >= 0; i--)
   {
      string parts[];
      int n = StringSplit(lines[i], (ushort)StringGetCharacter(FIELD_SEP, 0), parts);
      if(n < 6) continue;

      if(parts[2] != "1") continue;                       // not a delete record
      if(StringToInteger(parts[4]) > cutoff) continue;     // still fresh

      for(int j = i; j < count - 1; j++)
         lines[j] = lines[j + 1];

      count--;
      ArrayResize(lines, count);
      changed = true;
   }

   return changed;
}

int FindLineByUid(string &lines[], const int count, const string uid)
{
   string head = uid + FIELD_SEP;
   for(int i = 0; i < count; i++)
      if(StringFind(lines[i], head) == 0)
         return i;
   return -1;
}

//+------------------------------------------------------------------+
//| MANAGED LIST HELPERS                                              |
//+------------------------------------------------------------------+
void AddManaged(const string uid, const string localName,
                const string sig, const long rev, const bool isMirror,
                const string originSym)
{
   ArrayResize(g_mgd, g_mgdCount + 1);
   g_mgd[g_mgdCount].uid       = uid;
   g_mgd[g_mgdCount].localName = localName;
   g_mgd[g_mgdCount].sig       = sig;
   g_mgd[g_mgdCount].rev       = rev;
   g_mgd[g_mgdCount].isMirror  = isMirror;
   g_mgd[g_mgdCount].originSym = (originSym == "" ? Symbol() : originSym);
   g_mgdCount++;
}

void RemoveManagedAt(const int idx)
{
   if(idx < 0 || idx >= g_mgdCount) return;

   for(int i = idx; i < g_mgdCount - 1; i++)
   {
      g_mgd[i].uid       = g_mgd[i + 1].uid;
      g_mgd[i].localName = g_mgd[i + 1].localName;
      g_mgd[i].sig       = g_mgd[i + 1].sig;
      g_mgd[i].rev       = g_mgd[i + 1].rev;
      g_mgd[i].isMirror  = g_mgd[i + 1].isMirror;
      g_mgd[i].originSym = g_mgd[i + 1].originSym;
   }

   g_mgdCount--;
   ArrayResize(g_mgd, g_mgdCount);
}

int FindManagedByUid(const string uid)
{
   for(int i = 0; i < g_mgdCount; i++)
      if(g_mgd[i].uid == uid) return i;
   return -1;
}

int FindManagedByLocal(const string name)
{
   for(int i = 0; i < g_mgdCount; i++)
      if(g_mgd[i].localName == name) return i;
   return -1;
}

//+------------------------------------------------------------------+
//| SUPPRESSED LIST (local-only deletions)                            |
//+------------------------------------------------------------------+
bool IsSuppressed(const string uid)
{
   for(int i = 0; i < g_suppressCount; i++)
      if(g_suppress[i] == uid) return true;
   return false;
}

void AddSuppress(const string uid)
{
   if(IsSuppressed(uid)) return;

   ArrayResize(g_suppress, g_suppressCount + 1);
   g_suppress[g_suppressCount] = uid;
   g_suppressCount++;
}

void DropSuppress(const string uid)
{
   for(int i = g_suppressCount - 1; i >= 0; i--)
   {
      if(g_suppress[i] != uid) continue;

      for(int j = i; j < g_suppressCount - 1; j++)
         g_suppress[j] = g_suppress[j + 1];

      g_suppressCount--;
      ArrayResize(g_suppress, g_suppressCount);
   }
}

//+------------------------------------------------------------------+
//| Take ownership of an object the user just drew or moved           |
//+------------------------------------------------------------------+
void Adopt(const string name)
{
   string sig = BuildSignature(name);
   if(sig == "") return;

   // The symbol is baked into the uid so the object carries its own origin
   // symbol wherever it travels, independent of the registry symbol column.
   string uid = Symbol() + "#" + IntegerToString(g_chartId) + "@" + SafeName(name);
   if(FindManagedByUid(uid) >= 0) return;

   // Registered with an EMPTY signature and revision 0 on purpose: that way
   // the next sync cycle sees a difference and publishes the object. Storing
   // the real signature here would make it look already-in-sync and it would
   // never reach the other charts until you moved it.
   AddManaged(uid, name, "", 0, false, Symbol());

   if(InpVerboseLog) Print("ObjectSync: adopted ", name, " as ", uid);
}

//+------------------------------------------------------------------+
//| Optional: adopt everything already on the chart                   |
//+------------------------------------------------------------------+
void AdoptExistingObjects()
{
   int total = ObjectsTotal(0, -1, -1);
   for(int i = total - 1; i >= 0; i--)
   {
      string name = ObjectName(0, i);
      if(IsEligible(name))
         Adopt(name);
   }
}

//+------------------------------------------------------------------+
//| Is this object one we are allowed to sync?                        |
//+------------------------------------------------------------------+
bool IsEligible(const string name)
{
   if(StringLen(name) == 0)                    return false;
   if(StringFind(name, MIRROR_PREFIX) == 0)    return false;   // one of our copies
   if(StringFind(name, FIELD_SEP) >= 0)        return false;   // would break the registry
   if(StringFind(name, "@") >= 0)              return false;   // reserved for the uid
   if(IsIgnored(name))                         return false;
   if(ObjectFind(0, name) < 0)                 return false;

   int type = (int)ObjectGetInteger(0, name, OBJPROP_TYPE);
   return (PivotCount(type) > 0);
}

//+------------------------------------------------------------------+
//| Was there mouse activity on this chart recently?                  |
//| Used to separate a hand-drawn object from an EA-drawn one.        |
//+------------------------------------------------------------------+
bool LooksManual()
{
   if(InpManualWindowMs <= 0) return true;   // check switched off
   if(g_lastMouseMs == 0)     return false;  // mouse has not moved here yet

   return((GetTickCount() - g_lastMouseMs) <= (uint)InpManualWindowMs);
}

bool IsIgnored(const string name)
{
   for(int i = 0; i < g_ignoreCount; i++)
      if(StringLen(g_ignore[i]) > 0 && StringFind(name, g_ignore[i]) == 0)
         return true;
   return false;
}

void ParseIgnoreList()
{
   ArrayResize(g_ignore, 0);
   g_ignoreCount = 0;

   string parts[];
   int n = StringSplit(InpIgnorePrefixes, (ushort)StringGetCharacter(",", 0), parts);

   for(int i = 0; i < n; i++)
   {
      string p = parts[i];
      StringTrimLeft(p);
      StringTrimRight(p);
      if(StringLen(p) == 0) continue;

      ArrayResize(g_ignore, g_ignoreCount + 1);
      g_ignore[g_ignoreCount] = p;
      g_ignoreCount++;
   }
}

//+------------------------------------------------------------------+
//| OBJECT TYPE TABLE                                                 |
//| Returns the number of anchor points, or 0 if the type is not      |
//| syncable (screen-anchored panels, buttons, bitmaps and so on).    |
//+------------------------------------------------------------------+
int PivotCount(const int type)
{
   switch(type)
   {
      // one anchor
      case OBJ_VLINE:              return 1;
      case OBJ_HLINE:              return 1;
      case OBJ_TEXT:               return 1;
      case OBJ_ARROW:              return 1;
      case OBJ_ARROW_THUMB_UP:     return 1;
      case OBJ_ARROW_THUMB_DOWN:   return 1;
      case OBJ_ARROW_UP:           return 1;
      case OBJ_ARROW_DOWN:         return 1;
      case OBJ_ARROW_STOP:         return 1;
      case OBJ_ARROW_CHECK:        return 1;
      case OBJ_ARROW_LEFT_PRICE:   return 1;
      case OBJ_ARROW_RIGHT_PRICE:  return 1;
      case OBJ_ARROW_BUY:          return 1;
      case OBJ_ARROW_SELL:         return 1;

      // two anchors
      case OBJ_TREND:              return 2;
      case OBJ_TRENDBYANGLE:       return 2;
      case OBJ_CYCLES:             return 2;
      case OBJ_RECTANGLE:          return 2;
      case OBJ_STDDEVCHANNEL:      return 2;
      case OBJ_REGRESSION:         return 2;
      case OBJ_GANNLINE:           return 2;
      case OBJ_GANNFAN:            return 2;
      case OBJ_GANNGRID:           return 2;
      case OBJ_FIBO:               return 2;
      case OBJ_FIBOTIMES:          return 2;
      case OBJ_FIBOFAN:            return 2;
      case OBJ_FIBOARC:            return 2;

      // three anchors
      case OBJ_CHANNEL:            return 3;
      case OBJ_TRIANGLE:           return 3;
      case OBJ_ELLIPSE:            return 3;
      case OBJ_PITCHFORK:          return 3;
      case OBJ_FIBOCHANNEL:        return 3;
      case OBJ_EXPANSION:          return 3;
   }
   return 0;
}

bool IsArrowType(const int type)
{
   switch(type)
   {
      case OBJ_ARROW:
      case OBJ_ARROW_THUMB_UP:
      case OBJ_ARROW_THUMB_DOWN:
      case OBJ_ARROW_UP:
      case OBJ_ARROW_DOWN:
      case OBJ_ARROW_STOP:
      case OBJ_ARROW_CHECK:
      case OBJ_ARROW_LEFT_PRICE:
      case OBJ_ARROW_RIGHT_PRICE:
      case OBJ_ARROW_BUY:
      case OBJ_ARROW_SELL:
         return true;
   }
   return false;
}

bool HasRay(const int type)
{
   switch(type)
   {
      case OBJ_TREND:
      case OBJ_TRENDBYANGLE:
      case OBJ_CHANNEL:
      case OBJ_STDDEVCHANNEL:
      case OBJ_REGRESSION:
      case OBJ_GANNLINE:
      case OBJ_FIBO:
      case OBJ_FIBOCHANNEL:
      case OBJ_PITCHFORK:
         return true;
   }
   return false;
}

bool CanFill(const int type)
{
   switch(type)
   {
      case OBJ_RECTANGLE:
      case OBJ_TRIANGLE:
      case OBJ_ELLIPSE:
      case OBJ_CHANNEL:
         return true;
   }
   return false;
}

bool HasScale(const int type)
{
   switch(type)
   {
      case OBJ_GANNLINE:
      case OBJ_GANNFAN:
      case OBJ_GANNGRID:
      case OBJ_FIBOARC:
         return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| STRING HELPERS                                                    |
//+------------------------------------------------------------------+
string Escape(const string s)
{
   string r = s;
   StringReplace(r, "\\", "\\\\");
   StringReplace(r, FIELD_SEP, "\\s");
   StringReplace(r, "\r", "\\r");
   StringReplace(r, "\n", "\\n");
   return r;
}

string Unescape(const string s)
{
   string r = s;
   StringReplace(r, "\\n", "\n");
   StringReplace(r, "\\r", "\r");
   StringReplace(r, "\\s", FIELD_SEP);
   StringReplace(r, "\\\\", "\\");
   return r;
}

//+------------------------------------------------------------------+
//| Name of the local copy for a given uid.                           |
//|                                                                   |
//| MT4 object names are limited to 63 characters, so a long uid is   |
//| folded down to a hash. The result is always the same on every     |
//| chart, which is what matters.                                     |
//+------------------------------------------------------------------+
string MirrorNameFor(const string uid)
{
   string nm = MIRROR_PREFIX + SafeName(uid);
   if(StringLen(nm) <= 60)
      return nm;

   return MIRROR_PREFIX + IntegerToString(SimpleHash(uid)) + "_"
        + StringSubstr(SafeName(OriginalNameFromUid(uid)), 0, 24);
}

// Small stable 31 bit hash (FNV style), same result on every chart
long SimpleHash(const string s)
{
   long h   = (long)2166136261;
   int  len = StringLen(s);

   for(int i = 0; i < len; i++)
   {
      h = h ^ (long)StringGetCharacter(s, i);
      h = (h * 16777619) & 0x7FFFFFFF;
   }

   return h;
}

// Object names cannot contain the field separator, and we keep uids tidy
string SafeName(const string s)
{
   string r = s;
   StringReplace(r, FIELD_SEP, "_");
   StringReplace(r, "\r", "");
   StringReplace(r, "\n", "");
   return r;
}

// uid format is "<chartId>@<original object name>"
string OriginalNameFromUid(const string uid)
{
   int at = StringFind(uid, "@");
   if(at < 0) return "";
   return StringSubstr(uid, at + 1);
}

long OriginChartFromUid(const string uid)
{
   int at = StringFind(uid, "@");
   if(at < 0) return 0;

   string head = StringSubstr(uid, 0, at);   // "<symbol>#<chartId>" or "<chartId>"

   int hash = LastHash(head);
   if(hash >= 0)
      head = StringSubstr(head, hash + 1);

   return StringToInteger(head);
}

//+------------------------------------------------------------------+
//| Origin symbol out of a uid. Empty for pre-1.02 uids.              |
//+------------------------------------------------------------------+
string SymbolFromUid(const string uid)
{
   int at = StringFind(uid, "@");
   if(at < 0) return "";

   string head = StringSubstr(uid, 0, at);

   int hash = LastHash(head);
   if(hash <= 0) return "";                 // old style uid, no symbol in it
   return StringSubstr(head, 0, hash);
}

//+------------------------------------------------------------------+
//| Position of the LAST '#' in a string, -1 if none.                 |
//| Last, not first, because a broker symbol may itself contain one   |
//| (#US30, #AAPL) and the chart id sits after the final separator.   |
//+------------------------------------------------------------------+
int LastHash(const string s)
{
   ushort mark = (ushort)StringGetCharacter("#", 0);

   for(int i = StringLen(s) - 1; i >= 0; i--)
      if((ushort)StringGetCharacter(s, i) == mark)
         return i;

   return -1;
}

//+------------------------------------------------------------------+
//| Strip characters that are not legal in a file name                |
//+------------------------------------------------------------------+
string SafeFile(const string s)
{
   string r = s;
   StringReplace(r, "\\", "_");
   StringReplace(r, "/",  "_");
   StringReplace(r, ":",  "_");
   StringReplace(r, "*",  "_");
   StringReplace(r, "?",  "_");
   StringReplace(r, "\"", "_");
   StringReplace(r, "<",  "_");
   StringReplace(r, ">",  "_");
   StringReplace(r, "|",  "_");
   StringReplace(r, " ",  "_");
   if(r == "") r = "SYM";
   return r;
}

string TimeframeString()
{
   switch(Period())
   {
      case PERIOD_M1:  return "M1";
      case PERIOD_M5:  return "M5";
      case PERIOD_M15: return "M15";
      case PERIOD_M30: return "M30";
      case PERIOD_H1:  return "H1";
      case PERIOD_H4:  return "H4";
      case PERIOD_D1:  return "D1";
      case PERIOD_W1:  return "W1";
      case PERIOD_MN1: return "MN1";
   }
   return "TF" + IntegerToString(Period());
}
//+------------------------------------------------------------------+
