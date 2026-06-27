"""
Technical indicators computed over a list/array of closing prices.
All functions accept and return plain Python lists for zero dependencies.
"""

from __future__ import annotations
from typing import List, Optional


def ema(prices: List[float], period: int) -> List[Optional[float]]:
    """Exponential moving average; returns None for insufficient data."""
    result: List[Optional[float]] = [None] * len(prices)
    if len(prices) < period:
        return result

    k = 2.0 / (period + 1)
    # seed with simple MA
    seed = sum(prices[:period]) / period
    result[period - 1] = seed
    for i in range(period, len(prices)):
        result[i] = prices[i] * k + result[i - 1] * (1 - k)  # type: ignore[operator]
    return result


def rsi(prices: List[float], period: int = 14) -> List[Optional[float]]:
    """Relative Strength Index using Wilder smoothing."""
    result: List[Optional[float]] = [None] * len(prices)
    if len(prices) < period + 1:
        return result

    gains = []
    losses = []
    for i in range(1, len(prices)):
        diff = prices[i] - prices[i - 1]
        gains.append(max(diff, 0.0))
        losses.append(max(-diff, 0.0))

    avg_gain = sum(gains[:period]) / period
    avg_loss = sum(losses[:period]) / period

    for i in range(period, len(prices)):
        if i > period:
            avg_gain = (avg_gain * (period - 1) + gains[i - 1]) / period
            avg_loss = (avg_loss * (period - 1) + losses[i - 1]) / period

        if avg_loss == 0:
            result[i] = 100.0
        else:
            rs = avg_gain / avg_loss
            result[i] = 100.0 - 100.0 / (1.0 + rs)

    return result


def atr(highs: List[float], lows: List[float], closes: List[float], period: int = 14) -> List[Optional[float]]:
    """Average True Range."""
    result: List[Optional[float]] = [None] * len(closes)
    if len(closes) < period + 1:
        return result

    trs = []
    for i in range(1, len(closes)):
        tr = max(
            highs[i] - lows[i],
            abs(highs[i] - closes[i - 1]),
            abs(lows[i] - closes[i - 1]),
        )
        trs.append(tr)

    avg = sum(trs[:period]) / period
    result[period] = avg
    for i in range(period + 1, len(closes)):
        avg = (avg * (period - 1) + trs[i - 1]) / period
        result[i] = avg

    return result
