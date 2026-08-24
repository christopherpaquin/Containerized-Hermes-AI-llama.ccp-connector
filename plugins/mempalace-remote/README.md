# mempalace-remote

Hermes `MemoryProvider` plugin that makes a centralized, remote
[MemPalace](http://10.1.10.17:8765/mcp) instance Hermes's automatic external
memory — recall before each turn, persistence after each turn — over MCP.
No local database, no duplicated credentials: it reuses whichever
`mcp_servers` entry in `config.yaml` already points at MemPalace.

Full design writeup, lifecycle mapping, and operational docs:
`docs/mempalace-memory-provider.md` at the repo root.

## Requirements

- A working `mcp_servers` entry in `~/.hermes/config.yaml` pointing at a
  MemPalace MCP endpoint, with a Bearer `Authorization` header (templated as
  `${SOME_ENV_VAR}` and set in `~/.hermes/.env`, or a literal token). This
  plugin does not create that entry — it reuses it.
- `memory.provider: mempalace-remote` set in `config.yaml` (the install
  script at the repo root, `mempalace-provider-install.sh`, does this for
  you).

## Optional configuration

Run `hermes memory setup` inside the container, or hand-edit
`~/.hermes/plugins/mempalace-remote/config.json`:

| Key | Default | Meaning |
|---|---|---|
| `mcp_server_name` | `local-lab-mempalace` | Which `mcp_servers` entry to reuse |
| `top_k` | `5` | Max memories recalled per turn |
| `wing` | `hermes_agent` | MemPalace wing used for automatic writes |
| `room` | `conversation` | MemPalace room used for automatic writes (must be a hyphenated slug) |
| `min_turn_chars` | `40` | Skip persistence for turns shorter than this |

## What it does NOT do

- It does not expose new tools to the model (`get_tool_schemas()` returns
  `[]` on purpose) — the existing MemPalace `mcp_servers` entries remain the
  direct tool surface for `mempalace_kg_query`, `mempalace_traverse`,
  `mempalace_diary_read`, etc.
- It does not turn free text into knowledge-graph triples — `on_memory_write`
  mirrors explicit memory writes as verbatim drawers, not `mempalace_kg_add`
  calls, since that would mean guessing subject/predicate/object out of
  unstructured text.
- Remote deletion (`on_memory_write(action="remove", ...)`) is best-effort:
  it only deletes a drawer that is both an exact text match and was written
  by this same plugin (tagged `source_file` under `hermes/mempalace-remote/`).
  Anything less certain is left alone and logged.
