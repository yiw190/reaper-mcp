#!/usr/bin/env python3
"""reaper-mcp — stdio MCP server. Zero third-party deps.

Talks to lua/bridge.lua over a JSON mailbox. Prefer a handful of grouped
tools plus batch / run_lua instead of dumping the whole ReaScript API.
"""

from __future__ import annotations

import json
import os
import sys
import time
import uuid

if sys.platform == "win32":
    import msvcrt
else:
    import fcntl

PROTOCOL_VERSION = "2024-11-05"
SERVER_NAME = "reaper-mcp"
SERVER_VERSION = "0.1.0"
HEARTBEAT_STALE = 5.0
POLL = 0.015
RENDER_TIMEOUT = float(os.environ.get("REAPER_MCP_RENDER_TIMEOUT", "300"))

INSTRUCTIONS = (
    "Drive REAPER. Time is beats (quarter notes), track/item indices are 0-based. "
    "Call status first. Prefer batch for multi-step edits. "
    "Use run_lua or reaper_call only for APIs not covered by the grouped tools."
)


def default_ipc_dir() -> str:
    env = os.environ.get("REAPER_MCP_IPC_DIR")
    if env:
        return env
    if os.environ.get("APPDATA"):
        return os.path.join(os.environ["APPDATA"], "reaper-mcp", "ipc")
    if sys.platform == "darwin":
        return os.path.expanduser("~/Library/Application Support/reaper-mcp/ipc")
    xdg = os.environ.get("XDG_DATA_HOME") or os.path.expanduser("~/.local/share")
    return os.path.join(xdg, "reaper-mcp", "ipc")


def _is_wsl() -> bool:
    if sys.platform != "linux":
        return False
    if os.environ.get("WSL_DISTRO_NAME") or os.environ.get("WSL_INTEROP"):
        return True
    try:
        with open("/proc/version", encoding="utf-8") as f:
            return "microsoft" in f.read().lower()
    except OSError:
        return False


class BridgeError(Exception):
    pass


