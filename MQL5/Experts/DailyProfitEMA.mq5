//+------------------------------------------------------------------+
//|                                               DailyProfitEMA.mq5 |
//|      EMA-band seeded grid EA with basket take-profit (v2)        |
//|                                                                  |
//|  Cycle lifecycle (one symbol per chart instance):                |
//|  1. SEED: on each H1 candle close, if the candle's open OR close |
//|     lies between EMA(21) and EMA(55), and the EA is flat, open   |
//|     1 BUY + 1 SELL at the seed lot (one fresh cycle).            |
//|  2. GRID: every grid step of price movement (default $2.00 of    |
//|     P/L per seed lot, = 20 pips on EURUSD) add a trade in the    |
//|     direction of the move: price up -> BUY, price down -> SELL.  |
//|  3. SIZING: a running lot starts at the seed lot; every time the |
//|     grid direction flips it grows x1.5; same-direction trades    |
//|     reuse the current running lot (0.01 -> 0.015 -> 0.0225 ...). |
//|  4. EXIT: no per-trade SL/TP. When the DAY's total P/L (realized |
//|     today + floating) reaches +$1200, ALL positions close, the   |
//|     profit is booked and trading halts until the next day.      |
//|  5. INTRADAY: everything is flattened at end of day and no new   |
//|     cycle is seeded in the late session; nothing held overnight. |
//|                                                                  |
//|  Cycle state persists in terminal global variables, so a restart |
//|  resumes the running cycle. If positions exist but the saved     |
//|  state is missing, the EA manages exits only (no new trades)     |
//|  until flat.                                                     |
//+------------------------------------------------------------------+
#property version     "2.20"
#property description "Seeds 1 BUY + 1 SELL when an H1 candle closes with its"
#property description "open/close between EMA21 and EMA55. Grid-adds with the"
#property description "move every fixed $ step, running lot x1.5 on each flip."
#property description "Books ALL trades when the day's P/L reaches the daily"
#property description "target, then halts until the next day."

#include <Trade/Trade.mqh>

input group "=== Market / signal ==="
input string          InpSymbolOverride = "";        // Symbol (empty = chart symbol)
input ENUM_TIMEFRAMES InpTF             = PERIOD_H1; // Timeframe
input int             InpFastEMA        = 21;        // Fast EMA period
input int             InpSlowEMA        = 55;        // Slow EMA period

input group "=== Cycle seeding ==="
input double          InpSeedLot        = 0.01;      // Seed lot (1 BUY + 1 SELL)

input group "=== Grid ==="
input double          InpGridUSD        = 2.0;       // Grid step: $ P/L move per seed lot
input double          InpFlipMult       = 1.5;       // Running-lot multiplier on direction flip
input double          InpMaxLot         = 0.0;       // Lot cap (0 = none)

input group "=== Daily profit booking ==="
input double          InpDailyTarget    = 1200.0;    // Day P/L ($, realized+floating): book all & stop

input group "=== Intraday ==="
input bool            InpFlattenAtEOD   = true;      // Close everything at end of day
input int             InpFlattenHour    = 22;        // End-of-day flatten hour (server time)
input int             InpSeedEndHour    = 20;        // No new cycles at/after this hour (server time)

input group "=== Misc ==="
input long            InpMagic          = 21550708;  // Magic number

CTrade   g_trade;
string   g_symbol;
int      g_hFast = INVALID_HANDLE;
int      g_hSlow = INVALID_HANDLE;
datetime g_seedBarChecked = 0;   // last bar evaluated for seeding

// --- cycle state (persisted in global variables across restarts) ---
bool     g_cycleActive = false;
double   g_runningLot  = 0.0;    // unrounded running lot of the sequence
int      g_lastGridDir = 0;      // +1 last grid trade was BUY, -1 SELL, 0 none yet
double   g_lastBand    = 0.0;    // price level of the last grid band
bool     g_manageOnly  = false;  // positions found at startup without saved state

datetime g_dayStamp    = 0;      // server midnight of the current trading day
bool     g_bookedToday = false;  // daily target reached: no more trading today

string GVName(const string suffix)
{
   return "DPEA2_" + (string)InpMagic + "_" + g_symbol + "_" + suffix;
}

