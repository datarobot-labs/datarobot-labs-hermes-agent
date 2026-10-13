# Contributing Guidelines

Guidelines for developing and contributing to this project.

## List of project maintainers

- [Andrii Kislitsyn](https://github.com/andriykislitsyn)
- [Carson Gee](https://github.com/carsongee)

## Running the tests

Run `task test` (needs only Docker) before you open a pull request. See the "Tests" section of the [README](README.md).

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
