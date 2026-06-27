"""
Broker abstraction layer.

Supports:
  - PaperBroker  — in-memory simulation (default)
  - OandaBroker  — live via OANDA v20 REST API  (requires `oandapyV20`)
"""

from __future__ import annotations
import logging
import random
from abc import ABC, abstractmethod
from dataclasses import dataclass, field
from datetime import datetime
from typing import Dict, List, Optional

from . import config

logger = logging.getLogger(__name__)


@dataclass
class Trade:
    id: str
    pair: str
    direction: str
    lot_size: float
    entry_price: float
    stop_loss: float
    take_profit: float
    opened_at: datetime = field(default_factory=datetime.utcnow)
    closed_at: Optional[datetime] = None
    pnl: float = 0.0
    status: str = "OPEN"    # OPEN | CLOSED | CANCELLED


class BaseBroker(ABC):
    @abstractmethod
    def get_price(self, pair: str) -> float: ...

    @abstractmethod
    def get_candles(self, pair: str, count: int = 100) -> List[Dict]: ...

    @abstractmethod
    def open_trade(self, pair: str, direction: str, lot_size: float,
                   stop_loss: float, take_profit: float) -> Trade: ...

    @abstractmethod
    def close_trade(self, trade_id: str) -> Trade: ...

    @abstractmethod
    def get_open_trades(self) -> List[Trade]: ...

    @abstractmethod
    def account_balance(self) -> float: ...


# ---------------------------------------------------------------------------
# Paper (simulation) broker
# ---------------------------------------------------------------------------

class PaperBroker(BaseBroker):
    """Simulates order execution with randomly generated price data."""

    def __init__(self, initial_balance: float = 10_000.0) -> None:
        self._balance = initial_balance
        self._trades: Dict[str, Trade] = {}
        self._prices: Dict[str, float] = {
            "EUR/USD": 1.0850, "GBP/USD": 1.2700, "USD/JPY": 149.50,
            "USD/CHF": 0.8960, "AUD/USD": 0.6550,
        }

    def get_price(self, pair: str) -> float:
        # Simulate slight random walk
        move = random.uniform(-0.0005, 0.0005)
        self._prices[pair] = round(self._prices.get(pair, 1.0) + move, 5)
        return self._prices[pair]

    def get_candles(self, pair: str, count: int = 100) -> List[Dict]:
        """Generate synthetic OHLC candles for back-testing / signal generation."""
        price = self._prices.get(pair, 1.0)
        candles = []
        for _ in range(count):
            o = price
            h = o + random.uniform(0, 0.003)
            l = o - random.uniform(0, 0.003)
            c = random.uniform(l, h)
            candles.append({"open": o, "high": h, "low": l, "close": c})
            price = c
        return candles

    def open_trade(self, pair: str, direction: str, lot_size: float,
                   stop_loss: float, take_profit: float) -> Trade:
        price = self.get_price(pair)
        trade_id = f"paper-{len(self._trades) + 1:04d}"
        trade = Trade(
            id=trade_id, pair=pair, direction=direction,
            lot_size=lot_size, entry_price=price,
            stop_loss=stop_loss, take_profit=take_profit,
        )
        self._trades[trade_id] = trade
        logger.info("OPEN  %s %s %s lots @ %.5f | SL %.5f TP %.5f",
                    direction, pair, lot_size, price, stop_loss, take_profit)
        return trade

    def close_trade(self, trade_id: str) -> Trade:
        trade = self._trades[trade_id]
        exit_price = self.get_price(trade.pair)
        pip = 0.01 if "JPY" in trade.pair else 0.0001
        pips = (exit_price - trade.entry_price) / pip
        if trade.direction == "SELL":
            pips = -pips
        trade.pnl = round(pips * trade.lot_size * 10, 2)
        trade.status = "CLOSED"
        trade.closed_at = datetime.utcnow()
        self._balance += trade.pnl
        logger.info("CLOSE %s %s PnL %.2f | balance %.2f",
                    trade.pair, trade.direction, trade.pnl, self._balance)
        return trade

    def get_open_trades(self) -> List[Trade]:
        return [t for t in self._trades.values() if t.status == "OPEN"]

    def account_balance(self) -> float:
        return self._balance


