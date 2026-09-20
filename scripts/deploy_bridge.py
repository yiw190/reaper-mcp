#!/usr/bin/env python3
"""Push lua/bridge.lua to a running REAPER bridge and restart it in place.

The bridge is a deferred ReaScript, so replacing the file is not enough: the
running instance has to be swapped too. This stages a copy, then performs a
handoff -- patch `reaper.defer` so the old tick chain ends, and load the new
file on a timer so the request that triggered the swap still gets answered.

    python3 scripts/deploy_bridge.py stage    # write files, verify hashes
    python3 scripts/deploy_bridge.py swap     # back up live, hand off
    python3 scripts/deploy_bridge.py verify   # confirm which build is live

Needs REAPER_MCP_HOSTNAME / REAPER_MCP_BEARER (or -H / -T).
"""

from __future__ import annotations

import argparse
import base64
import json
import os
import sys
import urllib.error
import urllib.request
import zlib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "lua" / "bridge.lua"

LIVE = "~/Library/Application Support/REAPER/Scripts/reaper_mcp_bridge.lua"
REPO = "~/reaper-mcp"
# local source -> where it has to land on the host
FILES = [
    ("lua/bridge.lua", [LIVE + ".new", f"{REPO}/lua/bridge.lua", f"{REPO}/reaper_mcp/bridge.lua"]),
    ("reaper_mcp/server.py", [f"{REPO}/reaper_mcp/server.py"]),
]
LAUNCH_LABEL = "com.yitian.reaper-mcp"

# Seconds to keep the old process alive while Python reads the swap response.
HANDOFF_TICKS = 30


def rpc(hostname: str, bearer: str, code: str) -> dict:
    body = json.dumps({
        "jsonrpc": "2.0", "id": 1, "method": "tools/call",
        "params": {"name": "run_lua", "arguments": {"code": code}},
    }).encode()
    req = urllib.request.Request(
        f"https://{hostname}/mcp", body,
        {"Authorization": f"Bearer {bearer}", "Content-Type": "application/json",
         "Accept": "application/json, text/event-stream",
         "User-Agent": "reaper-mcp-deploy/1.0"},
    )
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            payload = json.load(r)
    except urllib.error.HTTPError as e:
        raise SystemExit(f"HTTP {e.code}: {e.read(200).decode(errors='replace')}")
    if "error" in payload:
        raise SystemExit(f"rpc error: {payload['error']}")
    result = payload["result"]
    content = result["content"][0]["text"]
    if result.get("isError"):
        raise SystemExit(f"lua error: {content}")
    try:
        return json.loads(content)
    except ValueError:
        raise SystemExit(f"unexpected result: {content[:2000]}")


def adler32(data: bytes) -> str:
    return format(zlib.adler32(data), "08x")


DECODER = r"""
local B="ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local lut={}
for i=1,#B do lut[B:sub(i,i)]=i-1 end
local function b64(s)
  local out, acc, n = {}, 0, 0
  for i=1,#s do
    local c=s:sub(i,i)
    if c~="=" and lut[c] then
      acc = acc*64 + lut[c]
      n = n + 1
      if n==4 then
        out[#out+1]=string.char(math.floor(acc/65536)%256, math.floor(acc/256)%256, acc%256)
        acc, n = 0, 0
      end
    end
  end
  if n==2 then out[#out+1]=string.char(math.floor(acc/16)%256)
  elseif n==3 then
    acc = acc*64
    out[#out+1]=string.char(math.floor(acc/65536)%256, math.floor(acc/256)%256)
  end
  return table.concat(out)
end
local function adler(s)
  local a,b=1,0
  for i=1,#s do a=(a+s:byte(i))%65521; b=(b+a)%65521 end
  return string.format("%08x", b*65536+a)
end
local function expand(p) return p:gsub("^~", os.getenv("HOME")) end
local function write(p, data)
  p = expand(p)
  reaper.RecursiveCreateDirectory(p:match("^(.*)/[^/]*$") or ".", 0)
  local f = io.open(p,"wb")
  if not f then return { path=p, error="cannot write" } end
  f:write(data) f:close()
  local g = io.open(p,"rb") local back = g and g:read("*a") or ""
  if g then g:close() end
  return { path=p, bytes=#back, adler32=adler(back), ok=(back==data) }
end
"""


