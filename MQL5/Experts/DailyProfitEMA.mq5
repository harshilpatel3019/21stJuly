//+------------------------------------------------------------------+
//|                                               DailyProfitEMA.mq5 |
//|        EMA 21/55 crossover intraday EA with daily profit booking |
//|                                                                  |
//|  - Trades the symbol of the chart it is attached to (H1); a     |
//|    comma-separated list can be set to trade several from one    |
//|    chart instead                                                 |
//|  - Enters when EMA(21) crosses EMA(55), intrabar or on close     |
//|  - No per-trade SL/TP by default: books ALL trades and halts for |
//|    the day once floating profit reaches the daily $ target       |
//|  - Progressive lots: sequences start at the base lot, grow by a  |
//|    step while the trend persists, double on reversal trades      |
//|  - Flattens everything at end of day (intraday bot)              |
//+------------------------------------------------------------------+
#property version     "1.20"
#property description "EMA 21/55 cross entries on H1 (intrabar or closed candle)."
#property description "Progressive lot sizing (grows with the trend, doubles on"
#property description "reversal). No per-trade SL/TP by default; books all trades"
#property description "when floating profit hits the daily $ target, flat at EOD."

#include <Trade/Trade.mqh>

input group "=== Strategy ==="
input string          InpSymbols          = "";                     // Symbols (comma separated; empty = chart symbol)
input ENUM_TIMEFRAMES InpTF               = PERIOD_H1;              // Signal timeframe
input int             InpFastEMA          = 21;                     // Fast EMA period
input int             InpSlowEMA          = 55;                     // Slow EMA period
input bool            InpIntrabar         = true;                   // React to crosses on the forming candle
input bool            InpCloseOnOpposite  = true;                   // Close position on opposite cross

input group "=== Daily profit booking ==="
input double          InpDailyTarget      = 1200.0;                 // Floating profit ($) at which ALL trades are booked
input bool            InpFlattenAtEOD     = true;                   // Close everything at end of day
input int             InpFlattenHour      = 22;                     // End-of-day flatten hour (server time)

input group "=== Lot sizing (progressive) ==="
input double          InpBaseLot          = 0.01;                   // Starting lot of a sequence
input double          InpLotStep          = 0.01;                   // Lot increase for next same-direction trade
input double          InpReverseMult      = 2.0;                    // Lot multiplier on a reversal trade
input double          InpMaxLot           = 2.0;                    // Hard cap per position (safety)
input bool            InpReenterInTrend   = true;                   // Re-enter after TP/SL while trend persists
input bool            InpDailyLotReset    = true;                   // Restart lot sequence each day

input group "=== Optional per-trade exits (0 = disabled) ==="
input int             InpATRPeriod        = 14;                     // ATR period
input double          InpATRMultSL        = 0.0;                    // Stop loss in ATR multiples (0 = no SL)
input double          InpATRMultTP        = 0.0;                    // Take profit in ATR multiples (0 = no TP)
input int             InpMaxTotalPos      = 3;                      // Max open positions across all symbols

input group "=== Session / misc ==="
input bool            InpUseSession       = true;                   // Only open new trades inside session
input int             InpSessionStart     = 7;                      // Session start hour (server time)
input int             InpSessionEnd       = 20;                     // Session end hour (server time)
input long            InpMagic            = 21550708;               // Magic number

CTrade   g_trade;

int      g_count = 0;
string   g_sym[];
int      g_hFast[];
int      g_hSlow[];
int      g_hATR[];
int      g_rel[];        // +1 fast>slow, -1 fast<slow, 0 not initialised yet
datetime g_lastBar[];    // last evaluated bar per symbol (closed-candle mode)
double   g_lastLot[];    // last opened lot per symbol (progression state)
int      g_lastDir[];    // last trade direction per symbol (+1/-1, 0 = none)
datetime g_entryBar[];   // bar of last entry per symbol (re-entry throttle)

datetime g_dayStamp    = 0;      // server midnight of the current trading day
bool     g_bookedToday = false;  // daily target reached: no more trading today
bool     g_restartLock    = false; // positions found at startup: manage only, no new trades

