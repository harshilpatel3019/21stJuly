//+------------------------------------------------------------------+
//|                                               DailyProfitEMA.mq5 |
//|        EMA 21/55 crossover intraday EA with daily profit booking |
//|                                                                  |
//|  - Trades EURUSD, GBPUSD, GBPJPY from a single chart (H1)        |
//|  - Enters when EMA(21) crosses EMA(55), intrabar or on close     |
//|  - Books profit and halts for the day once the daily $ target    |
//|    is reached; also halts on a daily max loss                    |
//|  - Flattens everything at end of day (intraday bot)              |
//+------------------------------------------------------------------+
#property version     "1.00"
#property description "EMA 21/55 cross entries on H1 (intrabar or closed candle)."
#property description "Books profit at a daily $ target, stops at a daily max loss,"
#property description "and goes flat at end of day."

#include <Trade/Trade.mqh>

input group "=== Strategy ==="
input string          InpSymbols          = "EURUSD,GBPUSD,GBPJPY"; // Symbols (comma separated)
input ENUM_TIMEFRAMES InpTF               = PERIOD_H1;              // Signal timeframe
input int             InpFastEMA          = 21;                     // Fast EMA period
input int             InpSlowEMA          = 55;                     // Slow EMA period
input bool            InpIntrabar         = true;                   // React to crosses on the forming candle
input bool            InpCloseOnOpposite  = true;                   // Close position on opposite cross

input group "=== Daily profit booking ==="
input double          InpDailyTarget      = 1200.0;                 // Daily profit target ($): book & stop
input double          InpDailyMaxLoss     = 600.0;                  // Daily max loss ($): stop for the day
input bool            InpFlattenAtEOD     = true;                   // Close everything at end of day
input int             InpFlattenHour      = 22;                     // End-of-day flatten hour (server time)

input group "=== Risk ==="
input double          InpRiskPercent      = 0.5;                    // Risk per trade (% of equity)
input int             InpATRPeriod        = 14;                     // ATR period (stop-loss sizing)
input double          InpATRMultSL        = 1.5;                    // Stop loss = ATR x this
input double          InpRewardRisk       = 2.0;                    // Take profit = SL distance x this
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

double   g_dayStartEquity = 0.0;
datetime g_dayStamp       = 0;   // server midnight of the current trading day
bool     g_bookedToday    = false;

string GVName(const string suffix) { return "DPEA_" + (string)InpMagic + "_" + suffix; }

//+------------------------------------------------------------------+
int OnInit()
{
   string parts[];
   int n = StringSplit(InpSymbols, ',', parts);
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
      g_rel[g_count]     = 0;
      g_lastBar[g_count] = 0;
      g_count++;
   }

   if(g_count == 0)
   {
      Print("DailyProfitEMA: symbol list is empty");
      return INIT_PARAMETERS_INCORRECT;
   }

   g_trade.SetExpertMagicNumber(InpMagic);
   g_trade.SetDeviationInPoints(20);

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
//| Snapshot day-start equity; survives EA/terminal restarts via     |
//| global variables so the daily target is measured from the real   |
//| start of the day, not from the moment of the restart.            |
//+------------------------------------------------------------------+
void StartOrRestoreDay()
{
   datetime today = TimeCurrent() - TimeCurrent() % 86400;
   if(GlobalVariableCheck(GVName("date")) &&
      (datetime)(long)GlobalVariableGet(GVName("date")) == today &&
      GlobalVariableCheck(GVName("equity")))
   {
      g_dayStartEquity = GlobalVariableGet(GVName("equity"));
   }
   else
   {
      g_dayStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
      GlobalVariableSet(GVName("date"), (double)(long)today);
      GlobalVariableSet(GVName("equity"), g_dayStartEquity);
   }
   g_dayStamp    = today;
   g_bookedToday = false;
}

