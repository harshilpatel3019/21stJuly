"""
Forex trading bot configuration.
All monetary values in account currency; prices in quote currency.
"""

# Trading pairs to watch
PAIRS = ["EUR/USD", "GBP/USD", "USD/JPY", "USD/CHF", "AUD/USD"]

# Strategy parameters
EMA_FAST = 9        # fast EMA period
EMA_SLOW = 21       # slow EMA period
RSI_PERIOD = 14
RSI_OVERBOUGHT = 70
RSI_OVERSOLD = 30

# Risk management
RISK_PER_TRADE = 0.01   # 1% of account per trade
STOP_LOSS_PIPS = 20
TAKE_PROFIT_PIPS = 40   # 2:1 R/R
MAX_OPEN_TRADES = 3

# Broker / data source (paper trading by default)
BROKER = "paper"        # "paper" | "oanda" | "fxcm"
OANDA_API_KEY = ""
OANDA_ACCOUNT_ID = ""
FXCM_ACCESS_TOKEN = ""

# Candle timeframe
TIMEFRAME = "H1"        # M5 M15 H1 H4 D1

# Logging
LOG_LEVEL = "INFO"
LOG_FILE = "forex_bot.log"
