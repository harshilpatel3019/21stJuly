import sys, os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "../.."))

from forex_bot.risk import position_size, max_trades_reached


def test_position_size_basic():
    # 1% of $10k / (20 pips * $10/pip) = $100 / $200 = 0.5 lots
    size = position_size(10_000, stop_loss_pips=20, pip_value_per_lot=10.0)
    assert size == 0.5


def test_position_size_small_account():
    size = position_size(500, stop_loss_pips=20, pip_value_per_lot=10.0)
    assert size >= 0


def test_max_trades_not_reached():
    assert not max_trades_reached(2)


def test_max_trades_reached():
    assert max_trades_reached(3)
