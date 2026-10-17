# AGENTS.md

Guidance for AI coding agents and for people who start here. This repository builds the Hermes Agent image and holds the tooling that deploys it to DataRobot as a Workload. The [README](README.md) is the user guide. This file lists what the README doesn't say.

## Keep these out of the repository

- Never commit `.env`, `.datarobot.yaml`, or `.datarobot/workload/`. Git ignores them here on purpose. A clone that deploys from CI commits its own manifest with `git add -f .datarobot.yaml`, in a private repository.
- Never print or log a token, an API key, or any value from `.env`. The entrypoint logs variable names only, and the tests plant a canary private key to prove it.
- Don't edit `config/skills/datarobot/`. `task skills:datarobot` replaces the folder with a copy of [datarobot-agent-skills](https://github.com/datarobot-oss/datarobot-agent-skills).

## Never deploy from this repository

This is a public repository, and its deploy pipelines are examples. [`.github/workflows/deploy.yml`](.github/workflows/deploy.yml) and [`.gitlab-ci.yml`](.gitlab-ci.yml) run only when the variable `DEPLOY_TO_DATAROBOT` is `true`. Don't set that variable here, and don't add a deploy that runs without it.

The GitLab project is a read-only mirror of the GitHub repository. Make every change on GitHub. To deploy from GitLab, see [docs/GITLAB.md](docs/GITLAB.md).

## Check your change

Run both commands before you open a pull request:

```sh
task test
task lint
```

`task test` needs only Docker. It runs the bats suite in a pinned tools image, as uid 1000 on a read-only root, which is how the workload runs. `task lint` runs shellcheck on the scripts.

When you change a deploy pipeline, a pin, or a rule that keeps secrets out of the repository, update the matching test in `tests/static.bats`. Those tests are the contract.

## Follow these conventions

- Pin every action, component, and image by full commit SHA or digest, with the version in a comment. Tests check the actions and the base image.
- The `dr` version in the `Dockerfile` must be at least the minimum in `.datarobot/cli/versions.yaml`. A test checks it.
- Files under the paths in `.licenserc.yaml` start with the Apache 2.0 header, year included.
- Write documentation to the [Google developer documentation style guide](https://developers.google.com/style): sentence-case headings, imperative steps, present tense, and no "we".

## Know how a deploy behaves

- A workload is identified by the `workloadId` in the committed manifest. `dr workload up` doesn't adopt a workload by name. A run without the ID creates a second workload.
- CI never creates a workload. The first deploy runs on a person's machine.
- The first call to a freshly created endpoint can return HTTP 401 or 503 for about 20 seconds. After a roll, it answers at once.
- A promoted (locked) artifact can't be deleted, so `dr workload delete --purge` leaves it and its credentials.

## Find the details

The following table lists where to look.

| Topic | File |
| --- | --- |
| Deploy, configure, and run locally | [README.md](README.md) |
| Deploy from GitLab CI/CD | [docs/GITLAB.md](docs/GITLAB.md) |
| A failed deploy, the manifest, and Slack | [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) |
| How the image and the sync work | [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) |
| The manifest key check | [scripts/workload-config.sh](scripts/workload-config.sh) |
