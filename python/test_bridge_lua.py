#!/usr/bin/env python3
"""Headless tests for lua/bridge.lua, driven through the real mailbox.

Loads the bridge into a Lua interpreter with a fake ReaScript API
(python/fake_reaper.lua), then sends requests exactly like server.py does.

Needs lupa; skips cleanly when it is absent so a bare CI job still passes.

    uv run --with lupa python python/test_bridge_lua.py
"""

from __future__ import annotations

import json
import os
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BRIDGE = ROOT / "lua" / "bridge.lua"
FAKE = Path(__file__).resolve().parent / "fake_reaper.lua"

PPQ = 960.0

# Lua 5.1 (LuaJIT, what lupa ships) versus the 5.3+ the bridge targets.
COMPAT = """
if not table.pack then
  table.pack = function(...) return {n = select('#', ...), ...} end
end
if not table.unpack then table.unpack = unpack end
local _load = load
load = function(chunk, name, mode, env)
  local f, err = _load(chunk, name)
  if not f then return f, err end
  if env and setfenv then setfenv(f, env) end
  return f
end
"""


def main() -> None:
    try:
        import lupa
    except ImportError:
        print("SKIP  install lupa: uv run --with lupa python python/test_bridge_lua.py")
        return

    ipc_dir = tempfile.mkdtemp(prefix="reaper_lua_")
    os.environ["REAPER_MCP_IPC_DIR"] = ipc_dir
    req = os.path.join(ipc_dir, "request.json")
    resp = os.path.join(ipc_dir, "response.json")

    lua = lupa.LuaRuntime()
    lua.execute(COMPAT)
    lua.execute(FAKE.read_text(encoding="utf-8"))
    lua.execute(BRIDGE.read_text(encoding="utf-8"))

    g = lua.globals()
    failures = []

    def count(name) -> int:
        v = g.calls[name]
        return 0 if v is None else int(v)

    def clear():
        lua.execute("calls = {}")

    def rpc(func, args=None, code=None):
        payload = {"id": "t", "func": func}
        if code is not None:
            payload["code"] = code
        else:
            payload["args"] = args or []
        with open(req, "w", encoding="utf-8") as f:
            json.dump(payload, f)
        g.pump(1)
        for _ in range(300):
            if os.path.exists(resp):
                break
            g.pump(1)
        with open(resp, encoding="utf-8") as f:
            return json.loads(f.read())

    def check(label, cond, extra=""):
        print(("  PASS" if cond else "  FAIL"), label, "" if cond else extra)
        if not cond:
            failures.append(label)

    def seeded_track(index=0):
        """A track with one MIDI item holding one muted note."""
        lua.execute(f"""
            if not tracks[{index + 1}] then
              tracks[{index + 1}] = new_track("T{index}")
            end
            tracks[{index + 1}].items[1] = new_item(0.0, 2.0)
            tracks[{index + 1}].items[1].notes = {{
              {{sel = false, muted = true, sppq = 0.0, eppq = {PPQ},
                chan = 0, pitch = 60, vel = 96}},
            }}
        """)
        return g.tracks

    # --- baseline ----------------------------------------------------
    check("bridge loaded", rpc("ping").get("ok") is True)
    r = rpc("add_track", ["Solo", 0])
    check("add_track", r.get("ok") and r["ret"]["index"] == 0, r)
    check("one refresh per single call",
          count("UpdateArrange") == 1 and count("TrackList_AdjustWindows") == 1,
          f"arrange={count('UpdateArrange')} tracks={count('TrackList_AdjustWindows')}")

    # --- batch coalesces refresh ------------------------------------
    clear()
    r = rpc("batch", [[
        {"func": "add_track", "args": ["A", 1]},
        {"func": "add_track", "args": ["B", 2]},
        {"func": "update_track", "args": [0, {"volume_db": -3}]},
        {"func": "update_track", "args": [1, {"mute": True}]},
    ]])
    check("batch ok", r.get("ok"), r)
    check("batch refreshes arrange once",
          count("UpdateArrange") == 1, f"arrange={count('UpdateArrange')}")
    check("batch refreshes track layout once",
          count("TrackList_AdjustWindows") == 1, f"tracks={count('TrackList_AdjustWindows')}")

    # --- refresh state is released after the batch -------------------
    clear()
    r = rpc("update_track", [0, {"volume_db": -1}])
    check("refresh works after a batch",
          r.get("ok") and count("UpdateArrange") == 1, f"arrange={count('UpdateArrange')}")

    # --- MIDI note update -------------------------------------------
    seeded_track(0)
    clear()
    r = rpc("update_midi_note", [0, 0, 0, {"pitch": 62}])
    check("update_midi_note ok", r.get("ok"), r)
    check("update_midi_note sorts once", count("MIDI_Sort") == 1, f"sort={count('MIDI_Sort')}")
    check("update_midi_note asks the API not to sort",
          count("MIDI_SetNote.noSort") == 1 and count("MIDI_SetNote.sorted") == 0,
          f"noSort={count('MIDI_SetNote.noSort')} sorted={count('MIDI_SetNote.sorted')}")

    # lupa's LuaTable shadows Lua fields named like dict methods (items, keys),
    # so index with [] rather than attribute access.
    def note0():
        return g.tracks[1]["items"][1]["notes"][1]

    r = rpc("update_midi_note", [0, 0, 0, {"muted": False}])
    n = note0()
    check("update_midi_note can unmute", r.get("ok") and n["muted"] is False, dict(n))

    r = rpc("update_midi_note", [0, 0, 0, {"start_beats": 2.0}])
    n = note0()
    moved = abs(float(n["sppq"]) - 2.0 * PPQ) < 1e-6
    kept = abs(float(n["eppq"]) - float(n["sppq"]) - PPQ) < 1e-6
    check("moved note keeps its length", r.get("ok") and moved and kept, dict(n))

    # --- item index without a scan -----------------------------------
    clear()
    before = count("GetTrackMediaItem")
    r = rpc("create_midi_item", [0, 0.0, 4.0])
    check("create_midi_item index correct",
          r["ret"]["item_index"] == len(g.tracks[1]["items"]) - 1, r)
    check("create_midi_item does not scan items",
          count("GetTrackMediaItem") - before <= 1,
          f"lookups={count('GetTrackMediaItem') - before}")

    # --- list_items property reads -----------------------------------
    clear()
    n_items = len(g.tracks[1]["items"])
    rpc("list_items", [0])
    reads = sum(count(f"item.{k}") for k in ("D_POSITION", "D_LENGTH", "D_VOL"))
    check("list_items reads 3 properties per item",
          r.get("ok") and reads == 3 * n_items, f"reads={reads} items={n_items}")

    # --- read-only ops skip undo block --------------------------------
    clear()
    r = rpc("batch", [[
        {"func": "list_items", "args": [0]},
        {"func": "list_sends", "args": [0]},
        {"func": "list_envelopes", "args": [0]},
        {"func": "list_tracks", "args": []},
        {"func": "get_envelope", "args": [0, 0]},
    ]])
    check("read-only batch runs", r.get("ok"), r)
    check("read-only batch skips undo blocks",
          count("Undo_BeginBlock") == 0, f"undo={count('Undo_BeginBlock')}")

    # --- mutating ops keep their undo block ---------------------------
    clear()
    rpc("update_track", [0, {"volume_db": -2}])
    check("mutating op keeps its undo block", count("Undo_BeginBlock") == 1)

    # --- idle heartbeat throttle --------------------------------------
    clear()
    g.pump(60)  # one second of idle ticks
    writes = count("heartbeat_writes")
    check("idle heartbeat writes throttled", 1 <= writes <= 3, f"writes={writes}")

    # --- the bridge is still responsive -------------------------------
    r = rpc("ping")
    check("bridge still responsive", r.get("ok") and r["ret"]["pong"] is True, r)

    if failures:
        print("FAILED", failures)
        sys.exit(1)
    print("all passed")


if __name__ == "__main__":
    main()