//+------------------------------------------------------------------+
int OnInit()
{
   g_symbol = InpSymbolOverride;
   StringTrimLeft(g_symbol);
   StringTrimRight(g_symbol);
   if(g_symbol == "")
      g_symbol = _Symbol;
   if(!SymbolSelect(g_symbol, true))
   {
      Print("DailyProfitEMA: symbol not found in Market Watch: ", g_symbol);
      return INIT_PARAMETERS_INCORRECT;
   }

   g_hFast = iMA(g_symbol, InpTF, InpFastEMA, 0, MODE_EMA, PRICE_CLOSE);
   g_hSlow = iMA(g_symbol, InpTF, InpSlowEMA, 0, MODE_EMA, PRICE_CLOSE);
   if(g_hFast == INVALID_HANDLE || g_hSlow == INVALID_HANDLE)
   {
      Print("DailyProfitEMA: failed to create EMA handles for ", g_symbol);
      return INIT_FAILED;
   }

   g_trade.SetExpertMagicNumber(InpMagic);
   g_trade.SetDeviationInPoints(20);

   if(CountPositions() > 0)
   {
      if(LoadCycle())
         PrintFormat("DailyProfitEMA: resumed cycle on %s (running lot %.4f, last band %.5f)",
                     g_symbol, g_runningLot, g_lastBand);
      else
      {
         g_manageOnly = true;
         Print("DailyProfitEMA: positions found without saved cycle state; managing exits only until flat.");
      }
   }
   else
      EndCycle();

   StartOrRestoreDay();
   EventSetTimer(1);
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   EventKillTimer();
   if(g_hFast != INVALID_HANDLE) IndicatorRelease(g_hFast);
   if(g_hSlow != INVALID_HANDLE) IndicatorRelease(g_hSlow);
   // cycle state intentionally left in global variables for restart
}

void OnTick()  { DoWork(); }
void OnTimer() { DoWork(); }

//+------------------------------------------------------------------+
void DoWork()
{
   datetime today = TimeCurrent() - TimeCurrent() % 86400;
   if(today != g_dayStamp)
      StartOrRestoreDay();

   int positions = CountPositions();

   // Daily profit booking: when the day's total P/L (realized today +
   // floating) reaches the target, book everything and stop until the
   // next day.
   double dayPL = RealizedToday() + FloatingPL();
   if(!g_bookedToday && dayPL >= InpDailyTarget)
   {
      g_bookedToday = true;
      GlobalVariableSet(GVName("booked"), 1.0);
      PrintFormat("DailyProfitEMA: daily target hit (day P/L %.2f). Booking all trades on %s, halted until tomorrow.",
                  dayPL, g_symbol);
   }
   if(g_bookedToday)
   {
      if(positions > 0)
      {
         CloseAll();          // retried every tick until flat
         return;
      }
      if(g_cycleActive)
         EndCycle();
      return;                 // done for the day
   }

   // Intraday: flatten everything at end of day. Note this realises
   // whatever floating P/L the cycle carries at that moment.
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   bool eod = InpFlattenAtEOD && dt.hour >= InpFlattenHour;
   if(eod)
   {
      if(positions > 0)
         CloseAll();
      else if(g_cycleActive)
         EndCycle();
      return;
   }

   // Manage-only mode: positions predate this run and no state exists.
   if(g_manageOnly)
   {
      if(positions > 0)
         return;
      g_manageOnly = false;
      EndCycle();
   }

   if(positions == 0)
   {
      if(g_cycleActive)
         EndCycle();          // closed externally (manually or by broker)
      if(dt.hour < InpSeedEndHour)
         TrySeed();           // no fresh cycles in the late session
      return;
   }

   if(g_cycleActive)
      ProcessGrid();
}