string GVName(const string suffix) { return "DPEA_" + (string)InpMagic + "_" + suffix; }

//+------------------------------------------------------------------+
int OnInit()
{
   string syms = InpSymbols;
   StringTrimLeft(syms);
   StringTrimRight(syms);
   if(syms == "")
      syms = _Symbol;   // blank input: trade the chart's own symbol

   string parts[];
   int n = StringSplit(syms, ',', parts);
   if(n <= 0)
   {
      Print("DailyProfitEMA: no symbols configured");
      return INIT_PARAMETERS_INCORRECT;
   }

   ArrayResize(g_sym, n);
   ArrayResize(g_hFast, n);
   ArrayResize(g_hSlow, n);
   ArrayResize(g_hATR, n);
   ArrayResize(g_rel, n);
   ArrayResize(g_lastBar, n);
   ArrayResize(g_lastLot, n);
   ArrayResize(g_lastDir, n);
   ArrayResize(g_entryBar, n);

   g_count = 0;
   for(int i = 0; i < n; i++)
   {
      string s = parts[i];
      StringTrimLeft(s);
      StringTrimRight(s);
      if(s == "")
         continue;
      if(!SymbolSelect(s, true))
      {
         Print("DailyProfitEMA: symbol not found in Market Watch: ", s);
         return INIT_PARAMETERS_INCORRECT;
      }
      g_sym[g_count]   = s;
      g_hFast[g_count] = iMA(s, InpTF, InpFastEMA, 0, MODE_EMA, PRICE_CLOSE);
      g_hSlow[g_count] = iMA(s, InpTF, InpSlowEMA, 0, MODE_EMA, PRICE_CLOSE);
      g_hATR[g_count]  = iATR(s, InpTF, InpATRPeriod);
      if(g_hFast[g_count] == INVALID_HANDLE ||
         g_hSlow[g_count] == INVALID_HANDLE ||
         g_hATR[g_count]  == INVALID_HANDLE)
      {
         Print("DailyProfitEMA: failed to create indicator handles for ", s);
         return INIT_FAILED;
      }
      g_rel[g_count]      = 0;
      g_lastBar[g_count]  = 0;
      g_lastLot[g_count]  = 0.0;
      g_lastDir[g_count]  = 0;
      g_entryBar[g_count] = 0;
      g_count++;
   }

   if(g_count == 0)
   {
      Print("DailyProfitEMA: symbol list is empty");
      return INIT_PARAMETERS_INCORRECT;
   }

   g_trade.SetExpertMagicNumber(InpMagic);
   g_trade.SetDeviationInPoints(20);

   // After a terminal/EA restart the lot-sequence state is lost, so if
   // trades are still open, only manage them — do not stack new entries
   // on top. The lock clears once all existing positions are closed.
   g_restartLock = (CountOurPositions() > 0);
   if(g_restartLock)
      Print("DailyProfitEMA: existing positions found at startup; new entries locked until they are closed.");

   StartOrRestoreDay();
   EventSetTimer(1);   // evaluate all symbols even when the chart symbol is quiet
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   EventKillTimer();
   for(int i = 0; i < g_count; i++)
   {
      if(g_hFast[i] != INVALID_HANDLE) IndicatorRelease(g_hFast[i]);
      if(g_hSlow[i] != INVALID_HANDLE) IndicatorRelease(g_hSlow[i]);
      if(g_hATR[i]  != INVALID_HANDLE) IndicatorRelease(g_hATR[i]);
   }
}

void OnTick()  { DoWork(); }
void OnTimer() { DoWork(); }

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

   if(InpDailyLotReset)
      for(int i = 0; i < g_count; i++)
      {
         g_lastLot[i] = 0.0;
         g_lastDir[i] = 0;
      }
}

