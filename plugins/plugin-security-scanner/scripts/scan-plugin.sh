#!/usr/bin/env bash
# scan-plugin.sh <target-dir>
#
# Enumerate every scannable unit inside a plugin / marketplace directory and
# print a manifest the skill can feed back into Claude for deep analysis.
#
# Output is plain text with fixed section headers so the skill can parse it.
# The script does NO security judgement itself — it only surfaces what exists.

set -euo pipefail

target="${1:-}"
if [[ -z "$target" || ! -d "$target" ]]; then
  echo "usage: scan-plugin.sh <directory>" >&2
  exit 2
fi

target="$(cd "$target" && pwd)"

echo "### TARGET"
echo "$target"
echo

# Common exclusions for all find commands (dependencies, virtualenvs, caches, build output)
exclude_common=(-not -path "*/node_modules/*" -not -path "*/.git/*" -not -path "*/.venv/*" -not -path "*/venv/*" -not -path "*/vendor/*" -not -path "*/.tox/*" -not -path "*/__pycache__/*")

echo "### PLUGIN_MANIFESTS"
find "$target" -type f \( -name "plugin.json" -o -name "marketplace.json" \) "${exclude_common[@]}" 2>/dev/null | sort || true
echo

echo "### SKILL_FILES"
find "$target" -type f -name "SKILL.md" "${exclude_common[@]}" 2>/dev/null | sort || true
echo

echo "### MCP_CONFIGS"
find "$target" -type f \( -name ".mcp.json" -o -name "mcp.json" \) "${exclude_common[@]}" 2>/dev/null | sort || true
echo

echo "### HOOK_CONFIGS"
find "$target" -type f \( -name "settings.json" -o -name "settings.local.json" -o -name "hooks.json" \) "${exclude_common[@]}" 2>/dev/null | sort || true
echo

echo "### AGENT_FILES"
find "$target" -type f -path "*/agents/*.md" "${exclude_common[@]}" 2>/dev/null | sort || true
echo

echo "### SCRIPT_FILES"
find "$target" -type f \( -name "*.sh" -o -name "*.py" -o -name "*.js" -o -name "*.ts" -o -name "*.mjs" -o -name "*.cjs" \) "${exclude_common[@]}" -not -path "*/dist/*" -not -path "*/build/*" 2>/dev/null | sort || true
echo

echo "### BUNDLED_OR_MINIFIED"
find "$target" -type f \( -name "*.min.js" -o -name "bundle.js" -o -name "*.bundle.*" -o -path "*/dist/*" -o -path "*/build/*" \) "${exclude_common[@]}" 2>/dev/null | sort || true
echo

echo "### BINARY_FILES"
find "$target" -type f \( -name "*.exe" -o -name "*.so" -o -name "*.dylib" -o -name "*.bin" -o -name "*.wasm" \) "${exclude_common[@]}" 2>/dev/null | sort || true
echo

echo "### DEPENDENCY_MANIFESTS"
find "$target" -type f \( -name "package.json" -o -name "pyproject.toml" -o -name "requirements.txt" -o -name "Cargo.toml" -o -name "go.mod" \) "${exclude_common[@]}" 2>/dev/null | sort || true
echo

echo "### MCP_SERVER_PATHS"
# Extract --directory paths from .mcp.json files to resolve where MCP source lives
if command -v python3 &>/dev/null; then
  find "$target" -type f \( -name ".mcp.json" -o -name "mcp.json" \) "${exclude_common[@]}" 2>/dev/null | sort | while IFS= read -r mcpfile; do
    python3 -c "
import json, os, sys
with open('$mcpfile') as f:
    data = json.load(f)
servers = data.get('mcpServers', {})
for name, cfg in servers.items():
    args = cfg.get('args', [])
    resolved = ''
    for i, a in enumerate(args):
        if a == '--directory' and i + 1 < len(args):
            resolved = os.path.expanduser(args[i + 1])
            break
    cmd = cfg.get('command', '')
    print(f'{name}\t{resolved}\t{cmd}')
" 2>/dev/null || true
  done
fi
echo

echo "### DOTENV_FILES"
find "$target" -type f \( -name ".env" -o -name ".env.*" \) "${exclude_common[@]}" 2>/dev/null | sort || true
echo

echo "### README_FILES"
find "$target" -maxdepth 4 -type f -iname "readme*" "${exclude_common[@]}" 2>/dev/null | sort || true
echo

echo "### GIT_INFO"
if [[ -d "$target/.git" ]]; then
  git -C "$target" log --format="%H %ad %an" --date=short -n 5 2>/dev/null || true
  echo "---"
  git -C "$target" shortlog -sne 2>/dev/null | head -20 || true
else
  echo "(no .git directory)"
fi
echo

echo "### DONE"
