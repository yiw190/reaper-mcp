# reaper-mcp

<img src="icons/reaper-mcp.svg" alt="" width="96" height="96" align="left" hspace="12" vspace="4">

MCP server for [REAPER](https://reaper.fm).

[![ci](https://github.com/yiw190/reaper-mcp/actions/workflows/ci.yml/badge.svg)](https://github.com/yiw190/reaper-mcp/actions/workflows/ci.yml)

```
MCP client  --stdio JSON-RPC-->  python/server.py  --JSON mailbox-->  lua/bridge.lua (inside REAPER)
```

Fourteen grouped tools. Multi-step edits go through `batch`; anything else through `reaper_call` / `run_lua`. Track index `-1` is the master. Time is project quarter notes. `midi cc` is CC and program change; `item import` takes a path on the REAPER host; `project save` writes without a dialog (pass `path` if the project is unsaved). `midi get` omits default fields; `batch` slots are the inner result or `{error}`.

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

`status` `transport` `track` `midi` `fx` `send` `item` `envelope` `project` `render` `action` `reaper_call` `run_lua` `batch`

## Tests

```
python3 python/test_server.py                        # MCP server + fake bridge
uv run --with lupa python python/test_bridge_lua.py  # bridge.lua against a fake ReaScript API
```

Neither needs REAPER. The second one skips if lupa is not installed.

## License

MIT
