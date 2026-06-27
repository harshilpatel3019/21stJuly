"""
Main trading bot loop.

Usage:
    python -m forex_bot.bot           # run live loop
    python -m forex_bot.bot --once    # evaluate signals once and exit
"""

from __future__ import annotations
import argparse
import logging
import time

from . import config
from .broker import get_broker
from .risk import max_trades_reached, position_size
from .strategy import generate_signal

logging.basicConfig(
    level=config.LOG_LEVEL,
    format="%(asctime)s [%(levelname)s] %(message)s",
    handlers=[
        logging.StreamHandler(),
        logging.FileHandler(config.LOG_FILE),
    ],
)
logger = logging.getLogger(__name__)

POLL_SECONDS = {
    "M5": 300, "M15": 900, "H1": 3600, "H4": 14400, "D1": 86400,
}.get(config.TIMEFRAME, 3600)


def run_once(broker) -> None:
    balance = broker.account_balance()
    open_trades = broker.get_open_trades()
    logger.info("Balance: %.2f | Open trades: %d", balance, len(open_trades))

    if max_trades_reached(len(open_trades)):
        logger.info("Max open trades reached (%d), skipping scan.", config.MAX_OPEN_TRADES)
        return

    for pair in config.PAIRS:
        candles = broker.get_candles(pair, count=150)
        closes = [c["close"] for c in candles]

        signal = generate_signal(pair, closes)
        if signal.direction == "NONE":
            logger.debug("%s — no signal", pair)
            continue

        logger.info("SIGNAL %s %s @ %.5f | %s", signal.direction, pair, signal.price, signal.reason)

        lots = position_size(balance, config.STOP_LOSS_PIPS)
        if lots <= 0:
            logger.warning("Calculated lot size is 0, skipping trade.")
            continue

        broker.open_trade(
            pair=pair,
            direction=signal.direction,
            lot_size=lots,
            stop_loss=signal.stop_loss,
            take_profit=signal.take_profit,
        )

        if max_trades_reached(len(broker.get_open_trades())):
            logger.info("Max open trades reached after opening, stopping scan.")
            break


def run_loop(broker) -> None:
    logger.info("Forex bot started. Timeframe: %s | Broker: %s", config.TIMEFRAME, config.BROKER)
    while True:
        try:
            run_once(broker)
        except Exception as exc:
            logger.exception("Unexpected error: %s", exc)
        logger.info("Sleeping %ds until next bar...", POLL_SECONDS)
        time.sleep(POLL_SECONDS)


def main() -> None:
    parser = argparse.ArgumentParser(description="Forex trading bot")
    parser.add_argument("--once", action="store_true", help="Run one evaluation cycle and exit")
    args = parser.parse_args()

    broker = get_broker()
    if args.once:
        run_once(broker)
    else:
        run_loop(broker)


if __name__ == "__main__":
    main()
