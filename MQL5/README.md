# DailyProfitEMA — EMA 21/55 intraday EA with daily profit booking

A MetaTrader 5 Expert Advisor that trades **the symbol of the chart it is
attached to** (attach it to EURUSD, GBPUSD, GBPJPY — any pair — on **H1**),
enters on **EMA(21) / EMA(55) crossovers**, and manages the account like an
intraday prop trader. Optionally, a comma-separated symbol list input lets one
chart instance trade several pairs at once.

- **Books profit for the day** — once the **combined floating profit** of the
  open trades reaches the daily target (default **$1,200**), every position is
  closed and no new trade is opened until the next day.
- **Progressive lot sizing** — sequences start at **0.01**, grow by a step
  while the trend keeps paying, and a reversal trade opens at **double** the
  previous trade's lot.
- **No per-trade SL/TP by default** and **no daily loss limit** — positions
  float freely until the basket target, an opposite cross, or end of day
  closes them, so the full floating swing of a cycle is visible. The only
  hard protection left is the per-position lot cap. ATR-based SL/TP can be
  re-enabled via inputs.
- **Goes flat at end of day** (default 22:00 server time) — it is an intraday
  bot and holds nothing overnight.

## Strategy logic

| Rule | Behaviour |
|---|---|
| Buy | EMA(21) crosses **above** EMA(55) |
| Sell | EMA(21) crosses **below** EMA(55) |
| Signal timing | By default reacts **intrabar** (on the forming H1 candle, per tick). Set `InpIntrabar=false` to only act on closed candles. |
| Exit | Close on the opposite cross, basket booking at the floating target, and the end-of-day flatten. No per-trade SL/TP by default (`InpATRMultSL` / `InpATRMultTP` = 0); set them > 0 to add ATR-based stops back. |
| Position size | Progressive sequence per symbol: first trade `0.01`; a same-direction re-entry (after a TP/SL exit while the trend persists, max one per H1 bar) adds `InpLotStep` (default 0.01); a reversal trade multiplies the last lot by `InpReverseMult` (default 2×). Capped at `InpMaxLot`; sequence restarts at the base lot each day. |
| Concurrency | One position per symbol, max 3 total. |
| Session | New entries only between 07:00–20:00 server time by default. |

The cross detector is a state machine on the fast/slow EMA relation, so each
cross fires exactly once — no duplicate entries while the EMAs hover around
each other, and no phantom trade at startup from an already-existing trend.

The day-start equity snapshot is persisted in terminal global variables, so a
terminal or EA restart mid-day does **not** reset the daily profit/loss
tracking.

**Restart safety:** if the terminal or EA is restarted while trades are still
open, the EA goes into manage-only mode — it keeps handling exits (SL/TP,
opposite cross, daily target, end-of-day flatten) but opens **no new trades**
until every existing position is closed. This prevents stacking fresh entries
on top of an in-flight cycle whose lot-sequence state was lost in the restart.

## Installation

1. Open MetaEditor (F4 from MT5), copy `Experts/DailyProfitEMA.mq5` into your
   terminal's `MQL5/Experts/` folder, and compile (F7).
2. Attach the EA to the H1 chart of each pair you want traded (e.g. EURUSD
   H1) — with `InpSymbols` left blank it trades that chart's symbol only.
3. Enable Algo Trading.

**Attaching to multiple charts:** instances sharing the same magic number act
as **one basket** — the $1,200 floating target sums across all of them, and
whichever instance reaches it books *everything* and halts them all for the
day. Give each chart a **different magic number** if you want each pair to
have its own independent $1,200 target and lot sequence. Note that with a
shared magic, attaching to a new chart while other charts hold open trades
also engages the startup lock on that new instance until those trades close.

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
| `InpSymbols` | *(blank)* | Blank = trade the chart's own symbol; or a comma-separated list (e.g. `EURUSD,GBPUSD,GBPJPY`) to trade several from one chart |
| `InpTF` | H1 | Signal timeframe |
| `InpFastEMA` / `InpSlowEMA` | 21 / 55 | EMA periods |
| `InpIntrabar` | true | React to crosses on the open candle |
| `InpDailyTarget` | 1200 | Floating profit ($) of the open basket at which all trades are booked and trading stops for the day |
| `InpFlattenAtEOD` / `InpFlattenHour` | true / 22 | Close all positions at end of day |
| `InpBaseLot` | 0.01 | Starting lot of each sequence |
| `InpLotStep` | 0.01 | Lot increase for the next same-direction trade |
| `InpReverseMult` | 2.0 | Lot multiplier applied on a reversal trade |
| `InpMaxLot` | 2.0 | Hard cap on any single position's lot size |
| `InpReenterInTrend` | true | Re-enter after a TP/SL exit while the trend persists |
| `InpDailyLotReset` | true | Restart the lot sequence at the base lot each day |
| `InpATRMultSL` / `InpATRMultTP` | 0 / 0 | Optional per-trade SL/TP in ATR multiples (0 = disabled) |
| `InpMaxTotalPos` | 3 | Max simultaneous positions |
| `InpMagic` | 21550708 | Magic number (EA only touches its own trades) |

## Honest expectations — read this

- **$1,200/day is a booking target, not a guarantee.** The EA locks in $1,200
  on days the strategy gets there. No EA can produce a fixed daily profit.
- **The doubling-on-reversal sizing is a martingale variant.** In a choppy
  market the EMAs can cross many times in a day; each reversal doubles the
  lot (0.01 → 0.02 → 0.04 → 0.08 → …), so ten consecutive whipsaws would ask
  for 10+ lots. `InpMaxLot` (default 2.0) exists as a circuit breaker — do
  not raise it casually, and watch the sequence behaviour in the backtest
  before anything else.
- **With no SL and no daily loss limit, drawdown is unbounded until margin
  call.** A position on the wrong side of a strong trend floats a growing
  loss all day with nothing to cut it except the opposite cross or the
  end-of-day flatten. This configuration is for observing cycle behaviour in
  the Strategy Tester / on demo — it is not a live-money risk setup.
- Realized profit no longer counts toward the daily target: booking triggers
  only when the **open basket's floating** P/L reaches `InpDailyTarget`.
  Profit already realized by reversal closes doesn't accumulate into the
  trigger.
- EMA crossovers are a **trend-following** signal: they perform in trending
  markets and get whipsawed in ranges. Intrabar mode reacts faster but takes
  more whipsaw trades than closed-candle mode — backtest both.
- EURUSD, GBPUSD and GBPJPY are correlated (GBP appears twice), so
  simultaneous signals often win or lose together.
- The lot-sequence state (last lot / direction per symbol) lives in memory
  only: an EA or terminal restart mid-day restarts sequences at the base lot.
  The daily P/L tracking itself does survive restarts.
- All hour-based inputs use **broker server time**, which usually differs from
  your local time.
