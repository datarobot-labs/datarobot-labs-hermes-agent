# Hermes on DataRobot

> [!NOTE]
> Experimental and community maintained. Not an officially supported DataRobot product, and provided as is with no support commitment.

This repository packages [Hermes Agent](https://github.com/NousResearch/hermes-agent), an autonomous agent,
as a container image and deploys it as a DataRobot workload. It runs on
DataRobot's LLM gateway, serves a web UI on the workload's endpoint, can join
Slack as a bot, and carries tools for coding, git and working with DataRobot
itself.

Hermes Agent is a project of Nous Research. This repository is not affiliated with or endorsed by Nous Research.

## Deploy your own

You need a DataRobot account with Workloads enabled, and the DataRobot CLI
logged in to that install:

```sh
brew install datarobot-oss/taps/dr-cli          # or: curl -fsSL https://cli.datarobot.com/install | sh
dr auth login                                   # e.g. dr auth login https://staging.datarobot.com
```

Then, from a clone of this repo:

```sh
dr start
dr run deploy
```

**`dr start`** sets up the clone, and is safe to re-run:

- checks your `dr` version and installs [Task](https://taskfile.dev) if it's missing;
- writes `.env`, asking only for what's missing: whether to connect Slack, and
  if so its tokens. Your DataRobot URL and API token come from your `dr` login;
- writes `.datarobot.yaml`, the deploy manifest: built from the Dockerfile,
  1 CPU / 2 GB, a readiness probe on `/health`, and the secrets in `.env`
  stored as DataRobot credentials rather than in the file. Your own API token
  isn't one of them: the workload gets a key of its own from the platform.

**`dr run deploy`** runs `dr workload up`: it uploads the repo, DataRobot builds
the image (a few minutes the first time) and starts the workload, and later
deploys roll out only what changed. Add `-- --dry-run` to preview a deploy.

The first deploy is a draft, which DataRobot stops after 8 hours. Once it
works, keep it running (on `dr` v0.12 the flag is `--lock`):

```sh
dr run deploy -- --promote
```

To open the web UI, open the URL `dr workload endpoint` prints, with its
trailing slash. To check that everything is healthy:

```sh
dr run doctor
```

On an install other than `app.datarobot.com`, also see
[TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md#a-non-app-install-still-reaches-appdatarobotcom).
Each deployment needs its own name: to deploy a second copy, run
`WORKLOAD_NAME=hermes-<something> dr start` in a fresh clone.

## Connecting Slack

Slack is optional; without it the agent is still reachable through the web UI.
Each deployment needs its own Slack app, or two bots answer every message.

1. Create the app at [api.slack.com/apps](https://api.slack.com/apps) →
   **Create New App** → **From a manifest**, and paste
   `config/slack-manifest.json`. Rename the app in it first if a "Labs Agent"
   already exists in the workspace.
2. Install it to the workspace (**OAuth & Permissions** → **Install to
   Workspace**). Your Slack admins may need to approve it.
3. Copy two tokens: the **Bot User OAuth Token** (`xoxb-...`) from OAuth &
   Permissions, and an **app-level token** (`xapp-...`) with the
   `connections:write` scope from **Basic Information**.
4. Run `dr dotenv setup`, answer **Yes** to Slack, and enter the tokens and who
   may use the bot. An empty allowlist blocks everyone.
5. Ship it:

   ```sh
   dr run env
   dr run deploy
   ```

Slack needs no inbound URL: the bot connects out over Socket Mode.

## Adding skills

Skills are baked into the image from `config/skills/`. Install one, commit it,
and deploy:

```sh
dr run install:official/creative/ascii-art      # one of Hermes' optional skills
dr run install:<owner>/<repo>/<path>            # a skill on GitHub
dr run deploy
```

`install` runs `hermes skills install` in the pinned Hermes image, so it needs
Docker. To see what's available, run `task hermes -- skills browse`. The
DataRobot skills in `config/skills/datarobot/` come from
[datarobot-agent-skills](https://github.com/datarobot-oss/datarobot-agent-skills);
`dr run skills:datarobot` refreshes them.

## Adding Python packages

`config/requirements.txt` takes standard pip requirement lines. The Dockerfile
installs it with `uv` straight into `/opt/hermes/.venv`, the venv Hermes and
its plugins run in, so anything listed there is importable from Hermes' own
Python process. Deploy to ship a change.

## Changing settings

`.env` is the source of truth for the workload's environment. Change it by
hand or with `dr dotenv edit`, then copy the change into `.datarobot.yaml` and
deploy:

```sh
dr run env
dr run deploy
```

Use `dr run env` rather than `dr workload config --sync-env` or
`dr workload up --sync-env`: those copy every name in `.env` into the
workload, your own `DATAROBOT_API_TOKEN` included, in place of the workload's
own key. `dr run deploy` refuses `--sync-env` for that reason.

Settings you might change:

| Variable | What it does |
| --- | --- |
| `LLM_MODEL` | The model, by its LLM gateway id. Defaults to `anthropic/claude-opus-4-8`. After `dr run env`, check `.datarobot.yaml` holds it as a plain value ([why](docs/TROUBLESHOOTING.md#llm_model-ended-up-as-a-credential)). |
| `LLM_BASE_URL`, `LLM_API_KEY`, `LLM_PROVIDER`, `LLM_API_MODE` | A different `chat_completions` gateway. `dr start` keeps `LLM_BASE_URL` on the gateway of your `DATAROBOT_ENDPOINT`; to set your own, delete the marker line above it in `.env`. See [The LLM gateway](docs/ARCHITECTURE.md#the-llm-gateway). |
| `DR_SYNC_CATALOG_ID` | Keeps sessions and memory across restarts. See [Turning persistence on](docs/ARCHITECTURE.md#turning-persistence-on). |
| `DATAROBOT_ENTITY_ID` | Where traces go. See [The telemetry target](docs/ARCHITECTURE.md#the-telemetry-target). |
| `GH_TOKEN`, `GITLAB_TOKEN`, `GITHUB_APP_ID`, … | Let the agent work on GitHub or GitLab. See [Acting on GitHub as itself](docs/ARCHITECTURE.md#acting-on-github-as-itself-github-app-identity). |

## Day to day

```sh
dr run doctor                  # is everything healthy?
dr workload logs --follow      # container logs
dr workload status             # running, stopped, ...
dr workload stop               # and start
dr run deploy                  # ship what changed
dr task list --all             # every task this repo defines
```

Run `dr workload` commands from the repo root, where they find the workload
in `.datarobot.yaml`. With `dr` v0.12 or older, `export
DATAROBOT_CLI_FEATURE_WORKLOAD=true` first; the `dr run` tasks set it for you.

## Local development

`compose.yaml` reproduces all three platform constraints — uid 1000, read-only
rootfs, tmpfs `/tmp` — so a green run locally means something:

```sh
docker compose up --build
curl localhost:8642/health
docker compose exec hermes hermes status
docker compose logs -f
```

Settings come from `./.env` via `env_file`, the same values the workload gets
from the credential store. If you haven't run `dr start`, copy `.env.example`
to `.env` and fill it in; it lists every variable. It builds `linux/amd64` to match the workload, which
is emulated on Apple Silicon — comment out the `platform:` line for a faster
native loop once you trust the image.

To use the original setup dir interactively instead (a full Hermes home, no
platform constraints):

```sh
docker run -it --rm -v "$PWD/config:/opt/data" --env-file .env \
  nousresearch/hermes-agent:latest@sha256:d4da4a40cd7a28aba983775d9fd31d94cbf153eeb0cb9e844d6d0f612b7c24db chat
```

## Tests

```sh
task test                       # or tests/run.sh; needs only Docker
task test -- --filter dr-sync   # extra arguments go to bats
task test:image                 # or tests/smoke.sh; builds and boots the real image
```

The suite runs in a tools image pinned by digest (`tests/Dockerfile`) as uid 1000 on a read-only root, like the workload. CI runs the same command on every pull request (`.github/workflows/test.yml`).

- `tests/static.bats`: shellcheck, hadolint, YAML and JSON validity (including `.datarobot/cli/`), the base image pinned by digest in the Dockerfile, Taskfile and README, the `dr workload up` upload set (under 1,000 files, no secret files), and a gitleaks scan.
- `tests/entrypoint.bats`: runs `docker/entrypoint.sh` with stub `hermes`, `dr-sync`, `curl`, `nginx`, `python` and `sqlite3` (`tests/fixtures/opt/stubs`), and checks the boot sequence, that no secret value is ever logged, and `nginx -t`.
- `tests/nginx.bats`: runs `docker/nginx.conf` in front of two stand-in upstreams and checks which one answers `/health`, `/v1`, `/api/jobs` and everything else. The platform's readiness probe hits `/health`, so it must reach the gateway and never the web UI.
- `tests/smoke.bats`: the checks in `tests/smoke.sh`, against a stub `docker`.

`task test:image` builds the image (about 4 GB, slow the first time) and boots it with no network, as uid 1000 on a read-only root, with dummy Slack, GitHub and DataRobot values that include a canary private key, and a `WORKLOAD_ID` so OTel export takes the deployed path. It passes when `/health` answers 200 and keeps answering after the Slack connection has failed, the skills step has put skills in `HERMES_HOME`, and no secret value appears in the log. `SMOKE_IMAGE=<tag>` tests an image you already built. CI runs it on pull requests that touch the image, and weekly (`.github/workflows/image.yml`).

When you change the entrypoint, add a test for the new behavior to `tests/entrypoint.bats`. When you bump the base image digest, change it in the Dockerfile, the Taskfile and the README together: the suite fails if they differ.

## How it works

- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md): how the image is built to run
  under the Workload API, secrets, persistence, tracing, the web UI and the
  bundled toolchain.
- [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md): known failures and their
  fixes.
- `.datarobot/cli/`: what `dr start` checks for (`versions.yaml`) and asks for
  (`prompts.yaml`).

## License and contributing

Apache 2.0, see [LICENSE](LICENSE). Read [CONTRIBUTING.md](CONTRIBUTING.md) and the [code of conduct](CODE_OF_CONDUCT.md) before you open a pull request, and report security issues as described in [SECURITY.md](SECURITY.md).
