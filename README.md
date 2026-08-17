# Hermes Agent on local llama.cpp

![License](https://img.shields.io/badge/license-Apache--2.0-blue)
![Platform](https://img.shields.io/badge/platform-Linux-lightgrey)
![Deploy](https://img.shields.io/badge/deploy-Docker%20Compose-2496ED)
![Inference](https://img.shields.io/badge/inference-local%20only-success)

Deploys [Hermes Agent](https://github.com/NousResearch/hermes-agent) (gateway
+ dashboard) configured to use a **llama.cpp `llama-server` already running
natively on this host** as its only inference provider. No cloud inference
provider is required, configured, or used as a fallback.

## 📋 Contents

- [🎯 Overview](#-overview)
- [🏗️ Architecture](#️-architecture)
- [📦 Requirements](#-requirements)
- [🚀 Installation](#-installation)
- [💬 Usage](#-usage)
- [⚙️ Configuration](#️-configuration)
- [🏥 Health check](#-health-check)
- [📊 Status](#-status)
- [📜 Logs](#-logs)
- [⬆️ Upgrade](#️-upgrade)
- [💾 Backups](#-backups)
- [🗑️ Uninstall](#️-uninstall)
- [💽 Persistent data](#-persistent-data)
- [🔒 Security notes](#-security-notes)
- [🛠️ Troubleshooting](#️-troubleshooting)
- [⚠️ Known limitations](#️-known-limitations)
- [📄 License](#-license)

---

## 🎯 Overview

`Hermes` (gateway + dashboard) → `llama.cpp` (native host process) →
local GGUF model. No cloud inference provider is ever configured, so a
down/unreachable `llama.cpp` fails loudly instead of silently falling back
to a paid provider (see [Security notes](#-security-notes)).

---

## 🏗️ Architecture

```text
┌────────────────────────────────────────────┐
│  Browser                                   │
└─────────────────────┴──────────────────────┘
                      │
                      ▼
┌─────────────────────┬──────────────────────┐
│  Hermes Dashboard  :9119                   │
│  container: hermes-dashboard               │
└─────────────────────┴──────────────────────┘
                      │
                      ▼
┌─────────────────────┬──────────────────────┐
│  Hermes Gateway                            │
│  container: hermes                         │
└─────────────────────┴──────────────────────┘
                      │
                      ▼
┌─────────────────────┬──────────────────────┐
│  127.0.0.1:8080/v1                         │
│  network_mode: host -- no proxy, no bridge │
└─────────────────────┴──────────────────────┘
                      │
                      ▼
┌─────────────────────┬──────────────────────┐
│  llama.cpp llama-server                    │
│  native host process, not containerized    │
└─────────────────────┴──────────────────────┘
                      │
                      ▼
┌─────────────────────┬──────────────────────┐
│  Local GGUF model                          │
└────────────────────────────────────────────┘
```

Both containers use `network_mode: host` and share `~/.hermes:/opt/data` as
their persistent state directory. This mirrors
[NousResearch/hermes-agent's own `docker-compose.yml`](https://github.com/NousResearch/hermes-agent/blob/main/docker-compose.yml)
(two services, host networking, `HERMES_UID`/`HERMES_GID`), with the repo's
`build: .` swapped for the published, version-pinned
`nousresearch/hermes-agent` image. llama.cpp is not containerized here — it
already exists and is managed independently.

---

## 📦 Requirements

- ✅ Docker + Docker Compose plugin
- ✅ `curl`, `jq`
- ✅ A llama.cpp `llama-server` already running on this host, launched with:
  - ⚠️ `--jinja` — **required**. Without it, llama-server ignores the `tools`
    parameter entirely and Hermes's tool calls silently degrade to raw text.
  - ⚠️ `--ctx-size 65536` (or higher) — Hermes Agent requires at least 64K
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

  Note: `llama-server` typically binds `0.0.0.0`, so it's also directly
  reachable from other machines on your LAN at `http://10.1.10.x:8080/v1`
  (`10.1.10.x` standing in for this host's actual LAN address throughout
  this README). This deployment doesn't use that path — Hermes always
  reaches it via `127.0.0.1` on the same host — but it's useful for
  testing the model directly from another machine.

---

## 🚀 Installation

```bash
./deploy.sh
```

This is idempotent — re-running converges on the desired state without
destroying sessions, memories, skills, or resetting authentication. It:

- [x] Verifies Docker, Docker Compose, and the Docker daemon.
- [x] Verifies llama.cpp is reachable and reports an OpenAI-compatible model
      list, and checks the reported context size.
- [x] Auto-selects the model if llama.cpp serves exactly one; otherwise
      picks the first and tells you to pin `HERMES_MODEL` in `.env`.
- [x] Creates `~/.hermes` if needed (never destroys an existing installation).
- [x] Pulls the pinned `nousresearch/hermes-agent` image and starts the
      gateway and dashboard.
- [x] Configures Hermes's `model.provider` / `model.base_url` /
      `model.default` via Hermes's own `hermes config set` CLI (backing up
      `config.yaml` first, only when a change is actually needed — no
      duplicate keys, no unnecessary churn on repeat runs).
- [x] Configures the dashboard's auth provider, the gateway API server, and
      Slack (each only if you've set the matching `.env` variables — see
      [Configuration](#️-configuration)).
- [x] Installs the Hermes-cron backup script.
- [x] Runs `healthcheck.sh` and prints a summary.

---

## 💬 Usage

Three ways to actually talk to Hermes once it's deployed, from simplest to
most powerful:

### 1. Web dashboard

Open `http://127.0.0.1:9119` locally, or `http://10.1.10.x:9119` (this
host's LAN address) if `HERMES_DASHBOARD_HOST=0.0.0.0` — see
[Security notes](#-security-notes) before exposing it beyond localhost.
Log in with the dashboard's configured auth. Gives you chat, sessions,
memory, skills, and cron job views.

### 2. Interactive CLI, inside the container

```bash
docker exec -it hermes hermes
```

A normal interactive Hermes chat session against the local model. `Ctrl-D`
or `/exit` to leave.

### 3. One-shot queries (scripting)

```bash
docker exec hermes hermes -z "What's 2+2?"
```

Prints just the final answer — no banner, no tool-call transcript. This is
what `healthcheck.sh` uses for its end-to-end test.

### 4. Slack (if configured)

If `SLACK_BOT_TOKEN`/`SLACK_APP_TOKEN`/`SLACK_ALLOWED_USERS` are set (see
[Configuration](#️-configuration)), message the bot directly from the
Slack app — no port forwarding or public exposure needed, since it
connects to Slack over an outbound Socket Mode WebSocket. Only the member
IDs listed in `SLACK_ALLOWED_USERS` are answered; everyone else is denied
by default.

### Connecting CLI coding agents to Hermes (vs. straight to llama.cpp)

Two different endpoints exist, for two different purposes — don't point a
coding CLI at both interchangeably without knowing which one you're getting:

| Endpoint | What it talks to | Use it for |
|---|---|---|
| `http://127.0.0.1:8080/v1` | llama.cpp directly | Raw code completions — the CLI's own tool-calling/file-editing logic drives everything. This is the default/recommended target for coding assistants. |
| `http://10.1.10.x:8642/v1` | The Hermes **agent** (gateway API server) | A client that should get Hermes's memory/skills/tool-loop in the response, not just a raw completion. Requests are agent turns, not bare chat completions — expect different latency/behavior than talking to the model directly. |

`10.1.10.x` stands in for this machine's actual LAN address throughout
this README (find it with `ip -4 addr show` if you don't already have it
saved) — the API server is bound to `0.0.0.0:8642` in this deployment, so
it's reachable from other machines on your network, not just `127.0.0.1`.

**To point a CLI client at Hermes instead of llama.cpp:**

1. Get the key: `grep API_SERVER_KEY .env`
2. Configure the client's OpenAI-compatible provider with:
   - Base URL: `http://10.1.10.x:8642/v1`
   - API key: the `API_SERVER_KEY` value from step 1 (sent as `Authorization: Bearer <key>`)
3. Switch back to `http://127.0.0.1:8080/v1` (no key needed) for plain
   completions against the local model.

Verify the server is up and enforcing auth at any time:

```bash
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8642/v1/models          # 401, no key
curl -s -o /dev/null -w '%{http_code}\n' -H "Authorization: Bearer $(grep API_SERVER_KEY .env | cut -d= -f2)" http://127.0.0.1:8642/v1/models   # 200
```

`healthcheck.sh` runs both of these checks automatically on every deploy.

---

## ⚙️ Configuration

Edit `.env` (copied from `.env.example` on first run) to change:

| Variable | Purpose | Default |
|---|---|---|
| `HERMES_IMAGE` / `HERMES_IMAGE_TAG` | Published image + pinned version tag | `nousresearch/hermes-agent` / `v2026.8.13` |
| `HERMES_UID` / `HERMES_GID` | Host user Hermes runs as (auto-set by deploy.sh) | `id -u` / `id -g` |
| `LLAMACPP_BASE_URL` | llama.cpp's OpenAI-compatible endpoint | `http://127.0.0.1:8080/v1` |
| `HERMES_MODEL` | Pin a specific model id when llama.cpp serves more than one | auto-detected |
| `HERMES_DASHBOARD_HOST` / `HERMES_DASHBOARD_PORT` | Dashboard bind address/port | `127.0.0.1` / `9119` |
| `HERMES_DASHBOARD_BASIC_AUTH_USERNAME` / `_PASSWORD` | Required if `HERMES_DASHBOARD_HOST` is non-loopback | unset |
| `HERMES_DASHBOARD_BASIC_AUTH_SECRET` | Session stability secret; auto-generated | unset → auto |
| `API_SERVER_ENABLED` | Turn on the gateway's own OpenAI-compatible API server | `false` |
| `API_SERVER_HOST` / `API_SERVER_PORT` | Bind address/port for that server | `127.0.0.1` / `8642` |
| `API_SERVER_KEY` | Bearer token for that server; auto-generated when enabled | unset → auto |
| `SLACK_BOT_TOKEN` / `SLACK_APP_TOKEN` / `SLACK_ALLOWED_USERS` | Slack platform (Socket Mode) — see [Usage](#-usage) | unset |
| `HERMES_BACKUP_DIR` / `HERMES_BACKUP_KEEP` / `HERMES_BACKUP_REMOTE` | Host-side `backup.sh` destination, retention, optional rsync target | `~/hermes-backups` / `14` / unset |
| `HERMES_BACKUP_NFS_MOUNT` | Host path `backup.sh` verifies is mounted before writing | unset (check skipped) |
| `HERMES_CRON_BACKUP_DEST` / `_KEEP` | Container-side cron backup destination/retention | `/opt/data/backups` / `14` |
| `HERMES_CRON_BACKUP_NFS_MOUNT` | Container path the cron backup verifies is mounted before writing | unset (check skipped) |
| `ALERT_SMTP_FROM` / `ALERT_SMTP_APP_PASSWORD` / `ALERT_EMAIL_TO` | Gmail SMTP alert on backup failure — see [Backups](#-backups) | unset |

Hermes's own config lives at `~/.hermes/config.yaml`:

```yaml
model:
  default: /models/Qwen3.8-27B-Q4_K_M.gguf
  provider: custom
  base_url: http://127.0.0.1:8080/v1
  api_key: none
```

---

## 🏥 Health check

```bash
./healthcheck.sh
```

Checks, in order: gateway/dashboard containers running, llama.cpp
`/v1/models` reachable and context size, dashboard port listening and its
auth gate enforced, the gateway API server's auth boundary (401 without a
key, 200 with one), Hermes's configured provider/base_url/model match what's
expected, no cloud API keys present in `~/.hermes/.env`, and a real
end-to-end test (`hermes -z "Reply with exactly: HERMES_LLAMA_OK"` run
inside the gateway container) proving Hermes → llama.cpp → model actually
works, not just that llama.cpp responds on its own.

---

## 📊 Status

```bash
./status.sh
```

Prints gateway/dashboard state, image tag, llama.cpp reachability and
context size, dashboard auth status, gateway API server status, and the
configured provider/base_url/model.

---

## 📜 Logs

```bash
docker compose logs -f gateway      # supervised gateway output
docker compose logs -f dashboard    # dashboard output
tail -F ~/.hermes/logs/gateways/default/current   # rotated gateway log, survives restarts
tail -F ~/.hermes/logs/container-boot.log          # per-boot reconciler audit log
```

---

## ⬆️ Upgrade

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

---

## 💾 Backups

```bash
./backup.sh
```

Archives `~/.hermes` (config, sessions, memories, skills, credentials) to
a timestamped `tar.gz` under `HERMES_BACKUP_DIR` (`.env`), excluding
`home/.cache` and `lazy-packages/` (pure, regenerable caches — typically
~500MB of the directory's ~520MB, none of it real state). Keeps the
newest `HERMES_BACKUP_KEEP` archives (default 14) and deletes older ones.
Set `HERMES_BACKUP_REMOTE` (e.g. `user@host:/path`) to also `rsync` a
copy to another host you control.

Currently configured to write to `/mnt/vol00/hermes-backups`, an NFS
share (`raptor.lab:/vol00`) rather than local disk — a genuine off-volume
backup. That directory had to be created and `chown`ed to a non-root UID
on the NFS server (raptor.lab) first: the export enforces the standard
`root_squash` behavior, so even `sudo` on this client has no real
authority over it — only a matching non-root UID/GID, set server-side,
can write.

⚠️ **The archive contains real secrets** (Slack tokens, `API_SERVER_KEY`,
the dashboard basic-auth secret, and any OAuth credentials) — it's created
`600`/owner-only, and is **not suitable for git/GitHub, even a private
repo**: private repos still carry exposure risk (a misconfigured
visibility toggle, account compromise, caching/indexing that outlives a
deleted repo) that a local or self-controlled remote backup doesn't. Keep
it on local disk or push it only to hosts you control.

Run it manually before risky changes, or on a cron schedule
(`crontab -e`: `0 3 * * * /path/to/backup.sh >> ~/hermes-backups/backup.log 2>&1`).

### NFS mount verification + failure alerts

Once `HERMES_BACKUP_DIR` (host) or `HERMES_CRON_BACKUP_DEST` (container,
below) actually points at a path under an NFS mount, set the matching
`HERMES_BACKUP_NFS_MOUNT` / `HERMES_CRON_BACKUP_NFS_MOUNT` to that mount's
path (e.g. `/mnt/vol00` on the host, `/opt/backups` inside the container).
Both scripts then verify it's an actual mount point (`mountpoint -q`)
**before** backing up, and if it isn't, **abort without writing
anything** and email an alert — rather than silently writing the backup
to local disk underneath the unmounted mount point, which looks
identical ✅ to a real off-volume backup until you actually need to
restore from it and discover ❌ it never left this host.

The alert email is sent via Gmail SMTP using `curl`'s built-in SMTP
support (no mail server/MTA installed or required). Configure in `.env`:

```
ALERT_SMTP_FROM=<sending gmail address>
ALERT_SMTP_APP_PASSWORD=<Google App Password, not the account password>
ALERT_EMAIL_TO=<recipient address>
```

Generate an App Password at https://myaccount.google.com/apppasswords
(requires 2-Step Verification enabled on that Google account first).

Leaving `HERMES_BACKUP_NFS_MOUNT`/`HERMES_CRON_BACKUP_NFS_MOUNT` unset
(the default) skips the mount check entirely — appropriate while the
backup destination is still local disk, as it is by default today.

### Scheduling via Hermes's own cron instead of host crontab

`hermes-cron-backup.sh` (this repo) is a second, container-native version
of the same idea, meant to be triggered by Hermes's **own** cron scheduler
rather than the host's. `deploy.sh` installs it to
`~/.hermes/scripts/backup-hermes-data.sh` on every run (Hermes's cron
requires scripts to live under `~/.hermes/scripts/`) — `deploy.sh` does
not register the schedule itself. Currently registered, weekly (Sundays
03:00 UTC):

```bash
docker exec hermes hermes cron create '0 3 * * 0' \
  --script backup-hermes-data.sh --no-agent --name hermes-backup
```

Manage it: `docker exec hermes hermes cron {list,pause,resume,remove,runs} hermes-backup`.
Note the job's schedule lives in Hermes's own state (`~/.hermes/cron/`),
not in this repo — redeploying doesn't re-register or change it; edit
with `hermes cron edit` if you want a different cadence.

`--no-agent` skips the LLM entirely (classic watchdog pattern — no tokens
spent) and delivers the script's one-line stdout summary as the job's
result. It writes to `HERMES_CRON_BACKUP_DEST` (currently `/opt/backups`,
bind-mounted in `compose.yaml` from `/mnt/vol00/hermes-backups` — the same
NFS share `backup.sh` uses on the host, so this is a genuine off-volume
backup, not the same-volume fallback). `HERMES_CRON_BACKUP_NFS_MOUNT` is
set to the same path so a dropped mount aborts and emails an alert instead
of silently falling back to the container's own `/opt/data`.

⚠️ **Test as the `hermes` user, not raw `docker exec`.** `docker exec
hermes <cmd>` runs as container **root** by default, and NFS's
`root_squash` maps root to an unprivileged account with no rights over the
`700` backup directory — a manual test as root fails with `chmod:
Operation not permitted` even though the real cron-triggered run (which
executes as the `hermes` user, UID matching the NFS chown) works fine. Use
`docker exec -u hermes hermes bash /opt/data/scripts/backup-hermes-data.sh`
to test manually.

To point this at local disk instead (e.g. before an NFS share exists):
remove the `/opt/backups` volume line in `compose.yaml`'s `gateway`
service, set `HERMES_CRON_BACKUP_DEST=/opt/data/backups`, leave
`HERMES_CRON_BACKUP_NFS_MOUNT` unset, and `./deploy.sh`.

---

## 🗑️ Uninstall

```bash
./uninstall.sh            # removes containers only; ~/.hermes is preserved
./uninstall.sh --purge    # also deletes ~/.hermes -- requires typed confirmation
```

⚠️ `--purge` permanently deletes sessions, memories, skills, config, and
credentials, and requires typing the exact data-directory path to confirm.
Neither mode touches llama.cpp.

---

## 💽 Persistent data

All Hermes state lives under `~/.hermes` (mounted to `/opt/data` in both
containers) and survives container recreation and image upgrades:
config (`config.yaml`), secrets (`.env`), sessions, memories, skills, cron
jobs, hooks, logs, and more. Files are owned by the host user that ran
`deploy.sh` — `HERMES_UID`/`HERMES_GID` in `.env` are set automatically
from `id -u`/`id -g` on every run.

---

## 🔒 Security notes

- **Dashboard**: defaults to `127.0.0.1:9119` — not the LAN. Access it
  locally at `http://127.0.0.1:9119`, or remotely over SSH port forwarding:
  ```bash
  ssh -L 9119:127.0.0.1:9119 user@host
  ```
  Because that bind is loopback, Hermes's dashboard auth gate does not
  engage (it only activates on non-loopback binds).

  **LAN exposure (`HERMES_DASHBOARD_HOST=0.0.0.0`)**: supported (reachable
  at `http://10.1.10.x:9119`), but only with an auth provider configured —
  Hermes hard-fails at startup otherwise. Set `HERMES_DASHBOARD_BASIC_AUTH_USERNAME` and
  `HERMES_DASHBOARD_BASIC_AUTH_PASSWORD` in `.env` (gitignored, never
  committed); `deploy.sh` refuses to proceed with a non-loopback bind
  until both are set, and auto-generates
  `HERMES_DASHBOARD_BASIC_AUTH_SECRET` the first time it's needed so
  sessions survive container restarts. `healthcheck.sh` additionally
  verifies an unauthenticated request against a non-loopback bind does
  **not** return HTTP 200, i.e. that the auth gate is actually active, not
  just configured. Use a real password here — this dashboard can execute
  shell/tool commands on the host.
- **Gateway API server** (`API_SERVER_ENABLED=true`): same LAN-exposure
  tradeoff as the dashboard, protected by `API_SERVER_KEY` (a generated
  bearer token, not a password) rather than a login page. `deploy.sh`
  auto-generates the key the first time the server is enabled and never
  changes it on subsequent runs. `healthcheck.sh` confirms unauthenticated
  requests get HTTP 401 and a correctly-authenticated request gets HTTP
  200 on every deploy. Treat `API_SERVER_KEY` in `.env` like any other
  credential — it's gitignored, and anyone who has it can drive the full
  Hermes agent (memory, skills, tool execution) from the network.
- **Slack**: connects outbound over Socket Mode — no inbound port, no
  public webhook. `SLACK_ALLOWED_USERS` is required alongside the tokens;
  without it Hermes denies every Slack message by default. Anyone who can
  message the bot and is on that allowlist can drive the same
  memory/skills/tool-execution surface as the dashboard and API server.
- **Local-only inference guardrail**: this deployment never writes a cloud
  provider API key (`OPENROUTER_API_KEY`, `ANTHROPIC_API_KEY`,
  `OPENAI_API_KEY`, etc.) into `~/.hermes/.env`. Hermes's `auxiliary.*`
  tasks (compression summaries, vision, web extraction) default to
  `provider: "auto"`, which routes to the **main chat model** — i.e. the
  local `custom` provider configured here — unless `fallback_providers`
  is explicitly configured, which this deployment does not do. With no
  cloud credentials present, any accidental fallback attempt fails loudly
  instead of silently billing a cloud account. If llama.cpp is down, Hermes
  chat/tool calls fail with a connection error rather than routing
  elsewhere. `healthcheck.sh` checks `~/.hermes/.env` for stray cloud keys
  on every run and warns if any are found.
- Never point two Hermes gateway containers at the same `~/.hermes`
  directory simultaneously — session and memory files aren't safe for
  concurrent writes.

---

## 🛠️ Troubleshooting

- [ ] **`deploy.sh` fails at "Nothing is listening on 127.0.0.1:8080"** —
      start `llama-server` first; this deployment does not manage it.
- [ ] **Hermes refuses to start / complains about context length** —
      restart `llama-server` with `--ctx-size 65536` or higher; Hermes
      hard-fails below 64K tokens for agent/tool use.
- [ ] **Tool calls come back as raw text instead of executing** —
      `llama-server` was started without `--jinja`. Restart it with
      `--jinja` and re-run `./deploy.sh`.
- [ ] **Dashboard not reachable remotely** — by design; use the SSH
      tunnel command above rather than changing the bind address.
- [ ] **Slack bot never responds** — confirm `SLACK_ALLOWED_USERS`
      contains your member ID (`hermes status` shows "Slack ✓
      configured" as soon as tokens are set, which isn't proof of a live
      connection — DM the bot to verify end-to-end).

---

## ⚠️ Known limitations

- On first boot, the image seeds `config.yaml` from a bundled template that
  can lag the image's own migration tooling (observed:
  `config-migrate` warning about a config "~2 years old" immediately after
  a fresh seed). This did not affect the `model.*` keys this deployment
  manages and the end-to-end health check still passes, but if you see
  migration warnings in `docker compose logs gateway`, review
  `hermes config check` output before relying on newer config features.
- `hermes config get`/`set` operate on dotted paths (`model.provider`,
  `model.base_url`, `model.default`, `model.api_key`); this deployment does
  not touch `fallback_providers` or `auxiliary.*` — see
  [Security notes](#-security-notes) for why that's intentional.
- `hermes config set` doesn't recognize `SLACK_ALLOWED_USERS` as a schema
  key — `deploy.sh` writes it directly to `~/.hermes/.env` instead (see
  `configure_slack` in `deploy.sh` if you're editing Slack config by hand).
- The gateway API server (when `API_SERVER_ENABLED=true` and bound to
  `0.0.0.0`) combined with the default `terminal.backend: local` means
  anyone with a valid `API_SERVER_KEY` — or, if Slack is also configured,
  anyone on the `SLACK_ALLOWED_USERS` list — can run unsandboxed shell
  commands as the host user. Hermes prints this warning itself on every
  gateway start when both conditions are true. Not changed in this
  deployment by request (single-operator Slack workspace); revisit if that
  changes — see `WORKLOG.md`.

---

## 📄 License

[Apache License 2.0](LICENSE).
