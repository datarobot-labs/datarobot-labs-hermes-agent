# How Hermes Agent on DataRobot works

[README.md](../README.md) covers deploying and operating the agent. This page
explains how the image is put together and why, for when you need to change it.
For things that go wrong, see [TROUBLESHOOTING.md](TROUBLESHOOTING.md).

## Where the config came from

The `hermes setup` wizard was run once against a local data dir, and its
durable output is what `./config` holds. You don't need to run it to deploy:
`config/config.yaml` reads everything that varies per deployment from
environment variables. `task hermes -- setup` still runs it, if you want to
regenerate the config from scratch.

## Where the config lives

`HERMES_HOME` is where Hermes reads `config.yaml`, `SOUL.md` and `skills/` — in
the base image that is `/opt/data`, the path `./config` was mounted at during
setup. Here it moves to `/tmp/hermes`, because that is the only writable path in
the workload (see below). So the seed is baked read-only at `/opt/hermes-seed`
and the entrypoint copies it into `HERMES_HOME` on boot.

Only the portable half of `./config` is baked. The rest is deliberately excluded
(see `.dockerignore`):

| Excluded | Why |
| --- | --- |
| `.env`, `auth.json` | Secrets. Injected as workload env vars instead. |
| `state.db`, `logs/`, `sessions/`, `cache/` | Runtime state; recreated on boot. Freezing it into a layer would ship one boot's state to every replica. |
| `bin/`, `.local/`, `.cua-driver/` | arm64 binaries `hermes setup` installed on the Mac that ran it. The workload image is linux/amd64, and the base image already ships `uv` and a Playwright Chromium of the right arch. |

That drops the build context from 375 MB / 15,277 files to ~50 KB / 492.

## What gets uploaded and built

The same exclusions appear twice, because two different mechanisms are at play:

- **`.drignore`** decides what `dr workload up` uploads to the artifact. It is
  the one that matters for the deploy: `dr` does not read `.dockerignore`, and
  without this file the sync refuses to run at all (`plan exceeds
  RollbackMaxFiles=1000`). `dr` reads the deprecated name `.wapiignore` only as
  a fallback and warns about it on every deploy.
- **`.dockerignore`** decides what the docker build sees, locally and
  server-side.

Keep the two in step.

## The LLM gateway

`config/config.yaml`'s `model:` block is `${LLM_MODEL}` / `${LLM_PROVIDER}` /
`${LLM_BASE_URL}` / `${LLM_API_KEY}` / `${LLM_API_MODE}` — env vars Hermes
substitutes at load time. `LLM_MODEL`, `LLM_PROVIDER` and `LLM_API_MODE`
default in the Dockerfile. `LLM_BASE_URL`, unless set, is derived at boot from
`DATAROBOT_ENDPOINT` (`<DATAROBOT_ENDPOINT>/genai/llmgw`), so any run, a local
`docker compose up` included, uses the gateway of the install it points at.

- **`LLM_BASE_URL`** is set by `dr start` to `$DATAROBOT_ENDPOINT/genai/llmgw`,
  as written. `dr workload config` and docker compose expand it, so a
  deployment on staging or on-prem talks to its own gateway, and it follows a
  changed `DATAROBOT_ENDPOINT` after `dr run env`. Replace it to use another
  gateway.
- **`LLM_MODEL`** is picked by `dr start` from the gateway's model catalog.
- **`LLM_API_KEY`** is optional for the DataRobot LLM gateway: when
  `LLM_BASE_URL` is on the same host as `DATAROBOT_ENDPOINT`, the entrypoint
  defaults it to `DATAROBOT_API_TOKEN`, which that gateway accepts. Any other
  gateway needs its own `LLM_API_KEY`: the entrypoint never sends the
  DataRobot token to another host, and logs that a key is missing instead.
- **`custom_providers[0].base_url` and `model.default`** don't follow the
  `${...}` substitution in the conversation loop (verified 2026-08-24), so the
  entrypoint sets both from `LLM_BASE_URL` and `LLM_MODEL` with
  `hermes config set` on every boot.

