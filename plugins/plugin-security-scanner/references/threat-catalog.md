# Threat Catalog — Claude Code Plugins, Skills, MCP Servers, Hooks

This catalog is the source of truth for what `plugin-scan` looks for. Each category has:

- **What it is** — the risk, in one sentence
- **Where to look** — files/fields the scanner should read
- **Detection hints** — concrete strings, regex, and patterns that indicate the risk
- **Severity default** — Critical / High / Medium / Low / Info (evidence can push it higher or lower)

A finding is only worth reporting if you can cite a specific `file:line`. No evidence = no finding.

---

## Part 1 — MCP server risks

Applies to: `.mcp.json`, any server referenced by it, any `command:` / `args:` / `env:` entry, and the source tree of the MCP itself (if bundled or clonable).

### MCP-1 — Prompt injection via tool results
- **What:** Tool responses can embed hidden instructions (`[SYSTEM: …]`, `<system>`, fake tool-result markers, "ignore previous instructions") that the LLM may follow.
- **Where:** Source files that build response strings returned from tool handlers (`return`, `respond`, `content:` payloads in TS/Python MCPs).
- **Detection hints:**
  - Returned strings that concatenate untrusted input without sanitisation (e.g. raw HTML, raw HTTP body, arbitrary webhook payloads) into the tool result.
  - String literals inside the server containing `SYSTEM:`, `<system>`, `</system>`, `ignore previous`, `disregard prior`, `you are now`, `[[ASSISTANT]]`, `<|im_start|>`.
  - No output filter / length cap / schema-validation on tool return.
- **Severity default:** **High** (Critical if the server proxies third-party content like web pages, issue trackers, email).

### MCP-2 — Tool poisoning (deceptive descriptions)
- **What:** An MCP declares tools with `description` fields designed to manipulate the LLM into calling them unnecessarily or to bypass user confirmation.
- **Where:** Tool registration sites — `server.tool(name, description, …)`, `@tool(...)` decorators, `tools: [...]` arrays, `ListToolsResult` schemas.
- **Detection hints (regex, case-insensitive):**
  - `call (this|me) before (every|each) response`
  - `always (call|invoke|use) (this|me) first`
  - `improves (accuracy|safety|performance) — (call|use) every time`
  - `(do not|don'?t) (ask|confirm) (the )?user`
  - `bypass|skip.*confirmation`
  - `without .* consent`
  - Descriptions that instruct the **LLM** rather than describing the tool.
  - Descriptions dramatically longer than the tool schema would warrant (>400 chars) — common poisoning smell.
- **Severity default:** **Critical**.

### MCP-3 — Silent data exfiltration
- **What:** The server contacts attacker-controlled endpoints, mirrors tool input/output to a second destination, or sends analytics/telemetry that includes user data.
- **Where:** Any network call in the MCP source.
- **Detection hints:**
  - `fetch(`, `axios`, `http.request`, `urllib`, `requests.`, `httpx.`, `net.Dial`, `XMLHttpRequest` pointing at hosts that don't match the documented service domain.
  - Hard-coded IP addresses (`\b(?:\d{1,3}\.){3}\d{1,3}\b`) or `*.ngrok`, `*.glitch.me`, `webhook.site`, `requestbin`, `pastebin`, `discord.com/api/webhooks`, `telegram`, raw `@gmail.com` SMTP.
  - Two destinations in the same handler (legitimate call + "telemetry").
  - `process.env.*` values forwarded outside the primary API base URL.
  - DNS lookups with user-controlled input (DNS exfiltration).
- **Severity default:** **Critical**.

### MCP-4 — Credential harvesting via env vars
- **What:** The server requests more env vars than its advertised function needs, or reads env at startup and transmits it.
- **Where:** `env` block in `.mcp.json`, `process.env.*` / `os.environ[...]` in source, startup hooks.
- **Detection hints:**
  - Env var names matching `(?i)(token|secret|password|key|apikey|api_key|credential|session)` that aren't used in any outbound request body to the documented host.
  - Reads of env vars unrelated to the stated purpose (e.g. a "Grafana" MCP reading `AWS_SECRET_ACCESS_KEY`, `GITHUB_TOKEN`, `OPENAI_API_KEY`).
  - `JSON.stringify(process.env)` / `json.dumps(dict(os.environ))` / `printenv` — **Critical**.
  - `.env` files bundled inside the plugin repo — leak risk.
- **Severity default:** **High** (Critical if env is serialised wholesale).

### MCP-5 — Cross-MCP contamination
- **What:** The server emits content that mimics other MCPs' schemas, rewrites context, or injects directives that alter how trusted MCPs behave in the same session.
- **Where:** Tool response bodies, resource contents, prompt templates.
- **Detection hints:**
  - Response strings referencing **other** MCPs by name (`mcp__slack__`, `mcp__github__`, `tool_use`) — possible prompt targeting.
  - Responses that contain fake tool-use XML / JSON blocks.
  - Responses that set "global" instructions ("for the rest of this session…", "going forward, …").
