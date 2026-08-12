/**
 * Thin client for TradingView's public (unauthenticated) web endpoints:
 *  - Symbol search:  https://symbol-search.tradingview.com/symbol_search/v3/
 *  - Market scanner: https://scanner.tradingview.com/{market}/scan
 *
 * These are the same endpoints the tradingview.com website uses. They do not
 * require an API key, but they are not an officially supported API, so shapes
 * may change without notice.
 */

const SEARCH_BASE = "https://symbol-search.tradingview.com/symbol_search/v3/";
const SCANNER_BASE = "https://scanner.tradingview.com";

const DEFAULT_HEADERS = {
  "User-Agent":
    "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36",
  Origin: "https://www.tradingview.com",
  Referer: "https://www.tradingview.com/",
};

const REQUEST_TIMEOUT_MS = 15_000;

async function httpJson(url, options = {}) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), REQUEST_TIMEOUT_MS);
  try {
    const res = await fetch(url, {
      ...options,
      headers: { ...DEFAULT_HEADERS, ...(options.headers ?? {}) },
      signal: controller.signal,
    });
    if (!res.ok) {
      const body = await res.text().catch(() => "");
      throw new Error(
        `TradingView request failed: HTTP ${res.status} ${res.statusText}` +
          (body ? ` — ${body.slice(0, 300)}` : "")
      );
    }
    return await res.json();
  } finally {
    clearTimeout(timer);
  }
}

/**
 * Search for symbols (stocks, crypto, forex, futures, indices...).
 * @param {string} text - free-text query, e.g. "apple" or "BTCUSD"
 * @param {object} [opts]
 * @param {string} [opts.exchange] - restrict to an exchange, e.g. "NASDAQ"
 * @param {string} [opts.type] - restrict to an asset type: stock, crypto, forex, futures, index, bond, economic
 */
export async function searchSymbols(text, { exchange, type } = {}) {
  const params = new URLSearchParams({
    text,
    hl: "0",
    lang: "en",
    domain: "production",
    sort_by_country: "US",
  });
  if (exchange) params.set("exchange", exchange);
  if (type) params.set("search_type", type);

  const data = await httpJson(`${SEARCH_BASE}?${params}`);
  const items = data.symbols ?? [];
  return items.map((s) => ({
    symbol: `${s.prefix ?? s.exchange}:${stripHighlight(s.symbol)}`,
    description: stripHighlight(s.description),
    type: s.type,
    exchange: s.exchange,
    currency: s.currency_code,
    country: s.country,
    provider_id: s.provider_id,
  }));
}

function stripHighlight(value) {
  return typeof value === "string" ? value.replace(/<\/?em>/g, "") : value;
}

/** Default columns returned for quote requests. */
export const QUOTE_COLUMNS = [
  "name",
  "description",
  "close",
  "change",
  "change_abs",
  "open",
  "high",
  "low",
  "volume",
  "market_cap_basic",
  "price_earnings_ttm",
  "earnings_per_share_basic_ttm",
  "sector",
  "currency",
];

/**
 * Run a raw scan against the TradingView screener.
 * @param {string} market - scanner market segment, e.g. "america", "crypto", "forex", "germany", "india"
 * @param {object} body - scanner request body ({symbols|filter, columns, sort, range, markets})
 */
export async function scan(market, body) {
  return httpJson(`${SCANNER_BASE}/${encodeURIComponent(market)}/scan`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
}

/** Turn a scanner response into an array of {symbol, <column>: value} objects. */
export function rowsToObjects(scanResponse, columns) {
  return (scanResponse.data ?? []).map((row) => {
    const out = { symbol: row.s };
    columns.forEach((col, i) => {
      out[col] = row.d[i];
    });
    return out;
  });
}

/**
 * Get quotes for a list of fully-qualified tickers (e.g. "NASDAQ:AAPL").
 * @param {string[]} tickers
 * @param {string} [market="america"]
 * @param {string[]} [columns=QUOTE_COLUMNS]
 */
export async function getQuotes(tickers, market = "america", columns = QUOTE_COLUMNS) {
  const res = await scan(market, {
    symbols: { tickers, query: { types: [] } },
    columns,
  });
  return rowsToObjects(res, columns);
}

const MOVER_SORT = {
  gainers: { sortBy: "change", sortOrder: "desc" },
  losers: { sortBy: "change", sortOrder: "asc" },
  most_active: { sortBy: "volume", sortOrder: "desc" },
};

/**
 * Get top movers for a market.
 * @param {"gainers"|"losers"|"most_active"} category
 * @param {string} [market="america"]
 * @param {number} [limit=10]
 */
export async function getTopMovers(category, market = "america", limit = 10) {
  const columns = [
    "name",
    "description",
    "close",
    "change",
    "change_abs",
    "volume",
    "market_cap_basic",
    "sector",
  ];
  const res = await scan(market, {
    filter: [
      { left: "change", operation: "nempty" },
      { left: "close", operation: "greater", right: 1 },
      { left: "volume", operation: "greater", right: 100_000 },
    ],
    options: { lang: "en" },
    markets: [market],
    columns,
    sort: MOVER_SORT[category],
    range: [0, limit],
  });
  return rowsToObjects(res, columns);
}
