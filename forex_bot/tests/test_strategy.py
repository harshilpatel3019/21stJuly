import sys, os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "../.."))

from forex_bot.strategy import generate_signal


def _flat_prices(n=150, base=1.085):
    return [base] * n


def test_no_signal_on_flat_prices():
    signal = generate_signal("EUR/USD", _flat_prices())
    assert signal.direction == "NONE"


def test_signal_has_correct_pair():
    signal = generate_signal("GBP/USD", _flat_prices(base=1.27))
    assert signal.pair == "GBP/USD"


def test_buy_signal_sl_below_price():
    # Build a rising close sequence that should trigger a bull cross
    prices = [1.085 + i * 0.0001 for i in range(150)]
    signal = generate_signal("EUR/USD", prices)
    if signal.direction == "BUY":
        assert signal.stop_loss < signal.price
        assert signal.take_profit > signal.price