//+------------------------------------------------------------------+
void DoWork()
{
   datetime today = TimeCurrent() - TimeCurrent() % 86400;
   if(today != g_dayStamp)
      StartOrRestoreDay();

   double floatPL = FloatingPL();
   if(!g_bookedToday && floatPL >= InpDailyTarget)
   {
      g_bookedToday = true;
      GlobalVariableSet(GVName("booked"), 1.0);
      PrintFormat("DailyProfitEMA: floating profit target hit (%.2f). Booking all trades, halted until tomorrow.",
                  floatPL);
   }
   if(g_bookedToday && CountOurPositions() > 0)
      CloseAll();   // retried every tick until everything is flat

   bool halted = g_bookedToday;

   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   bool eod = InpFlattenAtEOD && dt.hour >= InpFlattenHour;
   if(eod && CountOurPositions() > 0)
      CloseAll();

   if(g_restartLock && CountOurPositions() == 0)
   {
      g_restartLock = false;
      Print("DailyProfitEMA: startup positions closed; new entries unlocked.");
   }

   bool inSession = !InpUseSession || (dt.hour >= InpSessionStart && dt.hour < InpSessionEnd);
   bool canOpen   = !halted && !eod && inSession && !g_restartLock;

   for(int i = 0; i < g_count; i++)
      ProcessSymbol(i, canOpen);
}

//+------------------------------------------------------------------+
//| Cross detection is a state machine on the fast/slow relation, so |
//| each cross fires exactly once — per tick in intrabar mode, per   |
//| closed candle otherwise. No trade on startup from an already-    |
//| existing relation: the first evaluation only arms the state.     |
//+------------------------------------------------------------------+
void ProcessSymbol(const int i, const bool canOpen)
{
   int shift = InpIntrabar ? 0 : 1;

   if(!InpIntrabar)
   {
      datetime bt = iTime(g_sym[i], InpTF, 0);
      if(bt == g_lastBar[i] || bt == 0)
         return;
      g_lastBar[i] = bt;
   }

   double fast[], slow[];
   ArraySetAsSeries(fast, true);
   ArraySetAsSeries(slow, true);
   if(CopyBuffer(g_hFast[i], 0, shift, 1, fast) < 1 ||
      CopyBuffer(g_hSlow[i], 0, shift, 1, slow) < 1)
      return;

   int rel = fast[0] > slow[0] ? 1 : (fast[0] < slow[0] ? -1 : g_rel[i]);
   int sig = 0;
   if(g_rel[i] != 0 && rel != 0 && rel != g_rel[i])
      sig = rel;                       // +1 = bullish cross, -1 = bearish cross
   g_rel[i] = rel;

   if(sig != 0)
   {
      if(InpCloseOnOpposite)
         CloseSymbolDir(g_sym[i], sig == 1 ? POSITION_TYPE_SELL : POSITION_TYPE_BUY);

      if(!canOpen)
         return;
      if(HasPosition(g_sym[i]))
         return;
      if(CountOurPositions() >= InpMaxTotalPos)
         return;

      OpenTrade(i, sig);   // reversal trade: NextLot doubles the previous lot
      return;
   }

   // No cross this tick. If a previous trade in the trend direction was
   // closed (optional TP/SL, or manually) and the trend still holds,
   // re-enter with a gradually increased lot (one entry per bar max).
   if(!InpReenterInTrend || !canOpen)
      return;
   if(rel == 0 || g_lastDir[i] != rel)
      return;
   if(HasPosition(g_sym[i]))
      return;
   if(CountOurPositions() >= InpMaxTotalPos)
      return;
   datetime bt = iTime(g_sym[i], InpTF, 0);
   if(bt == 0 || bt == g_entryBar[i])
      return;

   OpenTrade(i, rel);      // same-direction trade: NextLot adds the lot step
}