# ---------------------------------------------------------------------------
# OANDA broker (requires `pip install oandapyV20`)
# ---------------------------------------------------------------------------

class OandaBroker(BaseBroker):
    """Live broker via OANDA v20 REST API."""

    def __init__(self) -> None:
        try:
            import oandapyV20
            import oandapyV20.endpoints.accounts as accounts
            import oandapyV20.endpoints.instruments as instruments
            import oandapyV20.endpoints.orders as orders
            import oandapyV20.endpoints.trades as trades_ep
            self._oanda = oandapyV20
            self._accounts = accounts
            self._instruments = instruments
            self._orders = orders
            self._trades_ep = trades_ep
        except ImportError:
            raise RuntimeError("Install oandapyV20: pip install oandapyV20")

        self._client = self._oanda.API(access_token=config.OANDA_API_KEY)
        self._account_id = config.OANDA_ACCOUNT_ID

    def _pair_to_oanda(self, pair: str) -> str:
        return pair.replace("/", "_")

    def get_price(self, pair: str) -> float:
        import oandapyV20.endpoints.pricing as pricing
        r = pricing.PricingInfo(accountID=self._account_id,
                                params={"instruments": self._pair_to_oanda(pair)})
        self._client.request(r)
        return float(r.response["prices"][0]["closeoutAsk"])

    def get_candles(self, pair: str, count: int = 100) -> List[Dict]:
        import oandapyV20.endpoints.instruments as instruments
        r = instruments.InstrumentsCandles(
            self._pair_to_oanda(pair),
            params={"count": count, "granularity": config.TIMEFRAME},
        )
        self._client.request(r)
        return [
            {
                "open": float(c["mid"]["o"]),
                "high": float(c["mid"]["h"]),
                "low": float(c["mid"]["l"]),
                "close": float(c["mid"]["c"]),
            }
            for c in r.response["candles"]
        ]

    def open_trade(self, pair: str, direction: str, lot_size: float,
                   stop_loss: float, take_profit: float) -> Trade:
        units = int(lot_size * 100_000)
        if direction == "SELL":
            units = -units
        body = {
            "order": {
                "type": "MARKET",
                "instrument": self._pair_to_oanda(pair),
                "units": str(units),
                "stopLossOnFill": {"price": f"{stop_loss:.5f}"},
                "takeProfitOnFill": {"price": f"{take_profit:.5f}"},
            }
        }
        import oandapyV20.endpoints.orders as orders
        r = orders.OrderCreate(self._account_id, data=body)
        self._client.request(r)
        fill = r.response["orderFillTransaction"]
        return Trade(
            id=fill["id"], pair=pair, direction=direction,
            lot_size=lot_size, entry_price=float(fill["price"]),
            stop_loss=stop_loss, take_profit=take_profit,
        )

    def close_trade(self, trade_id: str) -> Trade:
        import oandapyV20.endpoints.trades as trades_ep
        r = trades_ep.TradeClose(self._account_id, tradeID=trade_id)
        self._client.request(r)
        t = r.response["orderFillTransaction"]
        return Trade(
            id=trade_id, pair=t["instrument"], direction="",
            lot_size=0, entry_price=0,
            stop_loss=0, take_profit=0,
            pnl=float(t.get("pl", 0)), status="CLOSED",
        )

    def get_open_trades(self) -> List[Trade]:
        import oandapyV20.endpoints.trades as trades_ep
        r = trades_ep.OpenTrades(self._account_id)
        self._client.request(r)
        return [
            Trade(
                id=t["id"],
                pair=t["instrument"].replace("_", "/"),
                direction="BUY" if int(t["currentUnits"]) > 0 else "SELL",
                lot_size=abs(int(t["currentUnits"])) / 100_000,
                entry_price=float(t["price"]),
                stop_loss=float(t.get("stopLossOrder", {}).get("price", 0)),
                take_profit=float(t.get("takeProfitOrder", {}).get("price", 0)),
            )
            for t in r.response.get("trades", [])
        ]

    def account_balance(self) -> float:
        r = self._accounts.AccountSummary(self._account_id)
        self._client.request(r)
        return float(r.response["account"]["balance"])


def get_broker() -> BaseBroker:
    if config.BROKER == "oanda":
        return OandaBroker()
    return PaperBroker()
