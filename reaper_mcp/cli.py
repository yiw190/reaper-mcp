from __future__ import annotations

import sys


def main() -> None:
    if "--install-bridge" in sys.argv:
        from reaper_mcp.install_bridge import main as install
        sys.argv = [sys.argv[0]]
        install()
        return
    from reaper_mcp.server import main as serve
    serve()


if __name__ == "__main__":
    main()