def stage(host: str, bearer: str) -> int:
    ok = True
    for local, targets in FILES:
        raw = (ROOT / local).read_bytes()
        payload = base64.b64encode(raw).decode()
        code = DECODER + f"""
local data = b64("{payload}")
local out = {{}}
local targets = {{ {", ".join(json.dumps(t) for t in targets)} }}
for _, p in ipairs(targets) do out[#out+1] = write(p, data) end
return {{ ret = {{ source = {{ bytes = {len(raw)}, adler32 = "{adler32(raw)}" }}, written = out }} }}
"""
        res = rpc(host, bearer, code)["ret"]
        print(f"{local}: {res['source']['bytes']} bytes {res['source']['adler32']}")
        for w in res["written"]:
            hit = w.get("ok") and w.get("adler32") == res["source"]["adler32"]
            ok = ok and hit
            print(("  ok  " if hit else "  BAD "), w.get("path"), w.get("error", ""))
    return 0 if ok else 1


def swap(host: str, bearer: str) -> int:
    live = json.dumps(LIVE)
    stage_path = json.dumps(LIVE + ".new")
    code = f"""
local real = reaper.defer
local noop = function() end
reaper.defer = noop
if reaper.defer ~= noop then
  reaper.defer = real
  return {{ ret = {{ swapped = false, error = "reaper.defer is not patchable" }} }}
end
local function expand(p) return p:gsub("^~", os.getenv("HOME")) end
local live, stage = expand({live}), expand({stage_path})
-- back up the running script first
local src = io.open(live, "rb")
if src then
  local cur = src:read("*a"); src:close()
  local b = io.open(live .. ".bak", "wb")
  if b then b:write(cur) b:close() end
end
local s = io.open(stage, "rb")
if not s then reaper.defer = real return {{ ret = {{ swapped = false, error = "no staged file" }} }} end
local data = s:read("*a"); s:close()
local o = io.open(live, "wb")
if not o then reaper.defer = real return {{ ret = {{ swapped = false, error = "cannot write live" }} }} end
o:write(data) o:close()
local countdown = {HANDOFF_TICKS}
local function waiter()
  countdown = countdown - 1
  if countdown > 0 then real(waiter) return end
  reaper.defer = real
  local chunk, cerr = loadfile(live)
  if not chunk then reaper.ShowConsoleMsg("reaper-mcp reload failed: " .. tostring(cerr) .. "\\n") return end
  local ok, e = pcall(chunk)
  if not ok then reaper.ShowConsoleMsg("reaper-mcp reload error: " .. tostring(e) .. "\\n") end
end
real(waiter)
return {{ ret = {{ swapped = true, bytes = #data, live = live }} }}
"""
    res = rpc(host, bearer, code)["ret"]
    print(res)
    return 0 if res.get("swapped") else 1


def verify(host: str, bearer: str) -> int:
    pairs = [(local, target) for local, targets in FILES for target in targets]
    want = [(local, t, adler32((ROOT / local).read_bytes())) for local, t in pairs]
    code = DECODER + """
local out = {}
for _, p in ipairs(%s) do
  local f = io.open(expand(p), "rb")
  if f then
    local s = f:read("*a") f:close()
    out[#out+1] = { path = p, bytes = #s, adler32 = adler(s) }
  else
    out[#out+1] = { path = p, missing = true }
  end
end
return { ret = out }
""" % ("{" + ", ".join(json.dumps(t) for _, t, _ in want) + "}")
    res = rpc(host, bearer, code)["ret"]
    ok = True
    for (local, target, digest), got in zip(want, res):
        hit = got.get("adler32") == digest
        ok = ok and hit
        print(("  ok  " if hit else "  BAD "), target, got.get("bytes"), got.get("adler32"), "want", digest)
    return 0 if ok else 1


def restart(host: str, bearer: str) -> int:
    """Bounce the HTTP front so it loads the new server.py."""
    code = f"""
local cmd = "nohup sh -c 'sleep 2; launchctl kickstart -k gui/$(id -u)/{LAUNCH_LABEL}' >/dev/null 2>&1 &"
reaper.ExecProcess(cmd, 5000)
return {{ ret = {{ scheduled = true }} }}
"""
    print(rpc(host, bearer, code)["ret"])


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("action", choices=["stage", "swap", "restart", "verify"])
    ap.add_argument("-H", "--hostname", default=os.environ.get("REAPER_MCP_HOSTNAME"))
    ap.add_argument("-T", "--bearer", default=os.environ.get("REAPER_MCP_BEARER"))
    a = ap.parse_args()
    if not a.hostname or not a.bearer:
        raise SystemExit("set REAPER_MCP_HOSTNAME and REAPER_MCP_BEARER")
    fn = {"stage": stage, "swap": swap, "restart": restart, "verify": verify}[a.action]
    sys.exit(fn(a.hostname, a.bearer) or 0)


if __name__ == "__main__":
    main()
