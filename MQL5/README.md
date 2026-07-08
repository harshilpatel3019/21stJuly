# DailyProfitEMA v2 — EMA-band seeded grid with basket take-profit

A MetaTrader 5 Expert Advisor for **EURUSD H1** (attach to the chart of the
pair you want; it trades that chart's symbol). It runs self-contained
**cycles**:

1. **Seed** — on each H1 candle close, if that candle's **open OR close lies
   between EMA(21) and EMA(55)**, and the EA is flat, it opens **1 BUY + 1
   SELL** at the seed lot (0.01 each). Only when flat — one fresh cycle at a
   time.
2. **Grid** — every grid step of price movement it adds a trade in the
   direction of the move: price up → BUY, price down → SELL. The step is
   defined in money: **$2.00 of P/L per seed lot**, which on EURUSD with a
   0.01 seed equals **20 pips** (0.0020). A gap through several bands adds one
   trade per band.
3. **Running-lot sizing** — the running lot starts at 0.01. Each time the
   grid **direction flips**, it grows **×1.5** (0.01 → 0.015 → 0.0225 → …).
   Trades continuing the same direction reuse the current running lot.
   (Broker volume steps apply: with a 0.01-lot step, 0.015 rounds to 0.02 on
   the order, but the internal sequence keeps compounding exactly.)
4. **Daily profit booking** — no per-trade SL or TP. When the **day's total
   P/L** (profit already realized today **plus** current floating P/L)
   reaches **+$1,200**, ALL positions are closed, the profit is booked and
   trading halts until the next day. No lot cap by default (`InpMaxLot` = 0),
   no trend filter.
5. **Intraday** — everything is flattened at end of day (default 22:00
   server time) and no new cycle is seeded at/after 20:00, so nothing is
   held overnight.

## Restart behaviour

Cycle state (running lot, last grid direction, last band price) is persisted
in terminal global variables. Restarting MT5 or re-attaching the EA
**resumes the running cycle** where it left off. If open positions are found
but the saved state is missing, the EA switches to **manage-only** mode — it
still books at the daily target but places no new trades until flat. The
daily "booked" flag also survives restarts, and realized day P/L is read
from the deal history, so a restart cannot re-trade a day whose target was
already reached.

## Installation

1. Copy `Experts/DailyProfitEMA.mq5` into your terminal's `MQL5/Experts/`
   folder and compile in MetaEditor (F7).
2. Attach to the **EURUSD H1** chart (or any pair — it trades the chart's
   symbol; `InpSymbolOverride` can force a different one).
3. Enable Algo Trading. Use a **different magic number per chart** if you run
   it on several pairs.

## Inputs

| Input | Default | Meaning |
|---|---|---|
| `InpSymbolOverride` | *(blank)* | Blank = trade the chart's symbol |
| `InpTF` | H1 | Signal timeframe |
| `InpFastEMA` / `InpSlowEMA` | 21 / 55 | EMA band |
| `InpSeedLot` | 0.01 | Seed lot for the 1 BUY + 1 SELL cycle start |
| `InpGridUSD` | 2.0 | Grid step as $ of P/L per seed lot ($2 on 0.01 EURUSD = 20 pips) |
| `InpFlipMult` | 1.5 | Running-lot multiplier on each direction flip |
| `InpMaxLot` | 0 | Lot cap per trade (0 = none, per spec) |
| `InpDailyTarget` | 1200 | Day P/L ($, realized + floating) at which everything is booked and trading stops for the day |
| `InpFlattenAtEOD` / `InpFlattenHour` | true / 22 | End-of-day close-all (intraday operation) |
| `InpSeedEndHour` | 20 | No new cycles seeded at/after this hour |
| `InpMagic` | 21550708 | Magic number (EA only touches its own trades on its own symbol) |

## Backtesting

Strategy Tester → EURUSD, H1 chart, model **"Every tick based on real
ticks"**. Watch three things: the **equity vs. balance gap** (floating
drawdown of a cycle), the **largest lot reached** after consecutive flips,
and the **margin level** at the drawdown trough. Test a strong trending
period and a long ranging period separately — this system's risk lives in
the ranges.

## Read this before running it

- **This is a grid-martingale.** Every direction flip multiplies the running
  lot by 1.5; a long choppy range flips constantly (×1.5¹⁰ ≈ ×57, ×1.5²⁰ ≈
  ×3,325 of the seed lot). With **no SL, no lot cap and no loss limit**, the
  only hard floor is the broker's margin call.
- **The $1,200 daily target is far away from a 0.01 seed — especially
  intraday.** A clean 200-pip one-way run with 20-pip grid adds earns on the
  order of tens of dollars, not $1,200, and cycles only live until the
  end-of-day flatten. Expect most days to end at the 22:00 flatten P/L
  (often negative in ranges) rather than at the target. Consider testing a
  smaller daily target (e.g. $12–$50 per 0.01 seed) or a larger seed lot,
  and scale from what the tester shows.
- **The end-of-day flatten *realises* the cycle's floating P/L.** Intraday
  operation caps overnight risk, but it also converts every unfinished
  cycle's drawdown into a booked loss at 22:00 — watch the daily P/L
  distribution in the tester, not just the equity curve.
- Both seed legs open together, so one of them is always immediately losing;
  the cycle's floating P/L starts near zero minus spread.
- All hour-based inputs use **broker server time**.
- Backtest and demo only until you have seen a full year of cycles,
  including 2022-style one-way trends and long ranges.