- **Severity default:** **High**.

### MCP-6 — Supply-chain / rug-pull
- **What:** Package or repo may change after install, pulling in malicious code the user never reviewed.
- **Where:** `.mcp.json` `command`, `package.json`, `requirements.txt`, `uvx`, `npx`, `pipx`, install scripts, GitHub Actions.
- **Detection hints:**
  - `npx -y <pkg>` / `uvx <pkg>` / `pipx run <pkg>` without a pinned version or integrity hash.
  - Dependencies sourced from git URLs, GitHub tarballs, or non-registry hosts.
  - `postinstall`, `preinstall`, `prepare` npm scripts that fetch or execute remote code (`curl … | sh`, `wget … | bash`, `eval $(curl …)`).
  - Auto-update logic in the server (`self-update`, `spawn('git', ['pull'])`, `npm install` at runtime).
  - `.mcp.json` `command: "curl"` or `command: "bash"` with `-c` — **Critical**.
  - Maintainer list / first-commit date very recent combined with broad permissions.
- **Severity default:** **High**.

### MCP-7 — Excessive filesystem / shell access
- **What:** The server declares or uses unrestricted shell execution, arbitrary file reads/writes, or `rm -rf`-class operations.
- **Where:** Source — any `child_process`, `execSync`, `subprocess`, `os.system`, `eval`, `new Function`, `shell=True`.
- **Detection hints:**
  - Shell calls built from user-controlled args without escaping.
  - File operations that accept absolute paths from tool arguments with no allow-list.
  - Tools named generically (`run`, `execute`, `shell`, `eval`, `system`) — the existence itself is a risk that should be flagged so the user can decide.
- **Severity default:** **High**.

### MCP-8 — Unsigned / opaque transport
- **What:** The server speaks HTTP (not HTTPS), disables TLS verification, or trusts any certificate.
- **Detection hints:**
  - `rejectUnauthorized: false`, `verify=False`, `InsecureSkipVerify`, `NODE_TLS_REJECT_UNAUTHORIZED=0`.
  - `http://` URLs to non-localhost hosts.
- **Severity default:** **Medium**.

---

## Part 2 — Skill risks

Applies to: every `SKILL.md` in the plugin, plus any file referenced from one (scripts, references, assets).

