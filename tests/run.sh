#!/usr/bin/env bash
# Run the whole suite in a pinned tools image: `task test` or `tests/run.sh`.
# Needs only Docker. Extra arguments go to bats, for example `--filter <regex>`.
set -euo pipefail

repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
image=labs-hermes-tests

docker build --quiet --tag "$image" "$repo/tests" > /dev/null

# The workload runs as uid 1000 on a read-only root with only /tmp writable.
exec docker run --rm \
    --user 1000:1000 --read-only --tmpfs /tmp:exec,mode=1777 \
    --env HOME=/tmp \
    --volume "$repo":/repo:ro --workdir /repo \
    "$image" bats --print-output-on-failure "$@" /repo/tests/static.bats /repo/tests/entrypoint.bats
