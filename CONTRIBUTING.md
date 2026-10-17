# Contributing Guidelines

Guidelines for developing and contributing to this project.

## List of project maintainers

- [Andrii Kislitsyn](https://github.com/andriykislitsyn)
- [Carson Gee](https://github.com/carsongee)

## Where to contribute

Contribute on GitHub. The GitLab project is a read-only mirror of the GitHub repository, so open issues and pull requests there.

## Maintain the GitLab mirror

The workflow `.github/workflows/mirror-to-gitlab.yml` keeps the GitLab project in step with this repository: `main` and the `v*` tags, nothing else. The `v*` tags follow GitHub exactly: a tag that GitHub moves is moved on GitLab, and a tag that GitHub no longer has is deleted. No other branch or tag is touched. The workflow runs on pushes to `main`, once a week, and by hand, and never on a tag push, because a tag run would give the deploy key to whatever code the tag points at. A new tag reaches GitLab with the next of those runs, so after you tag a release, run the workflow from `main`. It pushes over SSH with a deploy key, because GitLab Free doesn't offer project access tokens. A deploy key reaches this one project only. Maintainers set it up once and replace it before it expires.

To set up the mirror, complete the following steps.

1. In an empty folder on your machine, generate the key pair:

   ```sh
   ssh-keygen -t ed25519 -N "" -C github-mirror -f mirror-key
   ```

2. In the GitLab project, go to **Settings > Repository > Deploy keys**, and select **Add new key**. Paste the contents of `mirror-key.pub`, select **Grant write permissions to this key**, and set an expiration date.
3. Go to **Settings > Repository > Branch rules**, and open the details of `main`. In **Allowed to push and merge**, select **Edit**, add the deploy key under **Deploy keys**, and save.
4. In the GitHub repository, go to **Settings > Environments**, and create the environment `gitlab-mirror`. Limit its deployment branches and tags to the branch `main`, with no tag rule. Add the contents of `mirror-key`, the private half, as the environment secret `GITLAB_MIRROR_KEY`.
5. Delete `mirror-key` and `mirror-key.pub` from your machine.
6. Run the workflow with **Run workflow**, and check that the GitLab project shows the same commit as `main`.

The weekly run fails once the key expires. To replace it, repeat the steps with a new key, and remove the old key from GitLab. The key can push only while the person who added it keeps access to the GitLab project, so replace it when that person leaves.

The push is a fast-forward, so a commit made directly on the GitLab default branch makes every later run fail. To recover, remove that commit from GitLab, which needs a temporary **Allow force push** on the protected branch, and run the workflow again.

## Running the tests

Run `task test` (needs only Docker) before you open a pull request. See the "Tests" section of the [README](README.md). If the pull request changes a file under `.github`, also run `task lint:workflows`, which audits the workflows with [zizmor](https://docs.zizmor.sh/) and [actionlint](https://github.com/rhysd/actionlint). To include the zizmor audits that query GitHub, run it with `GH_TOKEN` set.

The files listed under `paths` in `.licenserc.yaml` start with the Apache 2.0 header. CI checks it with [SkyWalking Eyes](https://github.com/apache/skywalking-eyes). To run it locally, install it with `go install github.com/apache/skywalking-eyes/cmd/license-eye@v0.9.0`, then run `license-eye -c .licenserc.yaml header fix` to add a missing header.

## Changing the entrypoint

`docker/entrypoint.sh` sources the files in `docker/entrypoint.d/` in order, so they share one shell. To add a boot step, add a file there, then add its `# shellcheck source=` line and `.` line to `entrypoint.sh` in the right place. The Dockerfile copies the whole directory. A snippet must not end on a failing `cmd && cmd` list, because `set -e` then exits the whole shell. Add a test to `tests/entrypoint.bats`, and run `task lint` for shellcheck over the chain.

## Opening new issues

- Before opening a new issue check if there are any existing FAQ entries (if one exists), issues or pull requests that match your case
- Open an issue, and make sure to label the issue accordingly - bug, improvement, feature request, etc...
- Be as specific and detailed as possible

## Did you find a bug?

- Do not open up a GitHub issue if the bug is a security
vulnerability, instead email the maintainers directly or email
oss-community-management@datarobot.com
- Ensure the bug was not already reported in the projects Issues section
- Open an issue as described above

## Responding to issues and pull requests

This project is community maintained. Maintainers respond on a best-effort
basis, with no response-time commitment.

If your issue or pull request gets no response, you can email oss-community-management@datarobot.com