//+------------------------------------------------------------------+
//| Seed a new cycle: evaluated once per closed H1 candle, only when |
//| flat. Condition: the closed candle's open OR close lies between  |
//| EMA(21) and EMA(55).                                             |
//+------------------------------------------------------------------+
void TrySeed()
{
   datetime bt = iTime(g_symbol, InpTF, 0);
   if(bt == 0 || bt == g_seedBarChecked)
      return;
   g_seedBarChecked = bt;

   double emaF[], emaS[];
   ArraySetAsSeries(emaF, true);
   ArraySetAsSeries(emaS, true);
   if(CopyBuffer(g_hFast, 0, 1, 1, emaF) < 1 || CopyBuffer(g_hSlow, 0, 1, 1, emaS) < 1)
      return;

   double o  = iOpen(g_symbol, InpTF, 1);
   double c  = iClose(g_symbol, InpTF, 1);
   double lo = MathMin(emaF[0], emaS[0]);
   double hi = MathMax(emaF[0], emaS[0]);
   bool inBand = (o >= lo && o <= hi) || (c >= lo && c <= hi);
   if(!inBand)
      return;

   double lot = NormLot(InpSeedLot);
   if(lot <= 0.0)
      return;

   bool okBuy  = g_trade.Buy(lot, g_symbol, 0.0, 0.0, 0.0, "seed buy");
   bool okSell = g_trade.Sell(lot, g_symbol, 0.0, 0.0, 0.0, "seed sell");
   if(!okBuy || !okSell)
      PrintFormat("DailyProfitEMA: seed order failed on %s (buy=%d sell=%d retcode=%d)",
                  g_symbol, okBuy, okSell, g_trade.ResultRetcode());
   if(!okBuy && !okSell)
      return;

   g_cycleActive = true;
   g_runningLot  = InpSeedLot;
   g_lastGridDir = 0;
   g_lastBand    = SymbolInfoDouble(g_symbol, SYMBOL_BID);
   SaveCycle();
   PrintFormat("DailyProfitEMA: new cycle seeded on %s at %.5f", g_symbol, g_lastBand);
}

//+------------------------------------------------------------------+
//| Grid: each time price travels one step from the last band, add a |
//| trade in the direction of the move. A gap through several bands  |
//| adds one trade per band.                                         |
//+------------------------------------------------------------------+
void ProcessGrid()
{
   double step = GridStepPrice();
   if(step <= 0.0)
      return;

   for(int guard = 0; guard < 10; guard++)
   {
      double bid = SymbolInfoDouble(g_symbol, SYMBOL_BID);
      if(bid >= g_lastBand + step)
      {
         if(!GridTrade(1, g_lastBand + step))
            return;
      }
      else if(bid <= g_lastBand - step)
      {
         if(!GridTrade(-1, g_lastBand - step))
            return;
      }
      else
         return;
   }
}

bool GridTrade(const int dir, const double band)
{
   if(g_lastGridDir != 0 && dir != g_lastGridDir)
      g_runningLot *= InpFlipMult;          // direction flip: grow the running lot

   double lot = g_runningLot;
   if(InpMaxLot > 0.0 && lot > InpMaxLot)
      lot = InpMaxLot;
   lot = NormLot(lot);
   if(lot <= 0.0)
      return false;

   bool ok = (dir == 1)
             ? g_trade.Buy(lot, g_symbol, 0.0, 0.0, 0.0, "grid buy")
             : g_trade.Sell(lot, g_symbol, 0.0, 0.0, 0.0, "grid sell");
   if(!ok)
   {
      PrintFormat("DailyProfitEMA: grid order failed on %s (%s), retcode=%d",
                  g_symbol, dir == 1 ? "buy" : "sell", g_trade.ResultRetcode());
      return false;
   }

   g_lastGridDir = dir;
   g_lastBand    = band;
   SaveCycle();
   return true;
}

