# reaper-mcp

[![ci](https://github.com/yiw190/reaper-mcp/actions/workflows/ci.yml/badge.svg)](https://github.com/yiw190/reaper-mcp/actions/workflows/ci.yml)

MCP server for [REAPER](https://reaper.fm).

```
MCP client  --stdio JSON-RPC-->  python/server.py  --JSON mailbox-->  lua/bridge.lua (inside REAPER)
```

Eleven grouped tools. Multi-step edits go through `batch`; anything else through `reaper_call` / `run_lua`.

## Setup

```bash
git clone https://github.com/yiw190/reaper-mcp.git
cd reaper-mcp
python3 python/install_bridge.py
```

Then in REAPER: **Actions → Load ReaScript → `reaper_mcp_bridge.lua` → Run**. Console: `reaper-mcp bridge 0.1.0 ready`.

MCP client config (Claude Code / Claude Desktop / Cursor):

```json
{
  "mcpServers": {
    "reaper": {
      "command": "python3",
      "args": ["/absolute/path/to/reaper-mcp/python/server.py"]
    }
  }
}
```

Use native Windows Python, not WSL.

```
REAPER_MCP_IPC_DIR     mailbox override (must match on both sides)
REAPER_MCP_TIMEOUT     default 10s
REAPER_MCP_DEBUG=1     Lua request log
```

Mailbox is `%APPDATA%/reaper-mcp/ipc` (ASCII path both sides derive). Time is **beats**. Indices are 0-based.

## Tools

`status` `transport` `track` `midi` `fx` `project` `render` `action` `reaper_call` `run_lua` `batch`

## Tests

```
python3 python/test_server.py
```

Fake bridge, no REAPER.

## License

MIT
