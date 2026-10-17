#!/usr/bin/env bash
# Copyright 2026 DataRobot, Inc. and its affiliates.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

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
    "$image" bats --print-output-on-failure "$@" /repo/tests/static.bats /repo/tests/entrypoint.bats /repo/tests/nginx.bats /repo/tests/smoke.bats \
    /repo/tests/workload-config.bats /repo/tests/llm-gateway-url.bats \
    /repo/tests/install-skill.bats /repo/tests/dr-version.bats /repo/tests/mirror-to-gitlab.bats