To point at a different `chat_completions` gateway, set the relevant vars in
`.env`, `LLM_API_KEY` included, then `dr run env` and `dr workload up` — no
edits to `config.yaml` needed.

One URL is still a literal: the `datarobot` MCP server in `config/config.yaml`
(`https://app.datarobot.com/api/v2/genai/globalmcp/mcp`). On another install,
edit it before deploying, or the agent's DataRobot tools reach across to `app`.

## Secrets

`./.env` is the local source of truth: `dr start` writes it with
`dr dotenv setup`, it is gitignored, and it never enters the image.
`dr workload config` turns it into the `environmentVars` block in
`.datarobot.yaml`. `dr start` runs that for the first manifest, and
`dr run env` re-runs it when `.env` changes.

- **`DATAROBOT_API_TOKEN`** is the exception. In `.env` it is the token of
  whoever ran `dr start`, which `dr` itself and a local `docker compose up`
  use. The workload must not run with it: this agent has a terminal, so
  anything that steers it (a prompt injection, a skill) could read the token
  and act with that person's permissions. The manifest declares the workload's
  own key instead, which the platform fills in:

  ```yaml
  - name: DATAROBOT_API_TOKEN
    source: api-key
  ```

  `dr workload config` can't be told to skip one name, and `--sync-env` drops
  any entry `.env` doesn't name, so `dr start` and `dr run env` call it through
  `scripts/workload-config.sh`, which shows it a copy of the project without
  the token and makes this the token's only entry afterwards, whatever `dr`
  kept. `dr run deploy` refuses, and `dr run doctor` flags, a manifest that
  still passes a token from `.env` on.
- **Secrets** (`SLACK_BOT_TOKEN`, `SLACK_APP_TOKEN`, and `LLM_API_KEY` if you
  set one) become DataRobot credentials named
  `<workload name>/<VARIABLE>`, referenced by id:
  `value: dr-credential:<id>/apiToken`. The values are in DataRobot's credential
  store; the manifest holds only the id.
- **Non-secrets** (`DATAROBOT_ENDPOINT`, `LLM_BASE_URL`, `SLACK_HOME_CHANNEL`,
  `SLACK_ALLOWED_USERS`, `GATEWAY_ALLOW_ALL_USERS`) are literals.

`dr` tells the two apart from the name and the value, and it can be wrong. A
model id like `anthropic/claude-opus-4-8` looks random enough to be filed as a
secret, and so does the state store's id, `DR_SYNC_CATALOG_ID`, 24 hex
characters. The workload reads a credential the same as a literal, so that only
changes how the manifest shows them. After adding a setting, check that `.datarobot.yaml` has the
form you expect.

Nothing needs a `.env` on disk in the container, and the entrypoint never writes
one. Hermes reads these keys straight from the real environment
(`get_env_value`), and Slack turns itself on purely from the presence of
`SLACK_BOT_TOKEN` + `SLACK_APP_TOKEN` — there is no config file entry for it.

To rotate a secret: change it in `./.env`, then `dr run env` (it re-sends the
credentials behind the secrets) and `dr workload up`.

## What the agent can read

Hermes runs the agent's commands in a shell that runs as the same user as Hermes
itself. Anything in the workload's environment is therefore readable by the
agent, and by anything that steers it, such as a prompt injection or a skill.

