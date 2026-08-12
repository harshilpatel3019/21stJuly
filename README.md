# TradingView MCP Server

A [Model Context Protocol](https://modelcontextprotocol.io) (MCP) server that gives AI assistants access to TradingView market data — symbol search, quotes, top movers, and a flexible market screener. Runs over stdio using the official `@modelcontextprotocol/sdk`.

> **Note:** This server uses TradingView's public web endpoints (the same ones tradingview.com uses). No API key is required, but these endpoints are not an officially supported API and may change without notice.

## Requirements

- Node.js 18+

## Installation

```bash
git clone <this-repo>
cd <this-repo>
npm install
```

## Configuration

Add the server to your MCP client config (e.g. Claude Desktop's `claude_desktop_config.json` or Claude Code's `.mcp.json`), replacing `<INSTALL_PATH>` with the absolute path to this repository:

```json
{
  "mcpServers": {
    "tradingview": {
      "command": "node",
      "args": ["<INSTALL_PATH>/src/server.js"]
    }
  }
}
```

## Tools

| Tool | Description |
|------|-------------|
| `search_symbols` | Find tickers by free-text query (company name, symbol, pair). Returns fully-qualified symbols like `NASDAQ:AAPL`. Optional `exchange` and `type` filters. |
| `get_quotes` | Current price, change, volume, market cap, P/E and more for up to 50 fully-qualified tickers. |
| `get_top_movers` | Today's top `gainers`, `losers`, or `most_active` symbols for a market (default: US stocks). |
| `scan_market` | Run a custom screener scan with filters, sort, and column selection — e.g. "US stocks with P/E under 15 and market cap over $10B". |

### Markets

Quote and screener tools take a `market` parameter matching TradingView's scanner segments: `america` (default), `crypto`, `forex`, `futures`, and country markets like `germany`, `india`, `uk`, `japan`, etc.

### Example prompts

- "Search TradingView for Apple and get its current quote."
- "What are today's top 10 gainers on the US market?"
- "Screen for US stocks with market cap over $100B sorted by P/E ascending."
- "Get quotes for NASDAQ:AAPL, NASDAQ:MSFT, and NYSE:BRK.A."

## Running manually

```bash
npm start
```

The server communicates over stdin/stdout using JSON-RPC (MCP), so it is meant to be launched by an MCP client rather than used directly.

## Project structure

```
src/
  server.js       # MCP server: tool registration + stdio transport
  tradingview.js  # TradingView endpoint client (search + scanner)
```

## License

MIT