//+------------------------------------------------------------------+
//| Price distance of one grid step: the move that produces          |
//| InpGridUSD of P/L on the seed lot (e.g. $2 on 0.01 EURUSD =      |
//| 20 pips).                                                        |
//+------------------------------------------------------------------+
double GridStepPrice()
{
   double tickVal = SymbolInfoDouble(g_symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSz  = SymbolInfoDouble(g_symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tickVal <= 0.0 || tickSz <= 0.0 || InpSeedLot <= 0.0 || InpGridUSD <= 0.0)
      return 0.0;
   return InpGridUSD * tickSz / (tickVal * InpSeedLot);
}

//+------------------------------------------------------------------+
double NormLot(double lot)
{
   double step = SymbolInfoDouble(g_symbol, SYMBOL_VOLUME_STEP);
   double minL = SymbolInfoDouble(g_symbol, SYMBOL_VOLUME_MIN);
   double maxL = SymbolInfoDouble(g_symbol, SYMBOL_VOLUME_MAX);
   if(step > 0.0)
      lot = MathRound(lot / step) * step;
   if(lot < minL)
      lot = minL;
   if(lot > maxL)
      lot = maxL;
   return NormalizeDouble(lot, 2);
}

//+------------------------------------------------------------------+
//| Cycle state persistence (terminal global variables)              |
//+------------------------------------------------------------------+
void SaveCycle()
{
   GlobalVariableSet(GVName("active"), g_cycleActive ? 1.0 : 0.0);
   GlobalVariableSet(GVName("runlot"), g_runningLot);
   GlobalVariableSet(GVName("dir"),    (double)g_lastGridDir);
   GlobalVariableSet(GVName("band"),   g_lastBand);
}

bool LoadCycle()
{
   if(!GlobalVariableCheck(GVName("active")) || GlobalVariableGet(GVName("active")) <= 0.0)
      return false;
   if(!GlobalVariableCheck(GVName("runlot")) || !GlobalVariableCheck(GVName("band")))
      return false;
   g_runningLot  = GlobalVariableGet(GVName("runlot"));
   g_lastGridDir = (int)GlobalVariableGet(GVName("dir"));
   g_lastBand    = GlobalVariableGet(GVName("band"));
   g_cycleActive = (g_runningLot > 0.0 && g_lastBand > 0.0);
   return g_cycleActive;
}

void EndCycle()
{
   g_cycleActive = false;
   g_runningLot  = 0.0;
   g_lastGridDir = 0;
   g_lastBand    = 0.0;
   GlobalVariableSet(GVName("active"), 0.0);
}

//+------------------------------------------------------------------+
//| Roll the trading day. The booked flag survives EA/terminal       |
//| restarts via a global variable so a restart after booking cannot |
//| restart trading on the same day.                                 |
//+------------------------------------------------------------------+
void StartOrRestoreDay()
{
   datetime today   = TimeCurrent() - TimeCurrent() % 86400;
   bool     sameDay = GlobalVariableCheck(GVName("date")) &&
                      (datetime)(long)GlobalVariableGet(GVName("date")) == today;
   if(sameDay)
   {
      g_bookedToday = GlobalVariableCheck(GVName("booked")) &&
                      GlobalVariableGet(GVName("booked")) > 0.0;
   }
   else
   {
      GlobalVariableSet(GVName("date"), (double)(long)today);
      GlobalVariableSet(GVName("booked"), 0.0);
      g_bookedToday = false;
   }
   g_dayStamp = today;
}

//+------------------------------------------------------------------+
//| Realized P/L of this instance's trades closed since server       |
//| midnight (profit + swap of closing deals, commission of all).    |
//+------------------------------------------------------------------+
double RealizedToday()
{
   if(!HistorySelect(g_dayStamp, TimeCurrent() + 60))
      return 0.0;
   double pl = 0.0;
   for(int i = HistoryDealsTotal() - 1; i >= 0; i--)
   {
      ulong t = HistoryDealGetTicket(i);
      if(t == 0)
         continue;
      if(HistoryDealGetInteger(t, DEAL_MAGIC) != InpMagic)
         continue;
      if(HistoryDealGetString(t, DEAL_SYMBOL) != g_symbol)
         continue;
      pl += HistoryDealGetDouble(t, DEAL_COMMISSION);
      ENUM_DEAL_ENTRY e = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(t, DEAL_ENTRY);
      if(e == DEAL_ENTRY_OUT || e == DEAL_ENTRY_INOUT || e == DEAL_ENTRY_OUT_BY)
         pl += HistoryDealGetDouble(t, DEAL_PROFIT) + HistoryDealGetDouble(t, DEAL_SWAP);
   }
   return pl;
}

//+------------------------------------------------------------------+
//| Position helpers: this instance's trades only (magic + symbol)   |
//+------------------------------------------------------------------+
double FloatingPL()
{
   double pl = 0.0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong t = PositionGetTicket(i);
      if(t > 0 && PositionGetInteger(POSITION_MAGIC) == InpMagic &&
         PositionGetString(POSITION_SYMBOL) == g_symbol)
         pl += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
   }
   return pl;
}

int CountPositions()
{
   int c = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong t = PositionGetTicket(i);
      if(t > 0 && PositionGetInteger(POSITION_MAGIC) == InpMagic &&
         PositionGetString(POSITION_SYMBOL) == g_symbol)
         c++;
   }
   return c;
}

void CloseAll()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong t = PositionGetTicket(i);
      if(t > 0 && PositionGetInteger(POSITION_MAGIC) == InpMagic &&
         PositionGetString(POSITION_SYMBOL) == g_symbol)
         g_trade.PositionClose(t);
   }
}
//+------------------------------------------------------------------+