Hermes removes the variables it knows about, such as the Slack tokens, from the
environment of that shell. This stops casual leaks only. Linux lets a process
read the environment of any other process that runs as the same user, for
example `/proc/1/environ`. The
[Hermes security policy](https://github.com/NousResearch/hermes-agent/blob/main/SECURITY.md)
names the operating system as the only security boundary, and this deployment
adds no sandbox. Treat every value in the table as readable.

| Variable | What it grants | Lifetime | How to rotate |
| --- | --- | --- | --- |
| `DATAROBOT_API_TOKEN` | The permissions of the user who deploys the workload. The Security section of [Workload API best practices](https://docs.datarobot.com/en/docs/workload-api/get-started-workloads/best-practices.html) describes this key. | Managed by DataRobot. | Managed by DataRobot. |
| `SLACK_BOT_TOKEN` | Acting as the bot in every channel it joined. | Until revoked in the Slack app. | Create a new token in the Slack app, then follow the steps to rotate a secret. |
| `SLACK_APP_TOKEN` | Opening the app's Socket Mode connection. | Until revoked in the Slack app. | Generate a new app-level token, follow the steps to rotate a secret, then revoke the old one. |
| `LLM_API_KEY` | Spending on the LLM gateway. On the DataRobot gateway, unless you set a key, it is a copy of `DATAROBOT_API_TOKEN` with the same permissions. Also exported as `<PROVIDER>_API_KEY` when `LLM_PROVIDER` is set. | A copy lasts as long as `DATAROBOT_API_TOKEN`. A key you set lasts until revoked at the gateway that issued it. | A copy rotates with `DATAROBOT_API_TOKEN`. For a key you set, create a new key at the gateway, then follow the steps to rotate a secret. |
| `GH_TOKEN`, `GITLAB_TOKEN` | Whatever the token grants on GitHub or GitLab. Set only when you pass one. | Until it expires or you revoke it at the host. | Create a new token at the host, then follow the steps to rotate a secret. |
| `API_SERVER_KEY` | Calls to the Hermes gateway API, including the terminal-capable and OpenAI-compatible routes that nginx exposes on the workload's port. The entrypoint generates it at each boot unless you set one. | A generated key lasts one boot. A key you set lasts until you change it. | Restart the workload to replace a generated key. For a key you set, change it in `./.env`, then follow the steps to rotate a secret. |
| `GITHUB_PRIVATE_KEY` | Signing in as the GitHub App and minting installation tokens for every installation, with the App's permissions. | Until the key is deleted in the App settings. | Generate a new private key, follow the steps to rotate a secret, then delete the old key. |

Installation tokens last about an hour, and the agent mints them on demand, so
they need no rotation.

## Running under the Workload API's constraints

DataRobot runs the container as **uid 1000** on a **read-only root filesystem
with only /tmp writable**. Both break the base image, and the first deploy
crash-looped on it:

```
/package/admin/s6-overlay/libexec/preinit: fatal: /run belongs to uid 0
instead of 1000, has insecure and/or unworkable permissions, and we're
lacking the privileges to fix it.
s6-overlay-suexec: fatal: child failed with exit code 100
```

Three changes fix it:

1. **`usermod --uid 1000 hermes`.** The image's `hermes` user is uid 10000, and
   its wrapper refuses to run under "an arbitrary, non-hermes UID". Remapping
   makes the platform's uid *be* the hermes uid, so `getpwuid()` resolves and
   the baked files are owned by whoever runs them.
2. **`HERMES_HOME=/tmp/hermes`** (plus `HOME`, `HERMES_WRITE_SAFE_ROOT`,
   `HERMES_LAZY_INSTALL_TARGET`). The seed is baked read-only at
   `/opt/hermes-seed` and copied in on boot.
3. **`docker/entrypoint.sh` replaces the s6-overlay dispatcher.** s6 cannot
   bootstrap as non-root on a read-only rootfs, and nothing here needs
   supervising — the gateway is one foreground process. The entrypoint does the
   handful of things `stage2-hook.sh` did that still apply: copy the seed,
   create the directories Hermes expects, generate an `API_SERVER_KEY`, sync
   bundled skills, then run `hermes gateway run --no-supervise` and wait on it,
   so the gateway's exit is the container's exit (the shell stays PID 1 to
   flush state on SIGTERM — see "Persisting state across restarts"). The boot
   steps live in `docker/entrypoint.d/`, one file per concern: `10-seed.sh`,
   `20-state-sync.sh`, `30-otel.sh`, `40-gateway-env.sh`, `50-skills.sh` and
   `60-services.sh`. `entrypoint.sh` sources them in that order into one shell
   and keeps the gateway start, the SIGTERM trap and the final upload.

> **State is per-boot.** `/tmp` is the only writable path and it is not a
> volume, so sessions, memories and `state.db` do not survive a restart on
> their own. The Workload API does not expose a persistent volume — see
> "Persisting state across restarts" below for how this repo works around
> that instead.

## Persisting state across restarts

`$HERMES_HOME` lives on `/tmp`, so a restart would otherwise lose every
session, memory and `state.db` (see above). [datarobot-sync](https://datarobot-labs.github.io/datarobot-sync/)
(the `dr-sync` binary) — a single static Go binary, downloaded into the image at
build time — mirrors `$HERMES_HOME` against a DataRobot Files API container
instead:

- **On boot**, `docker/entrypoint.sh` logs a `[entrypoint] boot <utc> host=<pod>`
  line, then downloads the store before starting the gateway, restoring
  whatever the last boot pushed. It downloads into an empty directory, then
  moves that into `$HERMES_HOME`: dr-sync fails a download over the image's
  seed if a stored path has another type there (a file where the image ships
  a directory, or the reverse), which would stop every boot. The image wins
  such a conflict, and the log names the path it kept. The download is retried
  (`DR_SYNC_DOWNLOAD_ATTEMPTS`, default 5, with backoff) and, if it still
  fails, the container **exits non-zero** rather than starting with empty
  state — otherwise the first upload would overwrite the good remote copy.
  An empty remote (first deploy) is a successful download and boots normally.
- **Every `DR_SYNC_INTERVAL_SECONDS`** (default 600), a background loop the
  entrypoint starts runs `dr-sync upload "$HERMES_HOME"`. There is no
  supervisor in this container to hang a real cron job off of (see above), so
  this is a plain `sleep`-and-upload loop backgrounded before the gateway
  starts.
- **On shutdown** (Kubernetes moving or stopping the pod sends SIGTERM to
  PID 1), the entrypoint forwards the signal to the gateway, waits for it to
  exit, then runs one final upload bounded by `DR_SYNC_FINAL_TIMEOUT`
  (default 20s, to fit the pod's 30s termination grace period). The gateway
  is therefore a child of the entrypoint shell, not `exec`'d.
- **SQLite databases are snapshotted, not copied live.** Hermes keeps
  `state.db`, `cron/*.db`, `kanban.db`, … open in WAL mode, and copying the
  `.db`/`-wal`/`-shm` files at different instants can yield a mismatched
  trio that silently loses recent writes. Each upload first takes a
  `sqlite3 .backup` copy of every `*.db` into `$HERMES_HOME/.dr-sync-snapshots/`
  (`<path>.db.snap`), and the live `*.db`/`-wal`/`-shm` files are excluded
  from the upload. On boot the snapshots are copied back over the live
  paths.
- **`config/.drsyncignore`** (baked into the seed alongside `config.yaml`)
  excludes what's baked from the image — `config.yaml`, `SOUL.md`,
  `slack-manifest.json`, the optional browser-use install and the file
  itself — so a stale download can never clobber what the current image just
  shipped, plus pure caches and logs that aren't worth persisting. `skills/`
  and `plugins/` are synced, and the image's own are laid over them after the
  download.
- **Retention** is `--keep-generations 144` (about a day of 10-minute
  uploads), so a bad overwrite can be rolled back (see below).

This assumes a **single writer**: one replica pushing to one container, so
there's no lock contention to design around. It does not assume the
Workload API's `replicaCount` stays at 1 forever — if that changes, this
sync strategy needs revisiting first.

Without `DR_SYNC_CATALOG_ID` the entrypoint logs a notice and boots without
persistence.

### How `dr start` sets it up

Every workload gets a store; there's nothing to turn on. `dr start` installs
the `dr sync` plugin (`.datarobot/cli/versions.yaml`), then
`scripts/state-store.sh` keeps the store `.env` names as `DR_SYNC_CATALOG_ID`,
once `dr sync inspect` confirms DataRobot has it, or creates one named
`<workload name>-state` with `dr sync init` and adds its id to `.env`. The
manifest `dr start` writes carries it; for a manifest that already exists, run
`dr run env`, then `dr workload up`. `dr run doctor` checks the store too.

Skills and plugins are part of it, so what the agent learns or adds survives a
restart. On every boot, after the download, the ones this repo's image ships
(`config/skills/`, the plugins in the seed) are laid over the stored copies, so
the current image's version wins, and the ones an earlier image shipped but
this one doesn't are removed: the store keeps a list of every file an image
shipped to it (`.dr-sync-shipped`). An upload never deletes from the store, so
a dropped skill's file stays there, and every boot removes it again. The
hub's `skills/.hub/lock.json` is merged rather than replaced
(`docker/entrypoint.d/hub-lock.py`): the image's records win, and a record for
a skill the agent installed at runtime stays while its skill does. Hermes' own
bundled skills follow its `skills_sync.py`: an unmodified one is updated to the
new image's version, one the agent changed is kept, and one Hermes dropped
stays.

Never point two running copies at one store: a second writer's fresh state
competes with the pod's. So `compose.yaml` leaves a local `docker compose up`
without a store, whatever `.env` says. To give a local run one of its own,
create a separate store (for example `datarobot sync init --name hermes-local`) and
pass its id on the command line, not in `.env`, where `dr run env` would carry
it into the deployed workload:

```sh
LOCAL_DR_SYNC_CATALOG_ID=<id> docker compose up
```

A rolling redeploy is the one time the workload itself has two writers: the
new pod boots and downloads the store while the old one still runs, and the old
one uploads once more on shutdown. dr-sync guards each upload with a lease and
a head check, so the store doesn't get corrupted, but it doesn't merge: what
one pod wrote during the overlap, usually the old pod's last minutes, can be
missing afterwards. Redeploy while the bot is idle. A handoff between the two
pods is a known follow-up.

### Checking and recovering state

These use the `dr sync` plugin, which `dr start` installs. To install it by
hand, see
[datarobot-sync installation](https://github.com/datarobot-labs/datarobot-sync#install).

```sh
# Did the pod restart? One line per boot:
dr workload logs --limit 50000 | grep ' boot '

# What does the remote hold right now, and which generations are retained?
dr sync inspect --catalog-id "$DR_SYNC_CATALOG_ID"
dr sync ls --long --catalog-id "$DR_SYNC_CATALOG_ID" --prefix sessions

# Roll a bad overwrite back: restore an older generation into a scratch dir
# first, look at it, then (with the workload stopped) into the real one.
dr sync download --catalog-id "$DR_SYNC_CATALOG_ID" --generation <N> /some/empty/dir
```

## Exporting traces to DataRobot

[`hermes-otel`](https://github.com/briancaffey/hermes-otel) is a Hermes
plugin that turns LLM calls, tool calls and API requests into OpenTelemetry
spans and exports them to any OTLP backend. The Dockerfile installs it
straight into `$HERMES_SEED` at build time (`hermes plugins install
briancaffey/hermes-otel/hermes_otel --ref <pinned commit>`) so it rides along
with everything else `docker/entrypoint.sh` copies into `$HERMES_HOME` on
boot, and `config/config.yaml`'s `plugins.enabled` turns it on.

`hermes` on `PATH` resolves to a privilege-drop shim that always execs as the
`hermes` user when invoked as root, so that install step has to run after the
Dockerfile's `usermod` remaps that user to uid 1000 — otherwise it dies
writing into a seed directory it can no longer see past the drop.

### Why the backend config is templated, not baked

hermes-otel's generic `otlp` backend type (what DataRobot's OTLP endpoint
needs) only accepts static `headers:` strings — unlike its Langfuse/SigNoz/etc.
backends, it has no `*_env:` indirection for pulling a header value out of an
environment variable at load time. DataRobot's auth is two headers,
`X-DataRobot-Api-Key` and `X-DataRobot-Entity-Id`, and the API key is a
secret — so it can never be written into a config file that lands in a git
commit or an image layer, the same rule the "Secrets" section above applies
to every credential.

The fix is the same shape as datarobot-sync's and the LLM gateway's: bake a
*template*, `config/hermes_otel.yaml.tmpl`, into the seed, and have
`docker/entrypoint.sh` render it into the real `$HERMES_HOME/hermes_otel.yaml`
on every boot via `envsubst`. Export is **on by default**: the entrypoint
renders the template whenever it has everything a successful upload needs — an
entity (defaulted to `workload-${WORKLOAD_ID}`, see below), the
`DATAROBOT_API_TOKEN` the auth header carries, and an endpoint. If any of the
three is missing it skips rendering, so hermes-otel stays unconfigured rather
than exporting with empty/anonymous headers that would 401 on every span.

### The telemetry target

By default a workload's traces land under **its own Tracing tab** (Console →
Deployed workloads → the workload → Tracing). DataRobot's tracing ingest
attributes each span to an entity by parsing its OTel `service.name` as
`<entity_type>-<entity_id>`, so the entrypoint defaults the entity to the
workload itself — `DATAROBOT_ENTITY_ID=workload-${WORKLOAD_ID}` (the platform
injects `WORKLOAD_ID`) — and `config/hermes_otel.yaml.tmpl` sets
`resource_attributes.service.name` to it. (hermes-otel otherwise hardcodes
`service.name` to `hermes-agent`, which matches no entity, so spans would never
appear.) No Use Case or manual wiring is required.

`DATAROBOT_OTEL_ENDPOINT` is derived at boot from `DATAROBOT_ENDPOINT` (trim
trailing slashes, strip `/api/v2`, add `/otel`), so export follows whichever
install the workload runs on — `app`, staging or on-prem — with no hardcoded
host. Set `DATAROBOT_OTEL_ENDPOINT` explicitly only to override that.

To target a **Use Case** instead of the workload, add
`DATAROBOT_ENTITY_ID=experiment_container-<use_case_id>` to `.env` and run
`dr run env` (it is a literal, not a secret — the id alone grants nothing
without `DATAROBOT_API_TOKEN`); an explicit value wins over the `workload-`
default, and traces then appear under that Use Case's Tracing tab.

For a local live view of spans (independent of the DataRobot export):

```sh
dr plugin install xp                                        # one-time
dr xp --entity-id <id> --enable-logs --enable-metrics
```

then open `http://127.0.0.1:8090`. Use the bare id, not the `workload-` /
`experiment_container-` prefixed form.

### Upgrading the plugin

`hermes plugins install --ref` pins to a commit so a rebuild months from now
doesn't silently pick up whatever `main` has drifted to. To move to a newer
release, bump `HERMES_OTEL_REF` in the Dockerfile to the new tag's commit SHA.

## Serving a web UI on the workload endpoint

Browsing the workload's endpoint used to 404: the gateway's own `api_server`
only defines `/v1/*` and `/health`, no root route. nginx now fronts the
single port the workload exposes (**8642**, unchanged) and splits traffic by
path between two backends that both run inside this same container:

```
external :8642  ->  nginx (docker/nginx.conf)
                     |-- /health  /health/detailed  /v1/*  /p/*        -> 127.0.0.1:8643  hermes gateway api_server
                     |-- /api/jobs*  /api/cron/fire  /api/model/options
                     |     /api/platforms/*/events                    -> 127.0.0.1:8643  hermes gateway api_server
                     '-- everything else (webui shell, static, its own
                          /api/* namespace, including /api/sessions*)  -> 127.0.0.1:8787  hermes-webui
```

`/health` and a handful of the gateway's own `/api/*` routes are deliberately
kept on the gateway rather than falling under the WebUI's catch-all — see
`docker/nginx.conf` for the full reasoning. In short: `/health` is the
readiness probe target, and routing it to the WebUI instead would stop
catching a wedged gateway event loop; `/api/jobs`, `/api/cron/fire`,
`/api/model/options` and `/api/platforms/*/events` are a different namespace
than the WebUI's own much larger `/api/*` surface and would otherwise become
unreachable. One exception on purpose: the gateway also has its own
`/api/sessions*` HTTP API, but hermes-webui claims that *exact same path*
for its own session list (the whole left-sidebar UI is built on it) — two
apps can't share one path, and the WebUI's UI wins, so the gateway's
`/api/sessions*` is not reachable through this endpoint.

[hermes-webui](https://github.com/nesquena/hermes-webui) is baked into the image
(`/opt/hermes-webui`, pinned via `HERMES_WEBUI_REF` — the upstream repo cuts
releases several times a day, so bump the tag deliberately rather than
floating on a branch). Its browser chat is configured to run turns through
this container's own gateway (`HERMES_WEBUI_CHAT_BACKEND=gateway`) rather than
its own default in-process runtime, so there is exactly one agent process
touching `HERMES_HOME`, not two competing ones.

hermes-webui emits relative asset and API URLs (`static/style.css`,
`fetch('api/...')`), which is what lets it work unmodified under the
DataRobot edge's stripped path prefix — but it also means the endpoint URL
must be opened **with its trailing slash** (`dr workload endpoint`
already prints it that way); without it, the browser resolves those relative
URLs one directory up and everything 404s.

The WebUI's own login (`HERMES_WEBUI_PASSWORD`) is unset because the
DataRobot edge already requires a login. Run this image only behind an
authenticating proxy, and keep the container's port private otherwise.

`API_SERVER_HOST`/`API_SERVER_PORT` moved the gateway's own API off the public
port entirely, to `127.0.0.1:8643` — nginx is now the only thing bound to a
non-loopback address. That server still fronts terminal-capable agent routes
and the OpenAI-compatible `/v1` API, still gated by `API_SERVER_KEY` (the
entrypoint generates it from `/dev/urandom` on every boot and never persists
or exports it), reachable through nginx at the same paths as before.

## The health probe

```console
$ curl localhost:8642/health
{"status": "ok", "platform": "hermes-agent", "version": "0.21.3"}
```

The gateway's own `api_server` answers `/health`, unauthenticated, and nginx
sits in front of it. `dr start` writes the manifest with
`--health /health`, so `.datarobot.yaml`'s `readinessProbe` points at it
(`path: /health, port: 8642`). A manifest written some other way may have no
probe at all; add that block under the container to get one.

It's deliberately **not** routed to hermes-webui (see `docker/nginx.conf`):
the WebUI answering its own health would prove nothing about whether the
gateway's event loop is still alive, and that's the failure mode a readiness
probe exists to catch. `/health/detailed` is key-gated, 401 without
`API_SERVER_KEY`.

Slack itself needs no inbound port — Socket Mode is an outbound WebSocket.

The workload logs a platform-side `Readiness probe failing: HTTP 401` line on
every deploy that is not a real failure; see
[TROUBLESHOOTING.md](TROUBLESHOOTING.md).

## Bundled toolchain

The image carries a working set for autonomous coding, git, pipeline and
documentation work. The base image already provided node + npm, git, uv/uvx,
ripgrep, gcc/g++, make, the docker CLI and ffmpeg; the Dockerfile adds:

| Area | Tools |
| --- | --- |
| Languages | **Go 1.27**, Node 26 + npm (base), Python 3.13 + uv/uvx (base) |
| Forges | **`gh`** 2.98, **`glab`** 1.114, `git-lfs`, `git-delta`, `openssh-client` |
| DataRobot | **`dr`** — this project's own deploy tool, so an agent in here can redeploy, read logs and inspect workloads |
| Pipelines / IaC | `task`, `kubectl`, `helm`, `pulumi` (with its language plugins) |
| Data wrangling | `jq`, `yq`, `sqlite3`, `fd`, `bat`, `tree`, `file` |
| Docs | `pandoc`, `graphviz` |
| Lint / format | `ruff`, `tsc`, `prettier`, `shellcheck` |
| Diagnostics | `procps`, `psmisc`, `iproute2`, `dnsutils`, `netcat`, `rsync`, `less` |

Versions are pinned as build `ARG`s (`GO_VERSION`, `GH_VERSION`, …) so a rebuild
months from now yields the same image; bump one to upgrade one tool. apt
packages are deliberately *not* pinned — Debian drops old point versions from
the archive, so pinning them makes the build fail over time rather than stay
reproducible.

`hermes setup` installed `browser-use` into `config/.local` as an arm64 venv. To
get the `browser` and `computer_use` toolsets in the deployed image, build with
`--build-arg WITH_BROWSER_USE=1` — it reinstalls the tool for the image's own
architecture (~220 MB, so it is off by default).

### Why this needs more than `apt install`

**Everything writes to /tmp.** Each of these tools wants a cache, config or
state directory, and every one of them defaults to somewhere outside `/tmp` —
which is read-only here. So the Dockerfile redirects them all under
`$TOOLS_HOME=/tmp/tools` (`GOPATH`, `GOCACHE`, `GOMODCACHE`, `npm_config_cache`,
`UV_CACHE_DIR`, the `XDG_*` dirs, `GH_CONFIG_DIR`, `GLAB_CONFIG_DIR`,
`PULUMI_HOME`, `KUBECONFIG`, the `HELM_*` dirs), and the entrypoint creates the
tree on boot because `/tmp` starts empty. Without that, `go build` fails with
EROFS rather than doing anything useful. `/tmp/tools` is kept *outside*
`HERMES_HOME` so tool state never collides with Hermes' own layout.

Tool config is therefore per-boot too, same as Hermes' state: `gh auth login`
does not survive a restart. Pass tokens as environment variables instead —
`GH_TOKEN`, `GITLAB_TOKEN`, `DATAROBOT_API_TOKEN` — which is what these CLIs
prefer anyway in non-interactive use.

**The sqlite3 CLI needed pinning.** Debian's `sqlite3` binary is built against
Debian's libsqlite3, but the base image ships a newer libsqlite3 (3.53.4) in
`/usr/local/lib` that wins the linker's search order. The CLI then aborts on
*every* invocation with `SQLite header and source version mismatch` — it will
not run `select 1`. A wrapper at `/usr/local/bin/sqlite3` pins that one binary
to the library it was compiled against. The global linker path is untouched on
purpose: Python's `sqlite3` resolves to the newer `/usr/local` build, which is
what Hermes' `state.db` uses for WAL journalling.

**Pipe failures had to be made fatal.** The downloads are all `curl | tar`, and
under `/bin/sh` (dash, no `pipefail`) a failed `curl` is silently swallowed,
producing an image with missing binaries. The toolchain stages set
`SHELL ["/bin/bash", "-o", "pipefail", "-c"]` so a bad URL fails the build.

### Acting on GitHub as itself (GitHub App identity)

Rather than a personal `GH_TOKEN`, this workload can authenticate as its own
GitHub App installation, so commits and PRs show up as the bot, not a
human's token. Three env vars drive it:

- `GITHUB_APP_ID` — the App's numeric ID (distinct from the installation ID).
- `GITHUB_PRIVATE_KEY` — the App's PEM private key, as a literal env value
  (no file on disk needed).
- `GITHUB_INSTALLATION_IDS` — comma-separated installation IDs, one per org
  the App is installed on. Plural and comma-separated on purpose: a single
  App registration can be installed on multiple orgs, letting one workload
  act across all of them without re-registering per org.

At runtime: sign a short-lived JWT (`iss: GITHUB_APP_ID`, RS256, ≤10 min
expiry) with `GITHUB_PRIVATE_KEY`, then exchange it at
`POST /app/installations/<id>/access_tokens` for each id in
`GITHUB_INSTALLATION_IDS` to get a ~1-hour installation token scoped to that
org's repos. Use the token as the `x-access-token` password over HTTPS git, or
as a bearer token against the REST API — no interactive `gh auth login`
required, and nothing here needs to survive a restart since tokens are minted
fresh every boot.

### Size

The toolchain costs about **1.3 GB** on top of the 2.7 GB base (3.98 GB total).
The four biggest items, if you need to trim:

| | |
| --- | --- |
| `pulumi` (incl. language plugins) | 314 MB |
| Go toolchain | 282 MB |
| `pandoc` | 189 MB |
| npm globals (`tsc`, `prettier`) | 59 MB |

Not included, as nothing here implied them: the AWS/Azure/GCP CLIs, Rust,
Java/JVM, Terraform. Each is one more line in the same pattern.
