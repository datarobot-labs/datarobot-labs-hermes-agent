# Hermes on DataRobot

The `hermes setup` wizard was run once against a local data dir:

```sh
docker run -it --rm -v ./config:/opt/data nousresearch/hermes-agent setup
```

Its output lives in `./config`. This repo bakes the durable half of that into an
image and deploys it as a DataRobot workload.

## Deploy

```sh
dr workload up
```

That is the whole thing. DataRobot builds `./Dockerfile` server-side, injects the
secrets, and rolls the new version onto the existing workload without changing
the endpoint. `dr workload up --dry-run` prints the plan and changes nothing.

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
   bundled skills, then `exec hermes gateway run --no-supervise` so the gateway
   is PID 1 and its exit is the container's exit.

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

- **On boot**, `docker/entrypoint.sh` runs `dr-sync download "$HERMES_HOME"`
  before starting the gateway, restoring whatever the last boot pushed.
- **Every `DR_SYNC_INTERVAL_SECONDS`** (default 600), a background loop the
  entrypoint starts runs `dr-sync upload "$HERMES_HOME"`. There is no
  supervisor in this container to hang a real cron job off of (see above), so
  this is a plain `sleep`-and-upload loop backgrounded before `exec hermes
  gateway run` takes over as PID 1.
- **`config/.drsyncignore`** (baked into the seed alongside `config.yaml`)
  excludes what's baked from the image — `config.yaml`, `SOUL.md`, `skills/`
  — so a stale download can never clobber what the current image just
  shipped, plus pure caches and logs that aren't worth persisting.

This assumes a **single writer**: one replica pushing to one container, so
there's no lock contention to design around. It does not assume the
Workload API's `replicaCount` stays at 1 forever — if that changes, this
sync strategy needs revisiting first.

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

## The health probe

Hermes already serves this — no sidecar. The gateway's `api_server` exposes an
unauthenticated `GET /health`, so the readiness probe just points at it:

```console
$ curl localhost:8642/health
{"status": "ok", "platform": "hermes-agent", "version": "0.20.5"}
```

The port is Hermes' own default, **8642** — the Dockerfile does not override
`API_SERVER_PORT`, and `.datarobot.yaml` is what points at it (both `port:` and
`readinessProbe.port:`). Only the bind host is overridden, to
`API_SERVER_HOST=0.0.0.0`: the default `127.0.0.1` is unreachable from the
kubelet running the probe. The server auto-enables as soon as a usable
`API_SERVER_KEY` exists.

That same server also fronts terminal-capable agent routes, and it logs a
warning about being network-accessible with `terminal.backend: local`. Those
routes are all behind `API_SERVER_KEY`, which the entrypoint generates from
`/dev/urandom` on every boot and never persists or exports — so nothing can
authenticate to them, and only `/health` is reachable. Binding `0.0.0.0` is
required for the kubelet to reach the probe at all. `/health/detailed` is
key-gated and returns 401; use `/health`.

Slack itself needs no inbound port — Socket Mode is an outbound WebSocket.

### One log line that looks like a failure but isn't

The workload logs, on every deploy:

```
Running, not ready (possible probe failure)
Readiness probe failing: HTTP 401 (10 consecutive failures,
  probe_url=https://lrs.../protons/<id>/health)
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
  nousresearch/hermes-agent chat
```

## Operating it

```sh
dr workload get hermes-agent      # status
dr workload logs <id> --follow    # container logs
dr workload stop <id>             # stop / start / delete
```
