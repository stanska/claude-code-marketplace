#!/usr/bin/env bash
# discover-mcps.sh
#
# Discover all installed MCP servers by reading .mcp.json config files from:
#   1. Current project root (if provided as $1, or pwd)
#   2. ~/.claude/.mcp.json (user-level MCPs)
#   3. ~/.claude/plugins/cache/*/.mcp.json (plugin-bundled MCPs)
#
# Output: one line per MCP server in the format:
#   <name>\t<source-path>\t<resolved-directory>
#
# - name: the mcpServers key
# - source-path: the .mcp.json file that declared it
# - resolved-directory: the --directory arg (scan target), or "stdio" if none

set -euo pipefail

project_root="${1:-$(pwd)}"
home_dir="${HOME:-$(eval echo ~)}"

# Collect all .mcp.json paths to check
mcp_configs=()

# 1. Project-level
if [[ -f "$project_root/.mcp.json" ]]; then
  mcp_configs+=("$project_root/.mcp.json")
fi

# 2. User-level
if [[ -f "$home_dir/.claude/.mcp.json" ]]; then
  mcp_configs+=("$home_dir/.claude/.mcp.json")
fi

# 3. Plugin cache (installed plugins with bundled MCPs)
if [[ -d "$home_dir/.claude/plugins/cache" ]]; then
  while IFS= read -r f; do
    mcp_configs+=("$f")
  done < <(find "$home_dir/.claude/plugins/cache" -name ".mcp.json" -type f 2>/dev/null || true)
fi

if [[ ${#mcp_configs[@]} -eq 0 ]]; then
  echo "(no .mcp.json files found)"
  exit 0
fi

echo "### MCP_SOURCES"
printf '%s\n' "${mcp_configs[@]}"
echo

echo "### MCP_SERVERS"

for config in "${mcp_configs[@]}"; do
  # Extract server names and --directory args using lightweight JSON parsing.
  # We avoid jq dependency — parse with grep/sed for the common pattern:
  #   "server-name": { ... "args": ["--directory", "/path", ...] ... }

  # If python3 is available, use it for reliable JSON parsing
  if command -v python3 &>/dev/null; then
    python3 -c "
import json, sys, os

with open('$config') as f:
    data = json.load(f)

servers = data.get('mcpServers', {})
for name, cfg in servers.items():
    server_type = cfg.get('type', 'stdio')
    args = cfg.get('args', [])
    resolved = ''

    if server_type == 'http':
        url = cfg.get('url', '')
        resolved = 'http:' + url
    else:
        for i, a in enumerate(args):
            if a == '--directory' and i + 1 < len(args):
                resolved = os.path.expanduser(args[i + 1])
                break
        if not resolved:
            cmd = cfg.get('command', '')
            if cmd:
                resolved = 'stdio:' + cmd
    print(f'{name}\t$config\t{resolved}')
" 2>/dev/null || true
  else
    # Fallback: just report the config file, let the skill read it
    echo "(python3 unavailable — manual parse needed)	$config	"
  fi
done

echo
echo "### DONE"