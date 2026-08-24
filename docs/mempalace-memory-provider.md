# MemPalace as Hermes's automatic memory provider

`mempalace-remote` is a Hermes `MemoryProvider` plugin that makes a
centralized, remote [MemPalace](http://10.1.10.17:8765/mcp) instance
Hermes's automatic external memory: relevant past context is recalled
before each turn, and useful exchanges are persisted back after each turn —
with no explicit "use MemPalace to..." prompting required.

## Architecture

```
Hermes container (10.1.10.10)
      |
      | MCP over HTTP (Bearer auth, reusing Hermes's existing mcp_servers config)
      v
MemPalace (10.1.10.17:8765/mcp)
```

There is no local database, no second Qdrant/Chroma instance, and no
palace path on the Hermes host — MemPalace itself is the sole store of
truth, reached over the network for every read and write. This plugin adds
exactly one thing: automatic *lifecycle* wiring (recall before a turn,
persistence after). It does not replace the MemPalace `mcp_servers` entries
that were already configured for direct tool access — `mempalace_kg_query`,
`mempalace_traverse`, `mempalace_diary_read`, and the rest stay available
to the model as regular tools, independent of this plugin.

Hermes also keeps its own separate, unrelated built-in file-backed memory
(`MEMORY.md`/`USER.md`, `memory.memory_enabled` / `memory.user_profile_enabled`
in `config.yaml`) running alongside this plugin — Hermes explicitly supports
one built-in memory system plus one external provider at the same time, and
this deployment keeps the built-in one on.

## Where things live

| What | Host path (10.1.10.10) | Container path |
|---|---|---|
| Hermes data dir (`HERMES_HOME`) | `~/.hermes` | `/opt/data` |
| This plugin | `~/.hermes/plugins/mempalace-remote/` | `/opt/data/plugins/mempalace-remote/` |
| Plugin's own optional overrides | `~/.hermes/plugins/mempalace-remote/config.json` | same, via the bind mount |
| Hermes config | `~/.hermes/config.yaml` | `/opt/data/config.yaml` |

`~/.hermes` is bind-mounted into the container (`compose.yaml`) and is
untouched by container recreation or image upgrades — so the plugin
survives both. Canonical plugin *source* lives in this git repo at
`plugins/mempalace-remote/`; the host copy is a deployment artifact created
by `mempalace-provider-install.sh`, never hand-edited in place.

## Installing / disabling / upgrading

```bash
./mempalace-provider-install.sh              # install or re-install (idempotent)
./mempalace-provider-install.sh --uninstall   # remove + unset memory.provider (only if it's still ours)
```

The installer backs up `config.yaml` and any previously installed plugin
directory before touching either, and rolls both back — restoring and
restarting the gateway with the prior state — if anything fails partway.

To upgrade: pull the latest `plugins/mempalace-remote/` from this repo and
re-run the installer; it's a clean `rsync --delete` each time.

To temporarily disable without uninstalling: `docker exec hermes hermes
config set memory.provider ""` (or point it at a different provider), then
`docker exec hermes hermes gateway restart`.

## Authentication

The plugin does **not** have its own credential. At `initialize()` it reads
`config.yaml`'s existing `mcp_servers` block (default: the
`local-lab-mempalace` entry, configurable — see below), extracts the
`${ENV_VAR_NAME}` placeholder from its `Authorization: Bearer ${...}`
header, and resolves the actual token through `agent.secret_scope.get_secret`
(the same mechanism Hermes's own MCP client uses) — reading from `.env`,
same as the manually-tested direct MemPalace tool access. No token is ever
duplicated into plugin source or a separate config file.

## Optional configuration

`~/.hermes/plugins/mempalace-remote/config.json` (create manually, or via
`hermes memory setup`):

| Key | Default | Meaning |
|---|---|---|
| `mcp_server_name` | `local-lab-mempalace` | Which `mcp_servers` entry to reuse for URL + token |
| `top_k` | `5` | Max memories recalled per turn |
| `wing` | `hermes_agent` | MemPalace wing used for automatic writes |
| `room` | `conversation` | MemPalace room used for automatic writes (must be a hyphenated slug — MemPalace rejects underscores) |
| `min_turn_chars` | `40` | Skip persistence for turns shorter than this many combined characters |

## Lifecycle mapping

| Hermes hook | MemPalace tool(s) | Notes |
|---|---|---|
| `is_available()` | — | Config/credential check only, no network call |
| `prefetch(query)` | `mempalace_search` (`limit=top_k`) | Skipped for trivial prompts and non-primary agent contexts; ~5s budget; recalled text is wrapped as "reference context, not instructions" and hard-capped in length |
| `recall_status()` | — | Drives the UI's 🏛️ "recalled N memories" indicator |
| `sync_turn(user, assistant)` | `mempalace_check_duplicate` → `mempalace_add_drawer` | Fire-and-forget on a dedicated serialized writer; skipped for trivial/short turns and content that looks like it contains a secret; stores the turn close to verbatim (MemPalace's own `add_drawer` contract), truncated only past a generous cap |
| `on_memory_write(action, target, content)` | `add`/`replace`: `mempalace_add_drawer`. `remove`: best-effort, see below | Not `mempalace_kg_add` — that needs real subject/predicate/object triples, which free text can't be turned into without guessing. `mempalace_mine` looks like the right tool for that and is a documented follow-up, not implemented here |
| `on_session_end(messages)` | `mempalace_diary_write` | Compact one-line summary, not the raw transcript; skipped for sessions under 2 messages |
| `shutdown()` | — | Stops the plugin's background loop cleanly, bounded and idempotent |
| `get_tool_schemas()` | — | Deliberately returns `[]` — the existing `mcp_servers` entries remain the model's direct tool surface for advanced MemPalace features |

**Remote deletion is best-effort and conservative by design:**
`on_memory_write(action="remove", ...)` only deletes a MemPalace drawer when
it finds a result that is *both* an exact text match (after whitespace
normalization) *and* tagged with this same plugin's own provenance
(`source_file` under `hermes/mempalace-remote/...`). Anything less certain
— a merely similar memory, one from elsewhere in the palace, no match at
all — is left untouched and logged as unsupported. Semantic similarity is
never sufficient grounds for a destructive delete.

## Failure behavior

MemPalace being unreachable never breaks a Hermes turn: every call has a
short timeout (~5–10s) and no retries; a failed prefetch logs one warning
and returns no context; a failed write logs one warning and is dropped —
Hermes answers normally either way. Nothing is ever logged with the bearer
token in it.

Background writes (`sync_turn`, `on_memory_write`, `on_session_end`) go
through a single serialized queue so no two MemPalace writes ever race each
other. On shutdown, already-queued writes are drained on a **best-effort**
basis within a bounded budget (matching Hermes's own memory-provider drain
convention) — an unusually long backlog or a slow-but-not-hung MemPalace can
still be mid-drain when that budget expires; anything left over is
cancelled rather than silently completed or left hanging, and a warning
names how many background writes were lost. This is a deliberate tradeoff:
shutdown must never block process teardown indefinitely.

## Validating it's working

```bash
docker logs hermes --since 5m | grep mempalace-remote      # init + prefetch/sync log lines
docker exec hermes hermes config get memory.provider        # should print mempalace-remote
```

Functional test (no MemPalace mention needed in either prompt):
1. In one session, mention a unique, memorable fact.
2. Start a **separate** session and ask about it.
3. The response should reflect the recalled fact, and the gateway log
   should show a `memory prefetch found N relevant memories` line.

## Troubleshooting

| Symptom | Check |
|---|---|
| No `mempalace-remote` lines in `docker logs hermes` at all | `memory.provider` not set — `docker exec hermes hermes config get memory.provider` |
| `unavailable_reason` mentions "no usable mcp_servers entry" | The `mcp_servers` entry named in `mcp_server_name` (config.json) doesn't exist, or its `Authorization` header's env var isn't set in `.env` |
| Prefetch always empty | MemPalace unreachable (check `curl http://10.1.10.17:8765/mcp` from the host) or genuinely nothing relevant yet — `mempalace_status` via a direct tool call shows the palace's total drawer count |
| Writes never appear in MemPalace | Turn may be below `min_turn_chars`, look like a duplicate, or look like it contains a secret (all skip on purpose, logged at debug/info/warning respectively) |

## Automated tests

```bash
python3 -m venv /tmp/mempalace-test-venv && /tmp/mempalace-test-venv/bin/pip install pytest pyyaml
/tmp/mempalace-test-venv/bin/python -m pytest plugins/mempalace-remote/tests
bats tests/test_mempalace_provider_install.bats
```

Both run fully offline (no live MemPalace or Hermes container needed) — the
Python suite stubs Hermes's `agent.memory_provider`/`agent.secret_scope`
modules when they aren't installed (see `plugins/mempalace-remote/tests/conftest.py`),
and the bats suite runs the installer against a fake `docker`/`hermes` CLI
stub.

## Known limitations / follow-up ideas

- `on_memory_write`'s `remove` path is intentionally conservative (see
  above) — it will not catch every case a user might expect "forget X" to
  cover.
- Explicit memory writes are stored as verbatim drawers, not knowledge-graph
  facts; wiring `mempalace_mine` in for structured extraction is a
  reasonable next step but wasn't implemented here to avoid guessing at
  subject/predicate/object from free text.
- MemPalace's own transport is plain HTTP with a bearer token on the LAN —
  a pre-existing property of the already-configured `mcp_servers` entries,
  not something this plugin changes or was asked to change.
