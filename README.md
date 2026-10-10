# Hermes on DataRobot

> [!NOTE]
> Experimental and community maintained. Not an officially supported DataRobot product, and provided as is with no support commitment.

This repository packages [Hermes Agent](https://github.com/NousResearch/hermes-agent) as a container image and deploys it as a DataRobot workload, with Slack, state persistence and trace export wired up. The `./config` directory holds the durable half of a `hermes setup` data dir, and the Dockerfile bakes it into the image.

Hermes Agent is a project of Nous Research. This repository is not affiliated with or endorsed by Nous Research.

## Quick start

You need Docker, a DataRobot account with Workloads enabled, and the [DataRobot CLI](https://github.com/datarobot-oss/cli) (`dr`) v0.12.0.

Run it locally first. `.env.example` lists every variable:

```sh
cp .env.example .env     # fill in LLM_API_KEY and, for Slack, the two Slack tokens
docker compose up --build
curl localhost:8642/health
```

## Deploy

The first deploy creates the credentials and the manifest. Later deploys only need the last command.

```sh
export DATAROBOT_CLI_FEATURE_WORKLOAD=true   # required by dr v0.12.0
dr workload config --yes                     # reads .env, creates credentials and .datarobot.yaml
dr workload up --yes --lock
```

DataRobot builds `./Dockerfile` server-side, injects the secrets, and rolls the new version onto the existing workload without changing the endpoint. `dr workload up --dry-run` prints the plan and changes nothing.

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

## Swapping the LLM gateway

`config/config.yaml`'s `model:` block is `${LLM_MODEL}` / `${LLM_PROVIDER}` /
`${LLM_BASE_URL}` / `${LLM_API_KEY}` / `${LLM_API_MODE}` — env vars Hermes
substitutes at load time. `LLM_MODEL`, `LLM_PROVIDER`, `LLM_BASE_URL`, and
`LLM_API_MODE` default in the Dockerfile to the current DataRobot LLM gateway;
`LLM_API_KEY` has no default and comes solely from the credential
`.datarobot.yaml` injects. To point at a different `chat_completions`
gateway, override the relevant vars in `.datarobot.yaml`'s `environmentVars`
(or the local `.env` for `docker compose`) — no edits to `config.yaml` needed.

The same exclusions appear twice, because two different mechanisms are at play:

- **`.wapiignore`** decides what `dr workload up` uploads to the artifact. It is
  the one that matters for the deploy — `dr` does not read `.dockerignore`, and
  without this file the sync refuses to run at all (`plan exceeds
  RollbackMaxFiles=1000`).
- **`.dockerignore`** decides what the docker build sees, locally and
  server-side.

Keep the two in step.

`hermes setup` installed `browser-use` into `config/.local` as an arm64 venv. To
get the `browser` and `computer_use` toolsets in the deployed image, build with
`--build-arg WITH_BROWSER_USE=1` — it reinstalls the tool for the image's own
architecture (~220 MB, so it is off by default).

## Adding Python packages

`config/requirements.txt` (empty by default) takes standard pip requirement
lines. The Dockerfile installs it with `uv` — already the base image's own
package manager — straight into `/opt/hermes/.venv`, the same venv Hermes and
its plugins (like hermes-otel above) run on, so anything listed there is
importable from Hermes' own Python process at runtime. No separate venv or
`pip` to reach for: the base image's venv ships no `pip` binary, only `uv`.

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

## Secrets

`config/.env` is **not** in the image and **not** committed. It sits at `./.env`
(gitignored) purely as the local source of truth, and `dr workload config` turned
it into the `environmentVars` block in `.datarobot.yaml`:

- **Secrets** (`LLM_API_KEY`, `SLACK_BOT_TOKEN`,
  `SLACK_APP_TOKEN`) became DataRobot credentials, referenced by id:
  `value: dr-credential:<id>/apiToken`. The values are in DataRobot's credential
  store; the manifest holds only the id.
- **Non-secrets** (`SLACK_ALLOWED_USERS`, `SLACK_HOME_CHANNEL`,
  `DR_SYNC_CATALOG_ID`) are literals.
- **`DATAROBOT_API_TOKEN`** is the odd one out: it's a secret, but not a
  `dr-credential` — it's a platform-injected workload API key (`source:
  api-key`). See "Persisting state across restarts" below.

Nothing needs a `.env` on disk in the container, and the entrypoint never writes
one. Hermes reads these keys straight from the real environment
(`get_env_value`), and Slack turns itself on purely from the presence of
`SLACK_BOT_TOKEN` + `SLACK_APP_TOKEN` — there is no config file entry for it.

To rotate a secret: edit `./.env`, then re-run `dr workload config` in a scratch
copy to mint a new credential, or update the credential in DataRobot directly. To
add a new variable, add it to `./.env` and re-run `dr workload config` — deleting
`.datarobot.yaml` first, since the command is a one-shot.

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
   flush state on SIGTERM — see "Persisting state across restarts").

> **State is per-boot.** `/tmp` is the only writable path and it is not a
> volume, so sessions, memories and `state.db` do not survive a restart on
> their own. The Workload API does not expose a persistent volume — see
> "Persisting state across restarts" below for how this repo works around
> that instead.

## Persisting state across restarts

`$HERMES_HOME` lives on `/tmp`, so a restart would otherwise lose every
session, memory and `state.db` (see above). [`dr-sync`](https://github.com/datarobot/datarobot-sync)
— a single static Go binary, vendored under `vendor/dr-sync/` and `COPY`'d
into the image — mirrors `$HERMES_HOME` against a DataRobot Files API
container instead:

- **On boot**, `docker/entrypoint.sh` logs a `[entrypoint] boot <utc> host=<pod>`
  line, then runs `dr-sync download "$HERMES_HOME"` before starting the
  gateway, restoring whatever the last boot pushed. The download is retried
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
  excludes what's baked from the image — `config.yaml`, `SOUL.md`, `skills/`
  — so a stale download can never clobber what the current image just
  shipped, plus pure caches and logs that aren't worth persisting.
- **Retention** is `--keep-generations 144` (about a day of 10-minute
  uploads), so a bad overwrite can be rolled back (see below).

This assumes a **single writer**: one replica pushing to one container, so
there's no lock contention to design around. It does not assume the
Workload API's `replicaCount` stays at 1 forever — if that changes, this
sync strategy needs revisiting first.

### Checking and recovering state

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

Never point a local `.env` at the production container: a local
`docker compose up` becomes a second writer and its fresh state competes with
the pod's. Create a throwaway container for local runs with `dr sync init
--name hermes-local`.

### Why `dr-sync` is vendored instead of downloaded

Every other pinned tool in the Dockerfile (`gh`, `glab`, `pulumi`, ...) is
`curl`'d from a public release during the build. `dr-sync` can't be: its repo,
`datarobot/datarobot-sync`, is **private**, and the server-side image build
has no GitHub credentials to fetch a release asset with — that `curl` 404s
with no hint why. Its other two distribution channels (the `ghcr.io` image,
the `dr` plugin tarball) are the same private org and fail the same way.

So the two Linux binaries live in the repo, unversioned, at
`vendor/dr-sync/linux_amd64/dr-sync` and `vendor/dr-sync/linux_arm64/dr-sync`
— the Dockerfile just `COPY`s the one matching `TARGETARCH`.
`vendor/dr-sync/VERSION` records which release they came from, since the
binaries themselves don't carry that in their path or filename.

To bump to the latest release (needs `gh` authenticated against the
`datarobot` org):

```sh
task vendor:dr-sync
```

### One-time setup

Create the Files API container once, from a machine with `dr` authenticated
(`dr` discovers the `sync` plugin automatically once installed):

```sh
dr sync init --name "hermes-workload-state"
# create  container <id>
# ...
# export DR_SYNC_CATALOG_ID=<id>
```

Wire the printed id in as `DR_SYNC_CATALOG_ID`:

- **Production** — a plain literal in `.datarobot.yaml`'s `environmentVars`
  (it's not a secret, just a container id).
- **Local dev** — the same variable in `.env`, which `compose.yaml` already
  passes through via `env_file`.

`dr-sync` also needs `DATAROBOT_ENDPOINT` (defaults in the Dockerfile,
alongside the `LLM_*` vars) and `DATAROBOT_API_TOKEN` to call the Files API.
Locally, put `DATAROBOT_API_TOKEN` in `.env` next to the other secrets. In
`.datarobot.yaml` it's wired as a platform-injected workload API key rather
than a manually managed `dr-credential`:

```yaml
- source: api-key
```

This is the newest piece here and unverified end-to-end: the `dr` CLI's own
manifest compiler only knows `dr-credential` as a typed `environmentVars`
source today, so `source: api-key` passes through to the Workload API
verbatim rather than being validated locally. If the server doesn't actually
mount a token from it, that's worth its own ticket against the Workload API.

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
to `LLM_API_KEY`.

The fix is the same shape as `dr-sync`'s and the LLM gateway's: bake a
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

To target a **Use Case** instead of the workload, set
`DATAROBOT_ENTITY_ID=experiment_container-<use_case_id>` explicitly in
`.datarobot.yaml`'s `environmentVars` (a literal, not a secret — the id alone
grants nothing without `DATAROBOT_API_TOKEN`); an explicit value wins over the
`workload-` default, and traces then appear under that Use Case's Tracing tab.

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
must be opened **with its trailing slash** (`dr workload endpoint <id>`
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

Unchanged from before nginx existed: the gateway's own `api_server` still
answers `/health`, unauthenticated, and `.datarobot.yaml`'s `readinessProbe`
still points at it (`path: /health, port: 8642`) — nginx just sits in front
now. It's deliberately **not** routed to hermes-webui (see
`docker/nginx.conf`): the WebUI answering its own health would prove nothing
about whether the gateway's event loop is still alive, and that's the
failure mode a readiness probe exists to catch. `/health/detailed` is
unchanged too — still key-gated, still 401 without `API_SERVER_KEY`.

Slack itself needs no inbound port — Socket Mode is an outbound WebSocket.

### One log line that looks like a failure but isn't

The workload logs, on every deploy:

```
Running, not ready (possible probe failure)
Readiness probe failing: HTTP 401 (10 consecutive failures)
```

That is a *platform-side* check going through the DataRobot edge, and the edge is
an auth gate — it answers the unauthenticated check itself, so the request never
reaches Hermes. Confirmed by hitting the endpoint directly:

```console
$ curl -H "Authorization: Bearer $DATAROBOT_API_TOKEN" "$ENDPOINT/health"
{"status": "ok", "platform": "hermes-agent", "version": "0.20.5"}
$ curl "$ENDPOINT/health"
{"message":"No session cookie"}
```

The Kubernetes readiness probe — the one that decides whether the pod serves —
hits the container directly and passes. Check that rather than the log line:

```sh
dr workload get <id>    # look for ready=true, restartCount=0
```

Before `initialDelaySeconds` was set this appeared as `HTTP 503` instead, because
the check also ran before the gateway had finished booting.

## Local development

`compose.yaml` reproduces all three platform constraints — uid 1000, read-only
rootfs, tmpfs `/tmp` — so a green run locally means something:

```sh
docker compose up --build
curl localhost:8642/health
docker compose exec hermes hermes status
docker compose logs -f
```

Secrets come from `./.env` via `env_file`, the same values the workload gets
from the credential store. It builds `linux/amd64` to match the workload, which
is emulated on Apple Silicon — comment out the `platform:` line for a faster
native loop once you trust the image.

To use the original setup dir interactively instead (a full Hermes home, no
platform constraints):

```sh
docker run -it --rm -v ./config:/opt/data --env-file .env \
  nousresearch/hermes-agent:latest@sha256:d4da4a40cd7a28aba983775d9fd31d94cbf153eeb0cb9e844d6d0f612b7c24db chat
```

## Tests

```sh
task test                       # or tests/run.sh; needs only Docker
task test -- --filter dr-sync   # extra arguments go to bats
```

The suite runs in a tools image pinned by digest (`tests/Dockerfile`) as uid 1000 on a read-only root, like the workload. CI runs the same command on every pull request (`.github/workflows/test.yml`).

- `tests/static.bats`: shellcheck, hadolint, YAML and JSON validity, the base image pinned by digest in the Dockerfile, Taskfile and README, the `dr workload up` upload set (under 1,000 files, no secret files), and a gitleaks scan.
- `tests/entrypoint.bats`: runs `docker/entrypoint.sh` with stub `hermes`, `dr-sync`, `curl` and `nginx` (`tests/fixtures/opt/stubs`), and checks the boot sequence, that no secret value is ever logged, and `nginx -t`.

When you change the entrypoint, add a test for the new behavior to `tests/entrypoint.bats`. When you bump the base image digest, change it in the Dockerfile, the Taskfile and the README together: the suite fails if they differ.

## License and contributing

Apache 2.0, see [LICENSE](LICENSE). Read [CONTRIBUTING.md](CONTRIBUTING.md) and the [code of conduct](CODE_OF_CONDUCT.md) before you open a pull request, and report security issues as described in [SECURITY.md](SECURITY.md).

## Operating it

```sh
dr workload get hermes-agent      # status
dr workload logs <id> --follow    # container logs
dr workload stop <id>             # stop / start / delete
```