//+------------------------------------------------------------------+
void OpenTrade(const int i, const int dir)
{
   string s = g_sym[i];

   double lots = NextLot(i, dir);
   if(lots <= 0.0)
      return;

   int    digits = (int)SymbolInfoInteger(s, SYMBOL_DIGITS);
   double ask    = SymbolInfoDouble(s, SYMBOL_ASK);
   double bid    = SymbolInfoDouble(s, SYMBOL_BID);
   double price  = (dir == 1) ? ask : bid;

   double sl = 0.0, tp = 0.0;   // 0 = order placed without SL/TP
   if(InpATRMultSL > 0.0 || InpATRMultTP > 0.0)
   {
      double atr[];
      ArraySetAsSeries(atr, true);
      if(CopyBuffer(g_hATR[i], 0, 0, 2, atr) < 2)
         return;
      if(atr[1] <= 0.0)
         return;
      if(InpATRMultSL > 0.0)
         sl = NormalizeDouble((dir == 1) ? price - atr[1] * InpATRMultSL
                                         : price + atr[1] * InpATRMultSL, digits);
      if(InpATRMultTP > 0.0)
         tp = NormalizeDouble((dir == 1) ? price + atr[1] * InpATRMultTP
                                         : price - atr[1] * InpATRMultTP, digits);
   }

   bool ok = (dir == 1)
             ? g_trade.Buy(lots, s, 0.0, sl, tp, "EMA 21x55 up")
             : g_trade.Sell(lots, s, 0.0, sl, tp, "EMA 21x55 down");
   if(ok)
   {
      g_lastLot[i]  = lots;
      g_lastDir[i]  = dir;
      g_entryBar[i] = iTime(s, InpTF, 0);
   }
   else
      PrintFormat("DailyProfitEMA: order failed on %s (%s), retcode=%d",
                  s, dir == 1 ? "buy" : "sell", g_trade.ResultRetcode());
}

//+------------------------------------------------------------------+
//| Progressive lot sequence per symbol:                             |
//|   first trade            -> InpBaseLot                           |
//|   same direction as last -> last lot + InpLotStep                |
//|   reversal               -> last lot x InpReverseMult            |
//| Capped at InpMaxLot and normalised to the broker's volume rules. |
//+------------------------------------------------------------------+
double NextLot(const int i, const int dir)
{
   string s = g_sym[i];
   double lot;
   if(g_lastDir[i] == 0 || g_lastLot[i] <= 0.0)
      lot = InpBaseLot;
   else if(dir == g_lastDir[i])
      lot = g_lastLot[i] + InpLotStep;
   else
      lot = g_lastLot[i] * InpReverseMult;

   if(lot > InpMaxLot)
      lot = InpMaxLot;

   double step = SymbolInfoDouble(s, SYMBOL_VOLUME_STEP);
   double minL = SymbolInfoDouble(s, SYMBOL_VOLUME_MIN);
   double maxL = SymbolInfoDouble(s, SYMBOL_VOLUME_MAX);
   if(step > 0.0)
      lot = MathRound(lot / step) * step;
   if(lot < minL)
      lot = minL;
   if(lot > maxL)
      lot = maxL;
   return NormalizeDouble(lot, 2);
}

//+------------------------------------------------------------------+
//| Combined floating P/L of this EA's open positions                |
//+------------------------------------------------------------------+
double FloatingPL()
{
   double pl = 0.0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong t = PositionGetTicket(i);
      if(t > 0 && PositionGetInteger(POSITION_MAGIC) == InpMagic)
         pl += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
   }
   return pl;
}

//+------------------------------------------------------------------+
int CountOurPositions()
{
   int c = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong t = PositionGetTicket(i);
      if(t > 0 && PositionGetInteger(POSITION_MAGIC) == InpMagic)
         c++;
   }
   return c;
}

bool HasPosition(const string s)
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong t = PositionGetTicket(i);
      if(t > 0 && PositionGetInteger(POSITION_MAGIC) == InpMagic &&
         PositionGetString(POSITION_SYMBOL) == s)
         return true;
   }
   return false;
}

void CloseAll()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong t = PositionGetTicket(i);
      if(t > 0 && PositionGetInteger(POSITION_MAGIC) == InpMagic)
         g_trade.PositionClose(t);
   }
}

void CloseSymbolDir(const string s, const ENUM_POSITION_TYPE type)
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong t = PositionGetTicket(i);
      if(t > 0 && PositionGetInteger(POSITION_MAGIC) == InpMagic &&
         PositionGetString(POSITION_SYMBOL) == s &&
         (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) == type)
         g_trade.PositionClose(t);
   }
}
//+------------------------------------------------------------------+
