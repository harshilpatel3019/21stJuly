"""
Position sizing and trade risk management.
"""

from __future__ import annotations
from . import config


def position_size(account_balance: float, stop_loss_pips: int, pip_value_per_lot: float = 10.0) -> float:
    """
    Returns lot size so that a stop-loss hit loses exactly RISK_PER_TRADE
    of the account balance.

    pip_value_per_lot: USD value of 1 pip on a standard lot (default $10 for USD quote pairs).
    """
    risk_amount = account_balance * config.RISK_PER_TRADE
    lot_size = risk_amount / (stop_loss_pips * pip_value_per_lot)
    # Round down to 2 decimal places (micro-lot precision)
    return round(int(lot_size * 100) / 100, 2)


def max_trades_reached(open_trades: int) -> bool:
    return open_trades >= config.MAX_OPEN_TRADES