//+------------------------------------------------------------------+
void DoWork()
{
   datetime today = TimeCurrent() - TimeCurrent() % 86400;
   if(today != g_dayStamp)
      StartOrRestoreDay();

   double dayPL  = AccountInfoDouble(ACCOUNT_EQUITY) - g_dayStartEquity;
   bool   halted = (dayPL >= InpDailyTarget) || (dayPL <= -InpDailyMaxLoss);

   if(halted && CountOurPositions() > 0)
   {
      CloseAll();
      if(!g_bookedToday)
      {
         g_bookedToday = true;
         PrintFormat("DailyProfitEMA: daily %s hit (%.2f). All positions closed, trading halted until tomorrow.",
                     dayPL >= InpDailyTarget ? "profit target" : "max loss", dayPL);
      }
   }

   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   bool eod = InpFlattenAtEOD && dt.hour >= InpFlattenHour;
   if(eod && CountOurPositions() > 0)
      CloseAll();

   bool inSession = !InpUseSession || (dt.hour >= InpSessionStart && dt.hour < InpSessionEnd);
   bool canOpen   = !halted && !eod && inSession;

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

   if(sig == 0)
      return;

   if(InpCloseOnOpposite)
      CloseSymbolDir(g_sym[i], sig == 1 ? POSITION_TYPE_SELL : POSITION_TYPE_BUY);

   if(!canOpen)
      return;
   if(HasPosition(g_sym[i]))
      return;
   if(CountOurPositions() >= InpMaxTotalPos)
      return;

   OpenTrade(i, sig);
}

//+------------------------------------------------------------------+
void OpenTrade(const int i, const int dir)
{
   string s = g_sym[i];

   double atr[];
   ArraySetAsSeries(atr, true);
   if(CopyBuffer(g_hATR[i], 0, 0, 2, atr) < 2)
      return;
   double slDist = atr[1] * InpATRMultSL;   // ATR of the last closed bar
   if(slDist <= 0.0)
      return;

   double lots = CalcLots(s, slDist);
   if(lots <= 0.0)
      return;

   int    digits = (int)SymbolInfoInteger(s, SYMBOL_DIGITS);
   double ask    = SymbolInfoDouble(s, SYMBOL_ASK);
   double bid    = SymbolInfoDouble(s, SYMBOL_BID);
   double price  = (dir == 1) ? ask : bid;
   double sl     = (dir == 1) ? price - slDist : price + slDist;
   double tp     = (dir == 1) ? price + slDist * InpRewardRisk
                              : price - slDist * InpRewardRisk;
   sl = NormalizeDouble(sl, digits);
   tp = NormalizeDouble(tp, digits);

   bool ok = (dir == 1)
             ? g_trade.Buy(lots, s, 0.0, sl, tp, "EMA 21x55 up")
             : g_trade.Sell(lots, s, 0.0, sl, tp, "EMA 21x55 down");
   if(!ok)
      PrintFormat("DailyProfitEMA: order failed on %s (%s), retcode=%d",
                  s, dir == 1 ? "buy" : "sell", g_trade.ResultRetcode());
}

//+------------------------------------------------------------------+
//| Position size so that hitting the stop loses InpRiskPercent of   |
//| current equity. Skips the trade (rather than oversizing) if even |
//| the minimum lot would risk more than configured.                 |
//+------------------------------------------------------------------+
double CalcLots(const string s, const double slDist)
{
   double tickVal = SymbolInfoDouble(s, SYMBOL_TRADE_TICK_VALUE);
   double tickSz  = SymbolInfoDouble(s, SYMBOL_TRADE_TICK_SIZE);
   if(tickVal <= 0.0 || tickSz <= 0.0)
      return 0.0;

   double riskMoney  = AccountInfoDouble(ACCOUNT_EQUITY) * InpRiskPercent / 100.0;
   double lossPerLot = slDist / tickSz * tickVal;
   if(lossPerLot <= 0.0)
      return 0.0;

   double lots = riskMoney / lossPerLot;
   double step = SymbolInfoDouble(s, SYMBOL_VOLUME_STEP);
   double minL = SymbolInfoDouble(s, SYMBOL_VOLUME_MIN);
   double maxL = SymbolInfoDouble(s, SYMBOL_VOLUME_MAX);
   if(step > 0.0)
      lots = MathFloor(lots / step) * step;
   if(lots < minL)
   {
      PrintFormat("DailyProfitEMA: skipping %s, computed lot %.2f below broker minimum %.2f", s, lots, minL);
      return 0.0;
   }
   if(lots > maxL)
      lots = maxL;
   return NormalizeDouble(lots, 2);
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
