#!/bin/bash
set -euo pipefail
mkdir -p "$HOME/Library/Logs"
exec > >(tee -a "$HOME/Library/Logs/reaper-mcp-bootstrap.log") 2>&1
echo "=== reaper-mcp bootstrap $(date) ==="
echo "host=$(hostname) arch=$(uname -m) user=$(whoami)"

BIN="$HOME/.local/bin"
CFG="$HOME/.config/reaper-mcp"
LAUNCH="$HOME/Library/LaunchAgents"
LOGDIR="$HOME/Library/Logs"
REPO="$HOME/reaper-mcp"
mkdir -p "$BIN" "$CFG" "$LAUNCH" "$LOGDIR"
export PATH="$BIN:$HOME/.local/bin:$PATH"

if [ -f "$CFG/env" ]; then
  set -a
  # shellcheck disable=SC1090
  . "$CFG/env"
  set +a
fi

: "${REAPER_MCP_BEARER:?set REAPER_MCP_BEARER}"
: "${CLOUDFLARE_TUNNEL_TOKEN:?set CLOUDFLARE_TUNNEL_TOKEN}"
REAPER_MCP_PORT="${REAPER_MCP_PORT:-8787}"
REAPER_MCP_HOSTNAME="${REAPER_MCP_HOSTNAME:-reaper.yitian.wang}"

if ! command -v uv >/dev/null 2>&1; then
  echo "installing uv"
  curl -LsSf https://astral.sh/uv/install.sh | sh
  export PATH="$HOME/.local/bin:$PATH"
fi
command -v uv || true
uv --version || true

if [ ! -x "$BIN/cloudflared" ]; then
  echo "installing cloudflared"
  tmp=$(mktemp -d)
  ARCH=$(uname -m)
  if [ "$ARCH" = "arm64" ]; then
    raw="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-darwin-arm64"
    tgz="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-darwin-arm64.tgz"
  else
    raw="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-darwin-amd64"
    tgz="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-darwin-amd64.tgz"
  fi
  if curl -fL "$tgz" -o "$tmp/cf.tgz"; then
    tar -xzf "$tmp/cf.tgz" -C "$tmp"
    found=$(find "$tmp" -type f \( -name 'cloudflared' -o -name 'cloudflared-darwin-*' \) | head -1)
    cp "$found" "$BIN/cloudflared"
  else
    curl -fL "$raw" -o "$BIN/cloudflared"
  fi
  chmod +x "$BIN/cloudflared"
  rm -rf "$tmp"
fi
"$BIN/cloudflared" --version

if [ ! -d "$REPO/.git" ]; then
  git clone https://github.com/yiw190/reaper-mcp.git "$REPO"
else
  git -C "$REPO" pull --ff-only || true
fi

if [ ! -f "$REPO/python/http_server.py" ]; then
  echo "missing $REPO/python/http_server.py" >&2
  exit 1
fi
chmod +x "$REPO/python/http_server.py"

umask 077
cat > "$CFG/env" << ENVEOF
REAPER_MCP_BEARER=$REAPER_MCP_BEARER
REAPER_MCP_PORT=$REAPER_MCP_PORT
REAPER_MCP_HOSTNAME=$REAPER_MCP_HOSTNAME
CLOUDFLARE_TUNNEL_TOKEN=$CLOUDFLARE_TUNNEL_TOKEN
ENVEOF
chmod 600 "$CFG/env"

python3 - << PY
from pathlib import Path
home = Path.home()
repo = home / "reaper-mcp"
launch = home / "Library/LaunchAgents"
logdir = home / "Library/Logs"
cfg = home / ".config/reaper-mcp/env"
vals = {}
for line in cfg.read_text().splitlines():
    if "=" in line and not line.startswith("#"):
        k, v = line.split("=", 1)
        vals[k] = v

def plist(label, args, env, logfile):
    env_xml = "\n".join(f"    <key>{k}</key><string>{v}</string>" for k, v in env.items())
    args_xml = "\n".join(f"    <string>{a}</string>" for a in args)
    env_block = ""
    if env:
        env_block = "  <key>EnvironmentVariables</key>\n  <dict>\n" + env_xml + "\n  </dict>\n"
    return f"""<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>{label}</string>
  <key>ProgramArguments</key>
  <array>
{args_xml}
  </array>
  <key>WorkingDirectory</key><string>{repo}</string>
{env_block}  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>{logfile}.log</string>
  <key>StandardErrorPath</key><string>{logfile}.err</string>
</dict>
</plist>
"""

(launch / "com.yitian.reaper-mcp.plist").write_text(plist(
    "com.yitian.reaper-mcp",
    ["/usr/bin/python3", str(repo / "python/http_server.py")],
    {"REAPER_MCP_BEARER": vals["REAPER_MCP_BEARER"], "REAPER_MCP_PORT": vals["REAPER_MCP_PORT"]},
    str(logdir / "reaper-mcp-http"),
))
(launch / "com.yitian.cloudflared-reaper.plist").write_text(plist(
    "com.yitian.cloudflared-reaper",
    [str(home / ".local/bin/cloudflared"), "tunnel", "run", "--token", vals["CLOUDFLARE_TUNNEL_TOKEN"]],
    {},
    str(logdir / "cloudflared-reaper"),
))
print("wrote launch agents")
PY

uid=$(id -u)
launchctl bootout "gui/$uid/com.yitian.reaper-mcp" 2>/dev/null || true
launchctl bootout "gui/$uid/com.yitian.cloudflared-reaper" 2>/dev/null || true
launchctl bootstrap "gui/$uid" "$LAUNCH/com.yitian.reaper-mcp.plist"
launchctl bootstrap "gui/$uid" "$LAUNCH/com.yitian.cloudflared-reaper.plist"
launchctl kickstart -k "gui/$uid/com.yitian.reaper-mcp"
launchctl kickstart -k "gui/$uid/com.yitian.cloudflared-reaper"
sleep 3
echo "--- healthz ---"
curl -sS -i "http://127.0.0.1:${REAPER_MCP_PORT}/healthz" | head -20 || true

REAPER_SCRIPTS="$HOME/Library/Application Support/REAPER/Scripts"
if [ -d "/Applications/REAPER.app" ] || [ -d "$HOME/Applications/REAPER.app" ] || [ -d "$HOME/Library/Application Support/REAPER" ]; then
  mkdir -p "$REAPER_SCRIPTS"
  if ! python3 "$REPO/python/install_bridge.py"; then
    cp "$REPO/lua/bridge.lua" "$REAPER_SCRIPTS/reaper_mcp_bridge.lua"
  fi
  echo "bridge ready"
else
  echo "REAPER app not found"
  ls /Applications 2>/dev/null | head -50 || true
fi

echo "=== bootstrap done $(date) ==="
