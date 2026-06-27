"""
EMA crossover + RSI filter strategy.

Signal logic:
  BUY  — fast EMA crosses above slow EMA AND RSI was oversold last bar
  SELL — fast EMA crosses below slow EMA AND RSI was overbought last bar
"""

from __future__ import annotations
from dataclasses import dataclass
from typing import List, Optional

from . import config
from .indicators import ema, rsi


@dataclass
class Signal:
    pair: str
    direction: str          # "BUY" | "SELL" | "NONE"
    price: float
    stop_loss: float
    take_profit: float
    reason: str


def _pip_value(pair: str) -> float:
    """Returns pip size for a given pair (0.01 for JPY pairs, 0.0001 otherwise)."""
    return 0.01 if "JPY" in pair else 0.0001


def generate_signal(pair: str, closes: List[float]) -> Signal:
    """Evaluate latest bar and return a trading signal."""
    pip = _pip_value(pair)
    price = closes[-1]
    no_signal = Signal(pair, "NONE", price, 0.0, 0.0, "No setup")

    fast = ema(closes, config.EMA_FAST)
    slow = ema(closes, config.EMA_SLOW)
    rsi_vals = rsi(closes, config.RSI_PERIOD)

    # Need at least two valid bars for crossover detection
    if fast[-2] is None or slow[-2] is None or rsi_vals[-1] is None:
        return no_signal

    prev_cross = fast[-2] - slow[-2]   # type: ignore[operator]
    curr_cross = fast[-1] - slow[-1]   # type: ignore[operator]

    sl_pips = config.STOP_LOSS_PIPS * pip
    tp_pips = config.TAKE_PROFIT_PIPS * pip

    if prev_cross <= 0 < curr_cross and rsi_vals[-2] is not None and rsi_vals[-2] < config.RSI_OVERSOLD:  # type: ignore[operator]
        return Signal(
            pair=pair,
            direction="BUY",
            price=price,
            stop_loss=round(price - sl_pips, 5),
            take_profit=round(price + tp_pips, 5),
            reason=f"EMA{config.EMA_FAST}/EMA{config.EMA_SLOW} bull cross, RSI oversold",
        )

    if prev_cross >= 0 > curr_cross and rsi_vals[-2] is not None and rsi_vals[-2] > config.RSI_OVERBOUGHT:  # type: ignore[operator]
        return Signal(
            pair=pair,
            direction="SELL",
            price=price,
            stop_loss=round(price + sl_pips, 5),
            take_profit=round(price - tp_pips, 5),
            reason=f"EMA{config.EMA_FAST}/EMA{config.EMA_SLOW} bear cross, RSI overbought",
        )

    return no_signal
