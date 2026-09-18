#!/usr/bin/env python3
"""Offline MCP + fake-bridge tests. No REAPER required."""

from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import threading
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
SERVER = os.path.join(HERE, "server.py")
BRIDGE = os.path.join(ROOT, "lua", "bridge.lua")


def fake_bridge(bridge_dir, stop):
    req = os.path.join(bridge_dir, "request.json")
    resp = os.path.join(bridge_dir, "response.json")
    heart = os.path.join(bridge_dir, "heartbeat")
    while not stop.is_set():
        with open(heart, "w", encoding="utf-8") as f:
            f.write(str(time.time()))
        if os.path.exists(req):
            try:
                with open(req, encoding="utf-8") as f:
                    payload = json.load(f)
                os.remove(req)
            except (OSError, ValueError):
                time.sleep(0.005)
                continue
            func = payload.get("func")
            if func == "get_project_summary":
                ret = {"project": "(unsaved)", "tempo_bpm": 120.0,
                       "track_count": 1,
                       "tracks": [{"index": 0, "name": "Drums"}]}
            elif func == "add_track":
                ret = {"index": payload["args"][1] or 0,
                       "name": payload["args"][0] or ""}
            elif func == "run_lua":
                ret = 1
            elif func == "batch":
                calls = payload["args"][0]
                ret = [{"ok": True, "ret": {"echo": c.get("func"), "args": c.get("args")}}
                       for c in calls]
            elif func == "CountTracks":
                ret = 3
            else:
                ret = {"echo": func, "args": payload.get("args")}
            out = {"id": payload.get("id"), "ok": True, "ret": ret}
            tmp = resp + ".tmp"
            with open(tmp, "w", encoding="utf-8") as f:
                json.dump(out, f)
            os.replace(tmp, resp)
        time.sleep(0.005)


def rpc(proc, msg):
    proc.stdin.write(json.dumps(msg) + "\n")
    proc.stdin.flush()
    if msg.get("id") is None:
        return None
    return json.loads(proc.stdout.readline())


def main():
    bridge_dir = tempfile.mkdtemp(prefix="reaper_ipc_")
    stop = threading.Event()
    threading.Thread(target=fake_bridge, args=(bridge_dir, stop), daemon=True).start()

    env = dict(os.environ, REAPER_MCP_IPC_DIR=bridge_dir, REAPER_MCP_TIMEOUT="5")
    proc = subprocess.Popen(
        [sys.executable, SERVER],
        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=sys.stderr,
        text=True, env=env, encoding="utf-8",
    )
    failures = []

    def check(label, cond):
        print(("  PASS" if cond else "  FAIL"), label)
        if not cond:
            failures.append(label)

    try:
        src = open(BRIDGE, encoding="utf-8").read()
        check("beats anchored at measure 0",
              "TimeMap2_beatsToTime(0, b, 0)" in src
              and "TimeMap2_beatsToTime(0, b, -1)" not in src)
        check("heartbeat file", "heartbeat" in src)
        check("MIDI undo uses OnStateChange_Item",
              "Undo_OnStateChange_Item" in src)
        check("APPDATA mailbox", "reaper-mcp" in src and "APPDATA" in src)

        r = rpc(proc, {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}})
        check("initialize", r["result"]["serverInfo"]["name"] == "reaper-mcp")
        check("instructions present", "beats" in r["result"].get("instructions", ""))
        rpc(proc, {"jsonrpc": "2.0", "method": "notifications/initialized"})

        r = rpc(proc, {"jsonrpc": "2.0", "id": 2, "method": "tools/list"})
        names = {t["name"] for t in r["result"]["tools"]}
        check("small tool surface", 8 <= len(names) <= 14)
        check("core tools", {"status", "track", "midi", "fx", "batch", "run_lua",
                             "reaper_call"} <= names)
        check("no 100-tool dump", "setup_sidechain_compression" not in names)
        print("       tools:", sorted(names), "count=", len(names))

        r = rpc(proc, {"jsonrpc": "2.0", "id": 3, "method": "tools/call",
                       "params": {"name": "status", "arguments": {}}})
        body = json.loads(r["result"]["content"][0]["text"])
        check("status via fake bridge", body["tracks"][0]["name"] == "Drums")

        r = rpc(proc, {"jsonrpc": "2.0", "id": 4, "method": "tools/call",
                       "params": {"name": "track",
                                  "arguments": {"action": "add", "name": "Bass"}}})
        body = json.loads(r["result"]["content"][0]["text"])
        check("grouped track add", body["name"] == "Bass")

        r = rpc(proc, {"jsonrpc": "2.0", "id": 5, "method": "tools/call",
                       "params": {"name": "reaper_call",
                                  "arguments": {"func": "CountTracks", "args": [0]}}})
        check("reaper_call", json.loads(r["result"]["content"][0]["text"]) == 3)

        r = rpc(proc, {"jsonrpc": "2.0", "id": 6, "method": "tools/call",
                       "params": {"name": "batch", "arguments": {
                           "calls": [
                               {"func": "track", "action": "add", "name": "Pad"},
                               {"func": "run_lua", "code": "return 1"},
                           ]}}})
        body = json.loads(r["result"]["content"][0]["text"])
        check("batch expands grouped tools",
              body[0]["ret"]["echo"] == "add_track")
        check("batch keeps run_lua", body[1]["ret"]["echo"] == "run_lua")

        r = rpc(proc, {"jsonrpc": "2.0", "id": 7, "method": "tools/call",
                       "params": {"name": "nope", "arguments": {}}})
        check("unknown tool errors", "error" in r)
    finally:
        stop.set()
        proc.kill()

    if failures:
        print("FAILED", failures)
        sys.exit(1)
    print("all passed")


if __name__ == "__main__":
    main()