class Bridge:
    def __init__(self) -> None:
        self.dir = default_ipc_dir()
        self.req = os.path.join(self.dir, "request.json")
        self.resp = os.path.join(self.dir, "response.json")
        self.heart = os.path.join(self.dir, "heartbeat")
        self.mutex = os.path.join(self.dir, "ipc.mutex")
        self.timeout = float(os.environ.get("REAPER_MCP_TIMEOUT", "10"))
        os.makedirs(self.dir, exist_ok=True)

    def _heartbeat_ok(self) -> bool:
        try:
            return (time.time() - os.path.getmtime(self.heart)) < HEARTBEAT_STALE
        except OSError:
            return False

    def _refuse(self) -> None:
        if _is_wsl():
            raise BridgeError(
                "REAPER bridge not seen. This Python is inside WSL; REAPER is a "
                "native Windows app and they do not share this IPC directory "
                f"({self.dir}). Run the MCP server with Windows Python, or set "
                "REAPER_MCP_IPC_DIR to a path both sides can see (e.g. /mnt/c/...)."
            )
        raise BridgeError(
            "REAPER bridge not running or heartbeat stale. In REAPER: Actions > "
            "Load ReaScript > lua/bridge.lua > Run."
        )

    def _lock(self, timeout: float):
        os.makedirs(self.dir, exist_ok=True)
        fd = open(self.mutex, "a+b")
        deadline = time.monotonic() + timeout
        try:
            while True:
                try:
                    if sys.platform == "win32":
                        fd.seek(0, os.SEEK_END)
                        if fd.tell() == 0:
                            fd.write(b"\0")
                            fd.flush()
                        fd.seek(0)
                        msvcrt.locking(fd.fileno(), msvcrt.LK_NBLCK, 1)
                    else:
                        fcntl.flock(fd.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
                    break
                except OSError:
                    if time.monotonic() >= deadline:
                        fd.close()
                        raise BridgeError(
                            "Timed out waiting for another reaper-mcp client to finish."
                        )
                    time.sleep(POLL)
            return fd
        except Exception:
            fd.close()
            raise

    def _unlock(self, fd) -> None:
        try:
            if sys.platform == "win32":
                fd.seek(0)
                msvcrt.locking(fd.fileno(), msvcrt.LK_UNLCK, 1)
            else:
                fcntl.flock(fd.fileno(), fcntl.LOCK_UN)
        except OSError:
            pass
        fd.close()

    def call(self, func: str, args=None, code: str | None = None, timeout: float | None = None):
        wait = timeout if timeout is not None else self.timeout
        fd = self._lock(wait)
        try:
            if not self._heartbeat_ok():
                self._refuse()
            rid = uuid.uuid4().hex[:12]
            payload = {"id": rid, "func": func}
            if code is not None:
                payload["code"] = code
            else:
                payload["args"] = args or []
            try:
                os.remove(self.resp)
            except OSError:
                pass
            tmp = self.req + ".tmp"
            with open(tmp, "w", encoding="utf-8") as f:
                json.dump(payload, f)
            os.replace(tmp, self.req)

            deadline = time.time() + wait
            while time.time() < deadline:
                if not self._heartbeat_ok():
                    self._refuse()
                if os.path.exists(self.resp):
                    try:
                        with open(self.resp, encoding="utf-8") as f:
                            data = json.loads(f.read())
                    except (OSError, ValueError):
                        time.sleep(POLL)
                        continue
                    if data.get("id") not in (rid, None):
                        time.sleep(POLL)
                        continue
                    try:
                        os.remove(self.resp)
                    except OSError:
                        pass
                    if not data.get("ok", False):
                        raise BridgeError(data.get("error", "unknown bridge error"))
                    return data.get("ret")
                time.sleep(POLL)
            raise BridgeError(
                "Timed out waiting for REAPER. Is lua/bridge.lua running?"
            )
        finally:
            self._unlock(fd)


TOOLS = []


def tool(name, description, schema, builder):
    TOOLS.append({
        "name": name,
        "description": description,
        "inputSchema": schema,
        "_builder": builder,
    })


def obj(props, required=None):
    return {
        "type": "object",
        "properties": props,
        "required": required or [],
        "additionalProperties": False,
    }


def _props(a, keys):
    return {k: a[k] for k in keys if k in a}


NOTE = {
    "type": "object",
    "properties": {
        "pitch": {"type": "integer", "minimum": 0, "maximum": 127},
        "start_beats": {"type": "number"},
        "length_beats": {"type": "number"},
        "velocity": {"type": "integer", "minimum": 1, "maximum": 127},
        "channel": {"type": "integer", "minimum": 0, "maximum": 15},
        "muted": {"type": "boolean"},
    },
    "required": ["pitch", "start_beats"],
}


tool(
    "status",
    "Check the Lua bridge and return project tempo, play state, and tracks. Call first.",
    obj({}),
    lambda b, a: b.call("get_project_summary"),
)

tool(
    "transport",
    "Playback control. action: play, stop, pause, record, toggle_repeat, goto_start.",
    obj({"action": {"type": "string",
                    "enum": ["play", "stop", "pause", "record",
                             "toggle_repeat", "goto_start"]}},
        ["action"]),
    lambda b, a: b.call("transport", [a["action"]]),
)

tool(
    "track",
    "Track operations. action: list | add | delete | update | bus. "
    "update uses name, volume_db, pan (-1..1), mute, solo. "
    "bus creates a submix named `name` and routes source_indices to it.",
    obj({
        "action": {"type": "string", "enum": ["list", "add", "delete", "update", "bus"]},
        "index": {"type": "integer", "minimum": 0},
        "name": {"type": "string"},
        "volume_db": {"type": "number"},
        "pan": {"type": "number", "minimum": -1, "maximum": 1},
        "mute": {"type": "boolean"},
        "solo": {"type": "boolean"},
        "source_indices": {"type": "array", "items": {"type": "integer", "minimum": 0}},
    }, ["action"]),
    lambda b, a: {
        "list": lambda: b.call("list_tracks"),
        "add": lambda: b.call("add_track", [a.get("name"), a.get("index")]),
        "delete": lambda: b.call("delete_track", [a["index"]]),
        "update": lambda: b.call("update_track", [a["index"], _props(
            a, ("name", "volume_db", "pan", "mute", "solo"))]),
        "bus": lambda: b.call("create_bus", [a.get("name"), a.get("source_indices") or []]),
    }[a["action"]](),
)

tool(
    "midi",
    "MIDI on a track item. Times are absolute project beats. "
    "action: create_item | add | get | replace | update | delete. "
    "replace rewrites the whole take in one undo step; add only appends.",
    obj({
        "action": {"type": "string",
                   "enum": ["create_item", "add", "get", "replace", "update", "delete"]},
        "track_index": {"type": "integer", "minimum": 0},
        "item_index": {"type": "integer", "minimum": 0},
        "start_beats": {"type": "number", "minimum": 0},
        "length_beats": {"type": "number", "minimum": 0},
        "notes": {"type": "array", "items": NOTE},
        "note_index": {"type": "integer", "minimum": 0},
        "note_indices": {"type": "array", "items": {"type": "integer", "minimum": 0}},
        "pitch": {"type": "integer", "minimum": 0, "maximum": 127},
        "velocity": {"type": "integer", "minimum": 1, "maximum": 127},
        "channel": {"type": "integer", "minimum": 0, "maximum": 15},
        "muted": {"type": "boolean"},
    }, ["action", "track_index"]),
    lambda b, a: {
        "create_item": lambda: b.call("create_midi_item", [
            a["track_index"], a.get("start_beats", 0), a.get("length_beats", 4)]),
        "add": lambda: b.call("add_midi_notes",
                              [a["track_index"], a["item_index"], a["notes"]]),
        "get": lambda: b.call("get_midi_notes", [a["track_index"], a["item_index"]]),
        "replace": lambda: b.call("replace_midi_notes",
                                  [a["track_index"], a["item_index"], a["notes"]]),
        "update": lambda: b.call("update_midi_note", [
            a["track_index"], a["item_index"], a["note_index"],
            _props(a, ("pitch", "start_beats", "length_beats",
                       "velocity", "channel", "muted"))]),
        "delete": lambda: b.call("delete_midi_notes",
                                 [a["track_index"], a["item_index"], a["note_indices"]]),
    }[a["action"]](),
)

tool(
    "fx",
    "Track FX. action: list | add | params | set. "
    "set accepts param as index or name, value 0..1 (REAPER normalized).",
    obj({
        "action": {"type": "string", "enum": ["list", "add", "params", "set"]},
        "track_index": {"type": "integer", "minimum": 0},
        "fx_index": {"type": "integer", "minimum": 0},
        "fx_name": {"type": "string"},
        "param": {"type": ["string", "integer"]},
        "value": {"type": "number"},
    }, ["action", "track_index"]),
    lambda b, a: {
        "list": lambda: b.call("list_track_fx", [a["track_index"]]),
        "add": lambda: b.call("add_track_fx", [a["track_index"], a["fx_name"]]),
        "params": lambda: b.call("get_fx_params", [a["track_index"], a["fx_index"]]),
        "set": lambda: b.call("set_fx_param",
                              [a["track_index"], a["fx_index"], a["param"], a["value"]]),
    }[a["action"]](),
)

tool(
    "project",
    "Project-level edits. action: tempo | time_signature | time_selection | marker.",
    obj({
        "action": {"type": "string",
                   "enum": ["tempo", "time_signature", "time_selection", "marker"]},
        "bpm": {"type": "number", "minimum": 1},
        "numerator": {"type": "integer", "minimum": 1},
        "denominator": {"type": "integer", "minimum": 1},
        "start_beats": {"type": "number", "minimum": 0},
        "end_beats": {"type": "number", "minimum": 0},
        "position_beats": {"type": "number", "minimum": 0},
        "name": {"type": "string"},
        "is_region": {"type": "boolean"},
        "region_end_beats": {"type": "number", "minimum": 0},
    }, ["action"]),
    lambda b, a: {
        "tempo": lambda: b.call("set_tempo", [a["bpm"]]),
        "time_signature": lambda: b.call("set_time_signature",
                                         [a["numerator"], a["denominator"]]),
        "time_selection": lambda: b.call("set_time_selection",
                                         [a["start_beats"], a["end_beats"]]),
        "marker": lambda: b.call("add_marker", [
            a["position_beats"], a.get("name", ""), a.get("is_region", False),
            a.get("region_end_beats")]),
    }[a["action"]](),
)

tool(
    "render",
    "Render with the project's last render settings. Optional path overwrite. "
    "No undo. Long timeout.",
    obj({"path": {"type": "string"}}),
    lambda b, a: b.call("render_project", [a.get("path")], timeout=RENDER_TIMEOUT),
)

tool(
    "action",
    "Run a REAPER Main_OnCommand by numeric command id.",
    obj({"command_id": {"type": "integer"}}, ["command_id"]),
    lambda b, a: b.call("action", [a["command_id"]]),
)

tool(
    "reaper_call",
    "Call any ReaScript function by name. Pointers come back as {\"__handle\":\"hN\"} "
    "and can be passed back in. Example: func=CountTracks args=[0].",
    obj({"func": {"type": "string"}, "args": {"type": "array"}}, ["func"]),
    lambda b, a: b.call(a["func"], a.get("args", [])),
)

tool(
    "run_lua",
    "Run a Lua snippet inside REAPER (`reaper` in scope). Use return to send a value. "
    "Best for multi-step work that would otherwise be many round-trips.",
    obj({"code": {"type": "string"}}, ["code"]),
    lambda b, a: b.call("run_lua", code=a["code"]),
)

tool(
    "batch",
    "Many operations in one IPC hop. Each call is {func, args} or {func, code} "
    "or {func, arguments} for a grouped tool name (track/midi/fx/...). "
    "One failure does not abort the rest. Handles from earlier calls work later.",
    obj({"calls": {"type": "array", "items": obj({
        "func": {"type": "string"},
        "args": {"type": "array"},
        "arguments": {"type": "object"},
        "code": {"type": "string"},
        "action": {"type": "string"}},
        ["func"])}},
        ["calls"]),
    lambda b, a: b.call("batch", [_normalize_batch(a["calls"])]),
)


def _expand_grouped(func, arguments):
    """Turn a grouped MCP tool invocation into a DSL/bridge call."""
    spec = TOOL_INDEX.get(func)
    if spec is None or func in ("batch", "reaper_call", "run_lua"):
        return None
    capture = _BatchCapture()
    return spec["_builder"](capture, arguments)


class _BatchCapture:
    def call(self, func, args=None, code=None, timeout=None):
        del timeout
        call = {"func": func}
        if code is not None:
            call["code"] = code
        else:
            call["args"] = args or []
        return call


def _normalize_batch(calls):
    out = []
    for original in calls:
        call = dict(original)
        func = call.get("func")
        arguments = call.get("arguments")
        if arguments is None and "action" in call:
            arguments = {k: v for k, v in call.items() if k != "func"}
        expanded = None
        if isinstance(arguments, dict):
            expanded = _expand_grouped(func, arguments)
        if expanded is not None:
            out.append(expanded)
        else:
            out.append(call)
    return out


TOOL_INDEX = {t["name"]: t for t in TOOLS}


def make_result(rid, result):
    return {"jsonrpc": "2.0", "id": rid, "result": result}


def make_error(rid, code, message):
    return {"jsonrpc": "2.0", "id": rid, "error": {"code": code, "message": message}}


def handle_request(bridge, msg):
    method = msg.get("method")
    rid = msg.get("id")
    params = msg.get("params") or {}

    if method == "initialize":
        return make_result(rid, {
            "protocolVersion": PROTOCOL_VERSION,
            "capabilities": {"tools": {}},
            "serverInfo": {"name": SERVER_NAME, "version": SERVER_VERSION},
            "instructions": INSTRUCTIONS,
        })
    if method == "ping":
        return make_result(rid, {})
    if method in ("notifications/initialized", "notifications/cancelled"):
        return None
    if method == "tools/list":
        return make_result(rid, {
            "tools": [{"name": t["name"], "description": t["description"],
                       "inputSchema": t["inputSchema"]} for t in TOOLS],
        })
    if method == "resources/list":
        return make_result(rid, {"resources": []})
    if method == "prompts/list":
        return make_result(rid, {"prompts": []})
    if method == "tools/call":
        name = params.get("name")
        args = params.get("arguments") or {}
        spec = TOOL_INDEX.get(name)
        if not spec:
            return make_error(rid, -32602, f"unknown tool: {name}")
        try:
            ret = spec["_builder"](bridge, args)
            text = json.dumps(ret, ensure_ascii=False, indent=2) if not isinstance(ret, str) else ret
            return make_result(rid, {
                "content": [{"type": "text", "text": text}],
                "isError": False,
            })
        except BridgeError as e:
            return make_result(rid, {
                "content": [{"type": "text", "text": f"REAPER error: {e}"}],
                "isError": True,
            })
        except Exception as e:  # noqa: BLE001
            return make_result(rid, {
                "content": [{"type": "text", "text": f"Server error: {e}"}],
                "isError": True,
            })
    if rid is None:
        return None
    return make_error(rid, -32601, f"method not found: {method}")


def main():
    for stream in (sys.stdin, sys.stdout):
        try:
            stream.reconfigure(encoding="utf-8", newline="\n")
        except (AttributeError, ValueError):
            pass
    bridge = Bridge()
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            msg = json.loads(line)
        except ValueError:
            continue
        try:
            response = handle_request(bridge, msg)
        except Exception as e:  # noqa: BLE001
            response = make_error(msg.get("id"), -32603, f"internal error: {e}")
        if response is not None:
            sys.stdout.write(json.dumps(response, ensure_ascii=False) + "\n")
            sys.stdout.flush()


if __name__ == "__main__":
    main()
