#!/usr/bin/env node
/**
 * TradingView MCP server (stdio transport).
 *
 * Exposes TradingView market data as MCP tools:
 *  - search_symbols : find tickers by free-text query
 *  - get_quotes     : quotes + fundamentals for specific tickers
 *  - get_top_movers : gainers / losers / most active for a market
 *  - scan_market    : flexible screener scan with custom filters/sort/columns
 */

import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { z } from "zod";
import {
  searchSymbols,
  getQuotes,
  getTopMovers,
  scan,
  rowsToObjects,
  QUOTE_COLUMNS,
} from "./tradingview.js";

const server = new McpServer({
  name: "tradingview",
  version: "1.0.0",
});

function jsonResult(data) {
  return { content: [{ type: "text", text: JSON.stringify(data, null, 2) }] };
}

function errorResult(err) {
  return {
    content: [{ type: "text", text: `Error: ${err.message ?? String(err)}` }],
    isError: true,
  };
}

server.registerTool(
  "search_symbols",
  {
    title: "Search symbols",
    description:
      "Search TradingView for tickers by free-text query (company name, symbol, pair). " +
      "Returns fully-qualified symbols like NASDAQ:AAPL to use with the other tools.",
    inputSchema: {
      query: z.string().min(1).describe("Free-text search, e.g. 'apple' or 'BTCUSD'"),
      exchange: z
        .string()
        .optional()
        .describe("Restrict to an exchange, e.g. 'NASDAQ', 'NYSE', 'BINANCE'"),
      type: z
        .enum(["stock", "crypto", "forex", "futures", "index", "bond", "economic"])
        .optional()
        .describe("Restrict to an asset type"),
    },
  },
  async ({ query, exchange, type }) => {
    try {
      const results = await searchSymbols(query, { exchange, type });
      return jsonResult(results);
    } catch (err) {
      return errorResult(err);
    }
  }
);

server.registerTool(
  "get_quotes",
  {
    title: "Get quotes",
    description:
      "Get current quote data (price, change, volume, market cap, P/E, ...) for one or more " +
      "fully-qualified tickers, e.g. ['NASDAQ:AAPL', 'NYSE:GME']. Use search_symbols first if " +
      "you only know the company name.",
    inputSchema: {
      tickers: z
        .array(z.string())
        .min(1)
        .max(50)
        .describe("Fully-qualified tickers like 'NASDAQ:AAPL'"),
      market: z
        .string()
        .default("america")
        .describe(
          "Scanner market segment: 'america' (default), 'crypto', 'forex', 'germany', 'india', etc."
        ),
      columns: z
        .array(z.string())
        .optional()
        .describe(
          `Scanner columns to return. Defaults to: ${QUOTE_COLUMNS.join(", ")}`
        ),
    },
  },
  async ({ tickers, market, columns }) => {
    try {
      const quotes = await getQuotes(tickers, market, columns ?? QUOTE_COLUMNS);
      return jsonResult(quotes);
    } catch (err) {
      return errorResult(err);
    }
  }
);

server.registerTool(
  "get_top_movers",
  {
    title: "Get top movers",
    description:
      "Get today's top gainers, losers, or most active symbols for a market " +
      "(default: US stocks). Filters out sub-$1 and illiquid symbols.",
    inputSchema: {
      category: z
        .enum(["gainers", "losers", "most_active"])
        .describe("Which mover list to fetch"),
      market: z
        .string()
        .default("america")
        .describe("Scanner market segment, e.g. 'america', 'crypto', 'india'"),
      limit: z.number().int().min(1).max(100).default(10).describe("Number of rows"),
    },
  },
  async ({ category, market, limit }) => {
    try {
      const movers = await getTopMovers(category, market, limit);
      return jsonResult(movers);
    } catch (err) {
      return errorResult(err);
    }
  }
);

server.registerTool(
  "scan_market",
  {
    title: "Scan market (screener)",
    description:
      "Run a custom TradingView screener scan. Supply filters (e.g. " +
      `[{"left":"market_cap_basic","operation":"greater","right":1000000000}]), ` +
      "a sort column, and the columns to return. Useful for questions like " +
      "'US stocks with P/E under 15 and market cap over $10B'.",
    inputSchema: {
      market: z
        .string()
        .default("america")
        .describe("Scanner market segment, e.g. 'america', 'crypto', 'forex'"),
      filters: z
        .array(
          z.object({
            left: z.string().describe("Field name, e.g. 'close', 'market_cap_basic'"),
            operation: z
              .string()
              .describe(
                "Operator: greater, less, egreater, eless, equal, nequal, in_range, nempty, ..."
              ),
            right: z
              .union([z.number(), z.string(), z.array(z.union([z.number(), z.string()]))])
              .optional()
              .describe("Comparison value (omit for 'nempty')"),
          })
        )
        .default([])
        .describe("Screener filter conditions (ANDed together)"),
      columns: z
        .array(z.string())
        .default(["name", "description", "close", "change", "volume", "market_cap_basic"])
        .describe("Columns to return for each matching symbol"),
      sort_by: z.string().optional().describe("Column to sort by, e.g. 'market_cap_basic'"),
      sort_order: z.enum(["asc", "desc"]).default("desc"),
      limit: z.number().int().min(1).max(200).default(25).describe("Number of rows"),
    },
  },
  async ({ market, filters, columns, sort_by, sort_order, limit }) => {
    try {
      const body = {
        filter: filters,
        options: { lang: "en" },
        markets: [market],
        columns,
        range: [0, limit],
      };
      if (sort_by) body.sort = { sortBy: sort_by, sortOrder: sort_order };
      const res = await scan(market, body);
      return jsonResult({ total: res.totalCount, rows: rowsToObjects(res, columns) });
    } catch (err) {
      return errorResult(err);
    }
  }
);

const transport = new StdioServerTransport();
await server.connect(transport);
console.error("TradingView MCP server running on stdio");
