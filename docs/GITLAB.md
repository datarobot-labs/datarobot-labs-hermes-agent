# Deploy from GitLab CI/CD

A GitLab CI/CD pipeline can roll out the Hermes Agent workload on every push to the default branch. The file [`.gitlab-ci.yml`](../.gitlab-ci.yml) includes the [`workload-deploy`](https://gitlab.com/datarobot-oss/workload-deploy) component, which runs `dr workload up` for the workload that `.datarobot.yaml` names. The pipeline is off until a project sets a CI/CD variable.

The GitHub equivalent is the `deploy.yml` workflow, described in the "Deploying from CI" section of the [README](../README.md).

## Use the GitLab project as a mirror

The GitLab project is a read-only mirror of the GitHub repository. It carries the code, not the issues or the pull requests. Open issues and pull requests on GitHub.

The workflow [`mirror-to-gitlab.yml`](../.github/workflows/mirror-to-gitlab.yml) pushes `main` and the `v*` tags to the mirror on every push to `main`, once a week, and when a maintainer runs it. A new tag reaches the mirror with the next of those runs. The push is a fast-forward and never forces, so a commit made directly on the default branch of the mirror makes every later push fail. For the setup, see "Maintain the GitLab mirror" in [CONTRIBUTING.md](../CONTRIBUTING.md).

To deploy, create your own private GitLab project from this code. The mirror itself never deploys, because it doesn't set the variable that turns the pipeline on.

## How it works

The pipeline follows the same rules as the GitHub workflow:

- CI never creates a workload. The first deploy runs on your machine, and the manifest it writes holds the workload ID that CI rolls from then on.
- The pipeline runs only on the default branch, and only when `DEPLOY_TO_DATAROBOT` is `true`. Without the variable, the project starts no pipeline.
- The workload keeps its own API key. Before the deploy, the `check-manifest` job fails the pipeline if the manifest gives the workload the token of whoever wrote it.

The following table lists the jobs.

| Job | Stage | What it does |
| --- | --- | --- |
| `check-manifest` | `check` | Runs `scripts/workload-config.sh --check` when the project has a committed `.datarobot.yaml`. |
| `datarobot-deploy` | `deploy` | Installs the pinned DataRobot CLI and runs `dr workload up`. The job links the `datarobot` environment to the endpoint of the workload. |
| `datarobot-stop` | `deploy` | Runs `dr workload stop`. GitLab runs it when the `datarobot` environment stops, and it is also a manual job in the pipeline. Stopping doesn't delete the workload. |

## Set up deployment

To roll out your own deployment from GitLab, complete the following steps.

1. Run the first deploy on your machine with `dr start` and `dr workload up`, as described in the "Deploy your own" section of the [README](../README.md).
2. Commit the manifest to a private project. It holds your credential IDs and Slack channel, and git ignores it by default, so add it with `-f`:

   ```sh
   git add -f .datarobot.yaml
   git commit -m "Add the deploy manifest"
   ```

3. In **Settings > CI/CD > Variables**, add two variables:
   - `DATAROBOT_ENDPOINT`: the URL of your DataRobot install, for example `https://app.datarobot.com`. Leave the variable unmasked, because GitLab hides a masked value in every log line.
   - `DATAROBOT_API_TOKEN`: an API key of the account that ran `dr start`. Mask and protect the variable.

   Set the environment scope of both variables to `datarobot`. Only the deploy and stop jobs run in that environment, so `check-manifest` never sees the token.
4. Add the variable `DEPLOY_TO_DATAROBOT` with the value `true`.
5. Push to the default branch. The pipeline rolls the workload, and the `datarobot` environment shows its endpoint.

The `.env` file stays on your machine. To change a setting, run `dr run env`, commit the updated manifest, and push.

GitLab Free doesn't enforce approvals on environments. To limit who can deploy, protect the default branch, and protect the variables so that only protected branches read them.

## Update the component

The include in `.gitlab-ci.yml` pins the component to a full commit SHA, and the comment next to it names the release. The file pins the job images by digest too, and Dependabot doesn't update them, so update the digests by hand when the base image needs a fix. To update the component, read the [release notes](https://gitlab.com/datarobot-oss/workload-deploy/-/releases), then replace the SHA with the commit of the new release.

The component runs the DataRobot CLI at the version it pins. A release of the component changes that version, so review the change before you merge it.

## Run on a private network

A runner that can't reach `github.com` can't download the deploy scripts or the CLI, and a runner that can't reach DataRobot can't deploy. For a restricted network, see the "Restricted networks" section of the [component documentation](https://gitlab.com/datarobot-oss/workload-deploy#restricted-networks).

## Troubleshoot a failed pipeline

The following table lists common failures.

| Symptom | Cause | Fix |
| --- | --- | --- |
| No pipeline starts. | `DEPLOY_TO_DATAROBOT` isn't `true`, or the push isn't to the default branch. | Add the variable, then push to the default branch. |
| GitLab asks to verify the account before the pipeline runs. | GitLab.com requires identity verification before it runs jobs on shared runners. | Verify the account, or register your own runner. |
| `No workloadId found in .datarobot.yaml` | The commit has no manifest with a workload ID. Git ignores the file by default. | Run the first deploy, then commit the manifest with `git add -f`. |
| `doesn't declare DATAROBOT_API_TOKEN as the workload's own key` | The manifest gives the workload the token of whoever wrote it. | Run `dr run env`, then commit the manifest. |
| `DATAROBOT_ENDPOINT is not set` | The variable is missing, or it is protected and the pipeline runs on an unprotected branch. | Add the variable, and protect the branch. |
| The job log shows `[MASKED]` instead of the endpoint URL. | The `DATAROBOT_ENDPOINT` variable is masked. | Unmask the endpoint, and keep only the token masked. |
| The first call to the endpoint after the first deploy returns HTTP 401 or 503. | The route of a new workload needs up to about 20 seconds after `dr workload up` returns. | Call the endpoint again. |

For more information, see the [component troubleshooting table](https://gitlab.com/datarobot-oss/workload-deploy#troubleshooting) and [TROUBLESHOOTING.md](TROUBLESHOOTING.md).
