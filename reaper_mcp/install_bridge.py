#!/usr/bin/env python3
"""Copy lua/bridge.lua into REAPER's Scripts folder."""

from __future__ import annotations

import os
import shutil
import sys
from pathlib import Path


def repo_bridge() -> Path:
    here = Path(__file__).resolve()
    candidates = [
        here.parents[1] / "lua" / "bridge.lua",
        here.parent / "bridge.lua",
    ]
    for p in candidates:
        if p.is_file():
            return p
    raise SystemExit("bridge.lua not found")


def scripts_dir() -> Path:
    override = os.environ.get("REAPER_RESOURCE_PATH")
    if override:
        return Path(override) / "Scripts"
    if sys.platform == "win32":
        appdata = os.environ.get("APPDATA")
        if not appdata:
            raise SystemExit("APPDATA is not set")
        return Path(appdata) / "REAPER" / "Scripts"
    if sys.platform == "darwin":
        return Path.home() / "Library" / "Application Support" / "REAPER" / "Scripts"
    return Path.home() / ".config" / "REAPER" / "Scripts"


def main() -> None:
    src = repo_bridge()
    dest_dir = scripts_dir()
    dest_dir.mkdir(parents=True, exist_ok=True)
    dest = dest_dir / "reaper_mcp_bridge.lua"
    if dest.exists():
        bak = dest.with_suffix(".lua.bak")
        shutil.copy2(dest, bak)
        print(f"backed up existing script to {bak}")
    shutil.copy2(src, dest)
    print(f"installed {dest}")
    print("In REAPER: Actions > Show action list > Load ReaScript >")
    print(f"  {dest}")
    print("then Run it and leave it running.")


if __name__ == "__main__":
    main()
