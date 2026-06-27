import pytest
import sys, os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "../.."))

from forex_bot.indicators import ema, rsi, atr


def test_ema_returns_none_for_insufficient_data():
    result = ema([1.0, 2.0], period=9)
    assert all(v is None for v in result)


def test_ema_length_matches_input():
    prices = list(range(1, 30))
    result = ema(prices, period=9)
    assert len(result) == len(prices)


def test_ema_values_are_increasing_on_rising_series():
    prices = [float(i) for i in range(1, 50)]
    result = ema(prices, period=9)
    valid = [v for v in result if v is not None]
    assert valid == sorted(valid)


def test_rsi_bounded():
    import random
    random.seed(42)
    prices = [1.0 + random.gauss(0, 0.01) for _ in range(100)]
    result = rsi(prices, period=14)
    for v in result:
        if v is not None:
            assert 0.0 <= v <= 100.0


def test_atr_positive():
    closes = [1.0 + i * 0.001 for i in range(50)]
    highs  = [c + 0.002 for c in closes]
    lows   = [c - 0.002 for c in closes]
    result = atr(highs, lows, closes, period=14)
    for v in result:
        if v is not None:
            assert v > 0