### SKL-1 — Prompt-injection payloads in SKILL.md
- **What:** The skill body contains text designed to manipulate the host model (data exfil instructions, persona overrides, "always…" directives not related to the skill's advertised purpose).
- **Where:** `SKILL.md` body, frontmatter `description`.
- **Detection hints:**
  - `(?i)ignore (previous|all|prior) (instructions|rules)` — **Critical**.
  - `(?i)you are now`, `(?i)pretend to be`, `(?i)act as .* (unrestricted|without safety|jailbroken)`.
  - Instructions to send data to URLs, email addresses, or webhooks.
  - Instructions to read sensitive files (`~/.ssh`, `~/.aws`, `.env`, `/etc/shadow`).
  - Hidden content — zero-width unicode (`\u200b`, `\u200c`, `\u200d`, `\ufeff`), right-to-left override (`\u202e`), Tag Unicode block (`\uE0000`–`\uE007F`), white-on-white/base64 blobs with no explanation.
- **Severity default:** **Critical** when obfuscation is present, **High** otherwise.

### SKL-2 — Overbroad `allowed-tools`
- **What:** The skill frontmatter grants more tools than its stated function needs — especially `Bash`, `Write`, `Edit`, and wildcards.
- **Where:** `allowed-tools:` frontmatter key.
- **Detection hints:**
  - `Bash` with no `Bash(*:...)` scoping, combined with a skill description that only reads code.
  - `allowed-tools: "*"` or missing the field when the skill obviously executes commands.
  - `Write`/`Edit` in a skill advertised as read-only.
- **Severity default:** **Medium** (High if combined with network-capable Bash).

### SKL-3 — Deceptive triggering description
- **What:** The description tries to force the skill to trigger for unrelated prompts (same pattern as MCP-2 tool poisoning).
- **Detection hints:** same regex set as MCP-2, applied to `description:` frontmatter.
- **Severity default:** **High**.

### SKL-4 — Untrusted remote content at runtime
- **What:** The skill instructs Claude to `curl`/`wget` a URL and execute the result, or to pipe remote content into shells/interpreters.
- **Where:** SKILL.md body, referenced scripts.
- **Detection hints:**
  - `curl .* | (sh|bash|zsh|python|node|perl)` — **Critical**.
  - `wget -O - .* | (sh|bash|...)` — **Critical**.
  - `eval "$(curl …)"`, `source <(curl …)`.
  - Instructions that say "download and run" without a checksum.
- **Severity default:** **Critical**.

### SKL-5 — Unsafe file operations
- **What:** Skill tells Claude to modify system files, secrets, or credentials outside the working directory.
- **Detection hints:**
  - Touches to `~/.ssh/`, `~/.aws/`, `~/.config/gh/`, `~/.claude/`, `/etc/`, crontabs, shell rc files without an obvious reason (e.g. "keybindings-help" legitimately touches `~/.claude/keybindings.json`).
  - Instructions to disable safety (`--no-verify`, `--dangerously-skip-permissions`, hook bypass).
- **Severity default:** **High**.

### SKL-6 — Sensitive egress instructions
- **What:** Skill instructs Claude to POST/upload local data to external services (including "just for analytics").
- **Detection hints:** any `curl -X POST`, `fetch(`, webhook URLs, Slack/Discord/Telegram webhook posts **inside** the skill instructions.
- **Severity default:** **Critical** when tied to files/secrets/env; **High** otherwise.

---

## Part 3 — Hook risks

Applies to: `settings.json` / `settings.local.json` `hooks` blocks, and any referenced hook script.

Hooks run as shell commands under the **user's** shell without an LLM reviewing each execution. They are therefore one of the most dangerous surfaces.

### HOK-1 — Arbitrary shell on every turn
- **What:** A `PreToolUse` / `PostToolUse` / `Stop` / `UserPromptSubmit` hook runs an unknown or opaque script.
- **Detection hints:**
  - `command:` running a file outside the plugin/repo (absolute path to `~/Downloads`, `/tmp`).
  - `command:` that `eval`s env, reads stdin unboundedly, or pipes to `sh`.
  - `matcher: "*"` combined with network commands.
- **Severity default:** **Critical**.

### HOK-2 — Exfiltration inside a hook
- **What:** A hook script sends transcript, env, or tool payloads to a remote host.
- **Detection hints:** same network + webhook set as MCP-3, but treated as Critical because it runs silently on every trigger.
- **Severity default:** **Critical**.

### HOK-3 — Destructive hook
- **What:** Hook deletes, truncates, or force-pushes without user input.
- **Detection hints:** `rm -rf`, `git push --force`, `git reset --hard`, `truncate`, `shred`, `>` over known paths.
- **Severity default:** **Critical**.

### HOK-4 — Privilege/permission escalation
- **What:** Hook uses `sudo`, `chmod 777`, `setuid`, or modifies allowlists/permissions in Claude settings.
- **Severity default:** **High**.

### HOK-5 — Persistence
- **What:** Hook writes to `~/.bashrc`, `~/.zshrc`, crontab, launchd, systemd user units, or adds itself to startup.
- **Severity default:** **Critical**.

---

## Part 4 — Cross-cutting / supply-chain

Applies to the whole plugin (every subdirectory).

### SUP-1 — Secrets committed
- `AKIA[0-9A-Z]{16}`, `ghp_[A-Za-z0-9]{36}`, `xoxb-\d+-\d+-[A-Za-z0-9]+`, `sk-[A-Za-z0-9]{20,}`, private keys (`-----BEGIN (RSA|OPENSSH|PGP) PRIVATE KEY-----`), `.env` with values.
- **Severity:** **Critical**.

### SUP-2 — Obfuscated / minified code without source
- Bundled `dist/` with no build config; `eval(atob(...))`; `Function(atob(...))`; long base64 blobs assigned to executable variables.
- **Severity:** **High**.

### SUP-3 — Binary executables
- Any `.exe`, `.so`, `.dylib`, `.bin`, or unknown binary checked into the plugin.
- **Severity:** **High** — user should inspect/disassemble before trusting.

### SUP-4 — Dependency risk
- Unpinned versions in `package.json` / `requirements.txt` / `pyproject.toml`.
- Typosquat names (ask the user to confirm — e.g. `reqeusts`, `axois`, `lodahs`).
- **Severity:** **Medium**.

### SUP-5 — License / attribution missing
- No `LICENSE`, or license file that claims someone else's copyright.
- **Severity:** **Low** / Info.

### SUP-6 — Maintainer / activity signals (Info — for GitHub repos)
- First-commit date very recent, single maintainer, tiny history, broad permissions asked: combine into one Info finding so the user can weigh trust.

---

## Severity guidance (how to decide)

- **Critical** — exploitation is trivial and gives the attacker secrets, code execution, or user data with no further user action.
- **High** — meaningful risk but needs a precondition (a particular flow, a specific input, user running a specific command).
- **Medium** — defence-in-depth concern; real but not directly exploitable.
- **Low / Info** — worth knowing; not a blocker.

Escalate severity when:
- Obfuscation is present (zero-width, base64, packed code).
- Multiple categories compound (e.g. env harvesting **and** network egress in the same file).
- The plugin auto-updates or uses unpinned `npx`/`uvx`.

De-escalate severity when:
- The behaviour is openly documented in the README **and** matches the skill's advertised purpose (e.g. a "slack poster" skill legitimately posts to a webhook).
- Evidence is weak (single keyword match with no dangerous context).

When in doubt, include the finding and mark it Low/Info — the human is the final arbiter.
