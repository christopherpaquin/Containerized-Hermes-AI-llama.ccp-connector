# Hermes Agent on local llama.cpp

Deploys [Hermes Agent](https://github.com/NousResearch/hermes-agent) (gateway
+ dashboard) configured to use a **llama.cpp `llama-server` already running
natively on this host** as its only inference provider. No cloud inference
provider is required, configured, or used as a fallback.

## Architecture

```text
Browser
   |
   v
Hermes Dashboard :9119  (container: hermes-dashboard, 127.0.0.1 only)
   |
   v
Hermes Gateway           (container: hermes)
   |
   v
127.0.0.1:8080/v1        (network_mode: host -- no proxy, no bridge)
   |
   v
llama.cpp llama-server    (native host process, not containerized)
   |
   v
Local GGUF model
```

Both containers use `network_mode: host` and share `~/.hermes:/opt/data` as
their persistent state directory. This mirrors
[NousResearch/hermes-agent's own `docker-compose.yml`](https://github.com/NousResearch/hermes-agent/blob/main/docker-compose.yml)
(two services, host networking, `HERMES_UID`/`HERMES_GID`), with the repo's
`build: .` swapped for the published, version-pinned
`nousresearch/hermes-agent` image. llama.cpp is not containerized here -- it
already exists and is managed independently.

## Requirements

- Docker + Docker Compose plugin
- `curl`, `jq`
- A llama.cpp `llama-server` already running on this host, launched with:
  - `--jinja` -- **required**. Without it, llama-server ignores the `tools`
    parameter entirely and Hermes's tool calls silently degrade to raw text.
  - `--ctx-size 65536` (or higher) -- Hermes Agent requires at least 64K
    tokens of context for agent/tool-use and refuses to start below that.
    llama.cpp does **not** default to a model's full context window; if you
    don't set `--ctx-size` explicitly you'll likely get 4K-32K depending on
    detected VRAM.
  - `-c` (llama.cpp's short flag) is the same setting as `--ctx-size`.

  Example:
  ```bash
  llama-server --jinja -fa -c 65536 -ngl 99 \
    -m /path/to/model.gguf --port 8080
  ```

- The server's OpenAI-compatible API must be reachable at
  `http://127.0.0.1:8080/v1`, specifically:
  - `GET /v1/models`
  - `POST /v1/chat/completions` (with native tool-calling support)

  Verify before deploying:
  ```bash
  curl http://127.0.0.1:8080/v1/models
  curl http://127.0.0.1:8080/props | jq '.chat_template'
  ```
  A non-empty `chat_template` confirms `--jinja` is active.

## Installation

```bash
./deploy.sh
```

This is idempotent -- re-running converges on the desired state without
destroying sessions, memories, skills, or resetting authentication. It:

1. Verifies Docker, Docker Compose, and the Docker daemon.
2. Verifies llama.cpp is reachable and reports an OpenAI-compatible model
   list, and checks the reported context size.
3. Auto-selects the model if llama.cpp serves exactly one; otherwise picks
   the first and tells you to pin `HERMES_MODEL` in `.env`.
4. Creates `~/.hermes` if needed (never destroys an existing installation).
5. Pulls the pinned `nousresearch/hermes-agent` image and starts the
   gateway and dashboard.
6. Configures Hermes's `model.provider` / `model.base_url` / `model.default`
   via Hermes's own `hermes config set` CLI (backing up `config.yaml` first,
   only when a change is actually needed -- no duplicate keys, no
   unnecessary churn on repeat runs).
7. Runs `healthcheck.sh` and prints a summary.

## Health check

```bash
./healthcheck.sh
```

Checks, in order: gateway/dashboard containers running, llama.cpp
`/v1/models` reachable and context size, dashboard port listening, Hermes's
configured provider/base_url/model match what's expected, no cloud API keys
present in `~/.hermes/.env`, and a real end-to-end test
(`hermes -z "Reply with exactly: HERMES_LLAMA_OK"` run inside the gateway
container) proving Hermes -> llama.cpp -> model actually works, not just
that llama.cpp responds on its own.

## Status

```bash
./status.sh
```

Prints gateway/dashboard state, image tag, llama.cpp reachability and
context size, and the configured provider/base_url/model.

## Logs

```bash
docker compose logs -f gateway      # supervised gateway output
docker compose logs -f dashboard    # dashboard output
tail -F ~/.hermes/logs/gateways/default/current   # rotated gateway log, survives restarts
tail -F ~/.hermes/logs/container-boot.log          # per-boot reconciler audit log
```

## Upgrade

Bump `HERMES_IMAGE_TAG` in `.env` (or `.env.example` for the committed
default) to a newer
[published tag](https://hub.docker.com/r/nousresearch/hermes-agent/tags),
then:

```bash
./deploy.sh
```

`~/.hermes` is untouched by an upgrade. Hermes runs non-interactive
config-schema migrations against the mounted `config.yaml` on container
start, backing it up first if a migration is needed.

## Uninstall

```bash
./uninstall.sh            # removes containers only; ~/.hermes is preserved
./uninstall.sh --purge    # also deletes ~/.hermes -- requires typed confirmation
```

`--purge` permanently deletes sessions, memories, skills, config, and
credentials, and requires typing the exact data-directory path to confirm.
Neither mode touches llama.cpp.

## Persistent data

All Hermes state lives under `~/.hermes` (mounted to `/opt/data` in both
containers) and survives container recreation and image upgrades:
config (`config.yaml`), secrets (`.env`), sessions, memories, skills, cron
jobs, hooks, logs, and more. Files are owned by the host user that ran
`deploy.sh` -- `HERMES_UID`/`HERMES_GID` in `.env` are set automatically
from `id -u`/`id -g` on every run.

## Configuration

Edit `.env` (copied from `.env.example` on first run) to change:

| Variable | Purpose | Default |
|---|---|---|
| `HERMES_IMAGE` / `HERMES_IMAGE_TAG` | Published image + pinned version tag | `nousresearch/hermes-agent` / `v2026.8.13` |
| `HERMES_UID` / `HERMES_GID` | Host user Hermes runs as (auto-set by deploy.sh) | `id -u` / `id -g` |
| `LLAMACPP_BASE_URL` | llama.cpp's OpenAI-compatible endpoint | `http://127.0.0.1:8080/v1` |
| `HERMES_MODEL` | Pin a specific model id when llama.cpp serves more than one | auto-detected |
| `HERMES_DASHBOARD_HOST` / `HERMES_DASHBOARD_PORT` | Dashboard bind address/port | `127.0.0.1` / `9119` |

Hermes's own config lives at `~/.hermes/config.yaml`:

```yaml
model:
  default: /models/Qwen3.8-27B-Q4_K_M.gguf
  provider: custom
  base_url: http://127.0.0.1:8080/v1
  api_key: none
```

## Connecting CLI coding agents to Hermes (vs. straight to llama.cpp)

Two different endpoints exist, for two different purposes -- don't point a
coding CLI at both interchangeably without knowing which one you're getting:

| Endpoint | What it talks to | Use it for |
|---|---|---|
| `http://127.0.0.1:8080/v1` | llama.cpp directly | Raw code completions -- the CLI's own tool-calling/file-editing logic drives everything. This is the default/recommended target for coding assistants. |
| `http://<host-ip>:8642/v1` | The Hermes **agent** (gateway API server) | A client that should get Hermes's memory/skills/tool-loop in the response, not just a raw completion. Requests are agent turns, not bare chat completions -- expect different latency/behavior than talking to the model directly. |

`<host-ip>` is this machine's LAN address (find it with `ip -4 addr show`
if you don't already have it saved) -- the API server is bound to
`0.0.0.0:8642` in this deployment, so it's reachable from other machines on
your network, not just `127.0.0.1`.

**To point a CLI client at Hermes instead of llama.cpp:**

1. Get the key: `grep API_SERVER_KEY .env`
2. Configure the client's OpenAI-compatible provider with:
   - Base URL: `http://<host-ip>:8642/v1`
   - API key: the `API_SERVER_KEY` value from step 1 (sent as `Authorization: Bearer <key>`)
3. Switch back to `http://127.0.0.1:8080/v1` (no key needed) for plain
   completions against the local model.

Verify the server is up and enforcing auth at any time:

```bash
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8642/v1/models          # 401, no key
curl -s -o /dev/null -w '%{http_code}\n' -H "Authorization: Bearer $(grep API_SERVER_KEY .env | cut -d= -f2)" http://127.0.0.1:8642/v1/models   # 200
```

`healthcheck.sh` runs both of these checks automatically on every deploy.

## Security notes

- **Dashboard**: defaults to `127.0.0.1:9119` -- not the LAN. Access it
  locally at `http://127.0.0.1:9119`, or remotely over SSH port forwarding:
  ```bash
  ssh -L 9119:127.0.0.1:9119 user@host
  ```
  Because that bind is loopback, Hermes's dashboard auth gate does not
  engage (it only activates on non-loopback binds).

  **LAN exposure (`HERMES_DASHBOARD_HOST=0.0.0.0`)**: supported, but only
  with an auth provider configured -- Hermes hard-fails at startup
  otherwise. Set `HERMES_DASHBOARD_BASIC_AUTH_USERNAME` and
  `HERMES_DASHBOARD_BASIC_AUTH_PASSWORD` in `.env` (gitignored, never
  committed); `deploy.sh` refuses to proceed with a non-loopback bind
  until both are set, and auto-generates
  `HERMES_DASHBOARD_BASIC_AUTH_SECRET` the first time it's needed so
  sessions survive container restarts. `healthcheck.sh` additionally
  verifies an unauthenticated request against a non-loopback bind does
  **not** return HTTP 200, i.e. that the auth gate is actually active, not
  just configured. Use a real password here -- this dashboard can execute
  shell/tool commands on the host.
- **Gateway API server** (`API_SERVER_ENABLED=true`): same LAN-exposure
  tradeoff as the dashboard, protected by `API_SERVER_KEY` (a generated
  bearer token, not a password) rather than a login page. `deploy.sh`
  auto-generates the key the first time the server is enabled and never
  changes it on subsequent runs. `healthcheck.sh` confirms unauthenticated
  requests get HTTP 401 and a correctly-authenticated request gets HTTP
  200 on every deploy. Treat `API_SERVER_KEY` in `.env` like any other
  credential -- it's gitignored, and anyone who has it can drive the full
  Hermes agent (memory, skills, tool execution) from the network.
- **Local-only inference guardrail**: this deployment never writes a cloud
  provider API key (`OPENROUTER_API_KEY`, `ANTHROPIC_API_KEY`,
  `OPENAI_API_KEY`, etc.) into `~/.hermes/.env`. Hermes's `auxiliary.*`
  tasks (compression summaries, vision, web extraction) default to
  `provider: "auto"`, which routes to the **main chat model** -- i.e. the
  local `custom` provider configured here -- unless `fallback_providers`
  is explicitly configured, which this deployment does not do. With no
  cloud credentials present, any accidental fallback attempt fails loudly
  instead of silently billing a cloud account. If llama.cpp is down, Hermes
  chat/tool calls fail with a connection error rather than routing
  elsewhere. `healthcheck.sh` checks `~/.hermes/.env` for stray cloud keys
  on every run and warns if any are found.
- Never point two Hermes gateway containers at the same `~/.hermes`
  directory simultaneously -- session and memory files aren't safe for
  concurrent writes.

## Troubleshooting

- **`deploy.sh` fails at "Nothing is listening on 127.0.0.1:8080"** --
  start `llama-server` first; this deployment does not manage it.
- **Hermes refuses to start / complains about context length** -- restart
  `llama-server` with `--ctx-size 65536` or higher; Hermes hard-fails below
  64K tokens for agent/tool use.
- **Tool calls come back as raw text instead of executing** -- `llama-server`
  was started without `--jinja`. Restart it with `--jinja` and re-run
  `./deploy.sh`.
- **Dashboard not reachable remotely** -- by design; use the SSH tunnel
  command above rather than changing the bind address.

## Known limitations

- On first boot, the image seeds `config.yaml` from a bundled template that
  can lag the image's own migration tooling (observed:
  `config-migrate` warning about a config "~2 years old" immediately after
  a fresh seed). This did not affect the `model.*` keys this deployment
  manages and the end-to-end health check still passes, but if you see
  migration warnings in `docker compose logs gateway`, review
  `hermes config check` output before relying on newer config features.
- `hermes config get`/`set` operate on dotted paths (`model.provider`,
  `model.base_url`, `model.default`, `model.api_key`); this deployment does
  not touch `fallback_providers` or `auxiliary.*` -- see Security notes for
  why that's intentional.
