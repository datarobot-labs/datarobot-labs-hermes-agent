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

## The Workload API isn't enabled

If `dr workload list` returns HTTP 403 or "not enabled", the DataRobot install doesn't have the Workload API enabled, and no workload can run there. An administrator of the install sets `ENABLE_WORKLOAD_API_CONTAINERS=true`.

If `dr` reports `workload` as an unknown command, the installed `dr` is older than v0.14.1. Run `dr self update`.

## PLACEHOLDER credentials

**Symptom.** `dr workload config` (run by `dr start` or `dr run env`) warns:

```
! LLM_API_KEY was not stored — a credential called "hermes-agent/LLM_API_KEY"
already exists ... keeps PLACEHOLDER ... a deploy will refuse that.
```

and `.datarobot.yaml` has `value: dr-credential:PLACEHOLDER/apiToken`.
`dr workload up` refuses to deploy it until it's fixed.

**Why.** `dr workload config` names each secret's credential
`<workload name>/<VARIABLE>`. Credentials live server-side, not in the repo,
so if an earlier deploy under the same name already created one, `dr` won't
overwrite a value it can't read, and leaves `PLACEHOLDER` instead. `dr workload
delete` leaves a workload's credentials in place unless it runs with `--purge`,
so this usually comes from a previous deployment with the same name.
Re-cloning changes nothing.

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
dr workload up
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

The gateway is still booting. It takes a minute or two after `dr workload up`
reports the endpoint; `dr run doctor` shows when `/health` turns 200.

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
  `dr run env` and `dr workload up`.
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

## State store not found

**Symptom.** `dr start` or `dr run doctor` says `DataRobot can't give state
store <id>`, or the workload restarts in a loop and its log shows `FATAL:
dr-sync download failed`.

**Why.** `DR_SYNC_CATALOG_ID` in `.env` names a store DataRobot doesn't have:
deleted, from another install, or mistyped. `dr start` won't replace it on its
own, since a new store starts from nothing.

**Fix.** Put the right store's id in `.env` as `DR_SYNC_CATALOG_ID`, or delete
the line and run `dr start` to create a new store. Then `dr run env` and
`dr workload up`. The workload logs the id it uses on every boot:
`dr workload logs | grep dr_sync_catalog=`. That's also where to find it when
`dr start` says `.datarobot.yaml` already gives the workload a store but `.env`
has none.

## `dr dotenv validate` printed my token

It prints every value it checks, `DATAROBOT_API_TOKEN` included. Use
`dr run doctor` instead, which keeps only the verdict, and don't paste
`validate` output anywhere.

## Start over

To deploy from scratch, delete the workload together with what the deploy created beside it, then run `dr start` again:

```sh
dr workload delete --purge
# Keep .env to skip re-entering settings.
rm .datarobot.yaml
dr start
```

`--purge` also removes the credentials the project created, its draft artifact, and the local sync state in `.datarobot/workload/`. Without it, the next deploy under the same name gets `PLACEHOLDER` credentials.

A locked artifact (`--lock`) can't be deleted: DataRobot refuses to delete a locked artifact. `--purge` keeps it, keeps the credentials it uses, and `dr` names them. A credential that another project created also stays. After a purge that kept credentials, the next deploy under the same name gets `PLACEHOLDER` credentials too. Don't delete the kept credentials: the locked artifact or the other project still uses them. Reuse them as in option 1 of [PLACEHOLDER credentials](#placeholder-credentials), or deploy under another name with `WORKLOAD_NAME=hermes-<something> dr start`.
