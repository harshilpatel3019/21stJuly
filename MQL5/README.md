# DailyProfitEMA — EMA 21/55 intraday EA with daily profit booking

An MetaTrader 5 Expert Advisor that trades **EURUSD, GBPUSD and GBPJPY** from a
single chart on **H1**, enters on **EMA(21) / EMA(55) crossovers**, and manages
the account like an intraday prop trader:

- **Books profit for the day** — once the account is up the daily target
  (default **$1,200**), every position is closed and no new trade is opened
  until the next day.
- **Daily max loss** — once the account is down the daily loss limit
  (default **$600**), it also stops for the day. The 2:1 target/loss asymmetry
  is what keeps the daily-target approach survivable.
- **Goes flat at end of day** (default 22:00 server time) — it is an intraday
  bot and holds nothing overnight.

## Strategy logic

| Rule | Behaviour |
|---|---|
| Buy | EMA(21) crosses **above** EMA(55) |
| Sell | EMA(21) crosses **below** EMA(55) |
| Signal timing | By default reacts **intrabar** (on the forming H1 candle, per tick). Set `InpIntrabar=false` to only act on closed candles. |
| Exit | Fixed SL at `1.5 × ATR(14)`, TP at `2 × SL distance`, plus close on the opposite cross. |
| Position size | Risk-based: hitting the SL loses `InpRiskPercent` (default 0.5%) of equity. Lot size adapts per symbol (handles GBPJPY's different pip value automatically). |
| Concurrency | One position per symbol, max 3 total. |
| Session | New entries only between 07:00–20:00 server time by default. |

The cross detector is a state machine on the fast/slow EMA relation, so each
cross fires exactly once — no duplicate entries while the EMAs hover around
each other, and no phantom trade at startup from an already-existing trend.

The day-start equity snapshot is persisted in terminal global variables, so a
terminal or EA restart mid-day does **not** reset the daily profit/loss
tracking.

## Installation

1. Open MetaEditor (F4 from MT5), copy `Experts/DailyProfitEMA.mq5` into your
   terminal's `MQL5/Experts/` folder, and compile (F7).
2. Make sure EURUSD, GBPUSD and GBPJPY are visible in Market Watch.
3. Attach the EA to **any one** H1 chart (e.g. EURUSD H1) — it trades all
   three symbols from that single chart. Do not attach it to multiple charts
   with the same magic number.
4. Enable Algo Trading.

## Backtesting (do this before any live money)

In the MT5 Strategy Tester:

- Chart: EURUSD H1, model **"Every tick based on real ticks"** (intrabar
  signals need tick data; "Open prices only" will not reproduce them).
- The tester automatically pulls data for the other two symbols the EA
  requests.
- Test at least 2–3 years, then forward-test on a **demo account** for a few
  weeks.

## Key inputs

| Input | Default | Meaning |
|---|---|---|
| `InpSymbols` | EURUSD,GBPUSD,GBPJPY | Traded symbols (comma separated) |
| `InpTF` | H1 | Signal timeframe |
| `InpFastEMA` / `InpSlowEMA` | 21 / 55 | EMA periods |
| `InpIntrabar` | true | React to crosses on the open candle |
| `InpDailyTarget` | 1200 | Daily profit ($) at which everything is closed and trading stops |
| `InpDailyMaxLoss` | 600 | Daily loss ($) at which trading stops |
| `InpFlattenAtEOD` / `InpFlattenHour` | true / 22 | Close all positions at end of day |
| `InpRiskPercent` | 0.5 | % of equity risked per trade |
| `InpATRMultSL` / `InpRewardRisk` | 1.5 / 2.0 | Stop-loss and take-profit geometry |
| `InpMaxTotalPos` | 3 | Max simultaneous positions |
| `InpMagic` | 21550708 | Magic number (EA only touches its own trades) |

## Honest expectations — read this

- **$1,200/day is a booking target, not a guarantee.** The EA locks in $1,200
  on days the strategy gets there and caps damage on days it doesn't. No EA
  can produce a fixed daily profit; anything promising that is a martingale
  waiting to blow up.
- EMA crossovers are a **trend-following** signal: they perform in trending
  markets and get whipsawed in ranges. Intrabar mode reacts faster but takes
  more whipsaw trades than closed-candle mode — backtest both.
- EURUSD, GBPUSD and GBPJPY are correlated (GBP appears twice), so
  simultaneous signals often win or lose together. That's why the default max
  position count and per-trade risk are conservative.
- All hour-based inputs use **broker server time**, which usually differs from
  your local time.
