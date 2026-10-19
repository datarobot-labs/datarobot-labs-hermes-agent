# Contributing Guidelines

Guidelines for developing and contributing to this project.

## List of project maintainers

- [Andrii Kislitsyn](https://github.com/andriykislitsyn)
- [Carson Gee](https://github.com/carsongee)

## Where to contribute

Contribute on GitHub. The GitLab project is a read-only mirror of the GitHub repository, so open issues and pull requests there.

## Maintain the GitLab copy

A scheduled pipeline in the GitLab project keeps it in step with this repository: `main` and the `v*` tags, nothing else. The job `sync-from-github` in [`.gitlab-ci.yml`](.gitlab-ci.yml) pulls them and pushes them with the job token, so no key or token is stored on GitHub. The `v*` tags follow GitHub exactly: a tag that GitHub moves is moved on GitLab, and a tag that GitHub no longer has is deleted. No other branch or tag is touched. After you tag a release, run the schedule from **Build > Pipeline schedules** to publish the tag at once.

The setup is in "Keep a GitLab project in step with GitHub" in [docs/GITLAB.md](docs/GITLAB.md). For the project of this repository, set `SYNC_FROM_GITHUB` to `true` and keep the schedule owned by a Maintainer.

The sync is a fast-forward, so a commit made directly on the GitLab default branch makes every later run fail. To recover, remove that commit from GitLab, which needs a temporary **Allow force push** on the protected branch, and run the schedule again.

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
