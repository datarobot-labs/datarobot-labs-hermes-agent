# Troubleshooting

Start with:

```sh
dr run doctor
```

It checks your tools, DataRobot login, `.env` and `.datarobot.yaml`, then the
workload's status and `/health`. If something fails, it prints the last 40
lines of the workload's logs.

## `dr` says this isn't a DataRobot Template directory

`dr run`, `dr start` and `dr dotenv` only work at the repo root, where they
find `.datarobot/cli/`. Run them from there. If you are at the root, pull: the
folder was added with the `dr start` onboarding.

## `dr workload`: unknown command

`dr` up to v0.12 hides `dr workload`, or its `config` and `up` subcommands,
until the client-side feature flag is set; v0.13 dropped the gate.
The repo's tasks set it themselves; to run `dr workload ...` directly, export
it first:

```sh
export DATAROBOT_CLI_FEATURE_WORKLOAD=true
```

Your DataRobot install must also have the Workload API enabled
(`ENABLE_WORKLOAD_API_CONTAINERS=true`, set by whoever runs the install). If
`dr workload list` returns 403 or "not enabled", no workload can run there.

## PLACEHOLDER credentials

**Symptom.** `dr workload config` (run by `dr start` or `dr run env`) warns:

```
! LLM_API_KEY was not stored — a credential called "hermes-agent/LLM_API_KEY"
already exists ... keeps PLACEHOLDER ... a deploy will refuse that.
```

and `.datarobot.yaml` has `value: dr-credential:PLACEHOLDER/apiToken`.
`dr run deploy` refuses to run until it's fixed.

**Why.** `dr workload config` names each secret's credential
`<workload name>/<VARIABLE>`. Credentials live server-side, not in the repo,
so if an earlier deploy under the same name already created one, `dr` won't
overwrite a value it can't read, and leaves `PLACEHOLDER` instead. Deleting a
workload doesn't delete its credentials, so this usually comes from a
previous deployment with the same name. Re-cloning changes nothing.

**Fix**, any one of:

1. **Reuse the existing credential.** Find its id in DataRobot (account menu →
   **Credentials**, named `hermes-agent/<VARIABLE>`), and put it in
   `.datarobot.yaml` in place of `PLACEHOLDER`.
2. **Delete the stale credentials** in that same Credentials page, then
   `dr run env`.
3. **Use another name.** Delete `.datarobot.yaml` and run
   `WORKLOAD_NAME=hermes-<something> dr start`.

## `deploy` refuses, or `doctor` says `DATAROBOT_API_TOKEN` isn't the workload's own key

The manifest passes a token from `.env` to the workload, usually your own,
instead of declaring the workload's key (`source: api-key`). Manifests written
before `dr start` existed, or by `dr workload config` run directly, look like
this. Fix it with:

```sh
dr run env
dr run deploy
```

`dr run env` lists `DATAROBOT_API_TOKEN` as removed and then puts the
workload's key in its place, also if you decline that removal. The credential that held your token stays in
DataRobot; delete it from the Credentials page.

## `dr workload up` says `.env` gives `DATAROBOT_API_TOKEN` a different value

Every deploy prints:

```
.env gives 1 declared variable a different value from the manifest, and the
manifest is what deploys: DATAROBOT_API_TOKEN.
  Apply it with 'dr workload up --sync-env'.
```

That difference is intended: `.env` holds your token, the manifest declares
the workload's own key. **Don't apply it**: `--sync-env` would replace the
workload's key with your token. To bring other `.env` changes over, use
`dr run env`.

## HTTP 502 right after a deploy

The gateway is still booting. It takes a minute or two after `dr run deploy`
reports the endpoint; `dr run doctor` shows when `/health` turns 200.

## The workload stopped after 8 hours

A deploy that isn't promoted is a draft, and DataRobot stops drafts after 8
hours. Once it works, keep it with (on `dr` v0.12 the flag is `--lock`):

```sh
dr run deploy -- --promote
```

## `Readiness probe failing: HTTP 401` in the logs

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
{"status": "ok", "platform": "hermes-agent", "version": "0.21.3"}
$ curl "$ENDPOINT/health"
{"message":"No session cookie"}
```

The Kubernetes readiness probe — the one that decides whether the pod serves —
hits the container directly and passes. Check that rather than the log line:
`dr workload status`, or `dr run doctor`.

If it shows `HTTP 503` instead, the check ran before the gateway had finished
booting.

## The Slack bot doesn't answer

- **Nobody is allowed.** An empty `SLACK_ALLOWED_USERS` blocks everyone; it is
  not "allow all". List user ids, or set `GATEWAY_ALLOW_ALL_USERS=true` to let
  the whole workspace in. Re-run `dr dotenv setup` to change it, then
  `dr run env` and `dr run deploy`.
- **The app token is missing a scope.** `SLACK_APP_TOKEN` (`xapp-...`) needs
  `connections:write`, or Socket Mode can't connect. Look for a WebSocket
  connect line in `dr workload logs`.
- **Two bots answer.** Two deployments share one Slack app's tokens. Give each
  deployment its own Slack app (README.md, "Connecting Slack").

## A non-`app` install still reaches `app.datarobot.com`

`dr start` points the LLM gateway at the install `.env` uses, but one URL in
`config/config.yaml` is a literal: the `datarobot` MCP server
(`https://app.datarobot.com/api/v2/genai/globalmcp/mcp`). Edit it to your
install's host before deploying. To find any others:

```sh
grep -rn 'app\.datarobot\.com' config/config.yaml
```

## `LLM_MODEL` ended up as a credential

`dr` decides which `.env` values are secrets partly by how random they look,
and a model id like `anthropic/claude-opus-4-8` passes for a token. If
`.datarobot.yaml` shows `LLM_MODEL` as `dr-credential:...`, it still works, but
changing the model then means updating a credential. Replace that line's value
with the plain model id.

## `dr dotenv validate` printed my token

It prints every value it checks, `DATAROBOT_API_TOKEN` included. Use
`dr run doctor` instead, which keeps only the verdict, and don't paste
`validate` output anywhere.

## Starting over

```sh
dr workload stop
dr workload delete
# Credentials outlive the workload: delete hermes-agent/* in DataRobot's
# Credentials page, or the next deploy under that name gets PLACEHOLDERs.
# So does the artifact:
dr artifact list | grep hermes-agent
dr artifact delete <artifact-id> --yes
rm .datarobot.yaml        # keep .env to skip re-entering settings
dr start
```
