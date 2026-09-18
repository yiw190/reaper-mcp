# reaper-mcp

[![ci](https://github.com/yiw190/reaper-mcp/actions/workflows/ci.yml/badge.svg)](https://github.com/yiw190/reaper-mcp/actions/workflows/ci.yml)

Small MCP server for [REAPER](https://reaper.fm). Not a fork.

```
MCP client  --stdio JSON-RPC-->  python/server.py  --JSON mailbox-->  lua/bridge.lua (inside REAPER)
```

**11 grouped tools**, not 180 flat `@mcp.tool`s. Long tail via `reaper_call` / `run_lua` / `batch`.

## Why this exists

| Problem | Who | Here |
|---|---|---|
| 10–30k tokens/turn of tool schema | xDarkzx 182 / TwelveTake 176 / shiehn “600+” | **11 tools**, grouped by `action` |
| IPC under `%TEMP%` (breaks WSL) | xDarkzx | `%APPDATA%/reaper-mcp/ipc` |
| IPC under `GetResourcePath()` | TwelveTake | fixed ASCII mailbox both sides derive |
| No heartbeat → hang until timeout | Anqi | `heartbeat` touched every defer tick, 5s stale |
| Two MCP clients stomp `request.json` | Anqi | OS file lock |
| MIDI edits missing from undo | common | `Undo_OnStateChange_Item` |
| Beats anchored at measure `-1` | old bridges | `TimeMap2_beatsToTime(0, b, 0)` |
| Mix-engine / FastMCP / style packs | xDarkzx | out of scope for the kernel |

Borrowed: Anqi handle registry + batch + stdlib MCP; xDarkzx heartbeat / mutex / WSL error; TwelveTake `create_bus` as **one** `track.action=bus`.

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

## Tools

`status` `transport` `track` `midi` `fx` `project` `render` `action` `reaper_call` `run_lua` `batch`

Time is **beats**. Indices are 0-based. Multi-step edits go through `batch`.

## Tests

```
python3 python/test_server.py
```

Fake bridge, no REAPER.

## License

MIT
