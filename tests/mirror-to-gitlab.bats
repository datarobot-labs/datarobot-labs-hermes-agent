#!/usr/bin/env bats
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

# Behaviour of scripts/mirror-to-gitlab.sh and its workflow: GitLab gets main
# and the v* tags from GitHub and nothing else, a fast-forward at a time. Two
# bare repositories stand in for GitHub and GitLab, and a clone of the first
# is where the script runs, as it does after `actions/checkout`.

setup() {
    WORK=$(mktemp -d)
    export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.com
    export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.com
    export GITLAB_MIRROR_TOKEN=canary-mirror-token-0123456789

    GITHUB="$WORK/github.git"
    GITLAB="$WORK/gitlab.git"
    CLONE="$WORK/clone"
    git init -q --bare -b main "$GITHUB"
    git init -q --bare -b main "$GITLAB"
    git clone -q "$GITHUB" "$CLONE" 2> /dev/null
    git -C "$CLONE" checkout -q -b main
    commit_on_github first
}

teardown() {
    rm -rf "$WORK"
}

# Adds a commit to the clone's main and pushes it to the stand-in for GitHub.
commit_on_github() {
    git -C "$CLONE" commit -q --allow-empty -m "$1"
    git -C "$CLONE" push -q origin main
}

mirror() {
    run sh -c 'cd "$1" && /repo/scripts/mirror-to-gitlab.sh "$2"' _ "$CLONE" "$GITLAB"
}

@test "pushes main and the v tags to GitLab" {
    git -C "$CLONE" tag v1.0.0

    mirror
    [ "$status" -eq 0 ]
    [ "$(git -C "$GITLAB" rev-parse main)" = "$(git -C "$CLONE" rev-parse origin/main)" ]
    [ "$(git -C "$GITLAB" tag --list v1.0.0)" = v1.0.0 ]
}

@test "leaves other branches and tags without a v prefix on GitHub" {
    git -C "$CLONE" branch feature
    git -C "$CLONE" push -q origin feature
    git -C "$CLONE" tag nightly

    mirror
    [ "$status" -eq 0 ]
    [ -z "$(git -C "$GITLAB" branch --list feature)" ]
    [ -z "$(git -C "$GITLAB" tag --list nightly)" ]
}

@test "fast-forwards GitLab when GitHub moves on" {
    mirror
    [ "$status" -eq 0 ]
    commit_on_github second

    mirror
    [ "$status" -eq 0 ]
    [ "$(git -C "$GITLAB" rev-parse main)" = "$(git -C "$CLONE" rev-parse origin/main)" ]
}

@test "refuses a GitLab main that has a commit GitHub lacks, and pushes no tag with it" {
    mirror
    [ "$status" -eq 0 ]

    # Someone commits straight to the GitLab copy.
    git clone -q "$GITLAB" "$WORK/gitlab-clone" 2> /dev/null
    git -C "$WORK/gitlab-clone" commit -q --allow-empty -m "made on GitLab"
    git -C "$WORK/gitlab-clone" push -q origin main
    stray=$(git -C "$GITLAB" rev-parse main)

    commit_on_github second
    git -C "$CLONE" tag v2.0.0

    mirror
    [ "$status" -ne 0 ]
    [ "$(git -C "$GITLAB" rev-parse main)" = "$stray" ]
    [ -z "$(git -C "$GITLAB" tag --list v2.0.0)" ]
}

@test "fails without a token, and pushes nothing" {
    unset GITLAB_MIRROR_TOKEN

    mirror
    [ "$status" -ne 0 ]
    [[ "$output" == *"GITLAB_MIRROR_TOKEN is empty"* ]]
    run git -C "$GITLAB" rev-parse --verify --quiet main
    [ "$status" -ne 0 ]
}

@test "never prints the token" {
    mirror
    [ "$status" -eq 0 ]
    [[ "$output" != *"$GITLAB_MIRROR_TOKEN"* ]]

    # A refused push prints git's error, which is the other place it could leak.
    git clone -q "$GITLAB" "$WORK/gitlab-clone" 2> /dev/null
    git -C "$WORK/gitlab-clone" commit -q --allow-empty -m "made on GitLab"
    git -C "$WORK/gitlab-clone" push -q origin main
    commit_on_github second

    mirror
    [ "$status" -ne 0 ]
    [[ "$output" != *"$GITLAB_MIRROR_TOKEN"* ]]
}

@test "the push never forces, deletes, or mirrors, and it is atomic" {
    run grep -nE -e '--force|--mirror|--prune|--delete|(^|[[:space:]])\+refs' /repo/scripts/mirror-to-gitlab.sh
    [ "$status" -ne 0 ]
    grep -q -e '--atomic' /repo/scripts/mirror-to-gitlab.sh
}

@test "the workflow runs only in this repository, reads the token from an environment, and runs on main, the v tags, and a schedule" {
    run python3 - /repo/.github/workflows/mirror-to-gitlab.yml <<'PY'
import sys, yaml
workflow = yaml.safe_load(open(sys.argv[1]))
on = workflow.get("on", workflow.get(True))  # YAML 1.1 reads a bare `on` as true
job = workflow["jobs"]["mirror"]
assert "github.repository ==" in job["if"], job["if"]
assert job["environment"] == "gitlab-mirror", job["environment"]
assert on["push"]["branches"] == ["main"], on["push"]
assert on["push"]["tags"] == ["v*"], on["push"]
assert "schedule" in on, "no weekly run to report an expired token"
assert "pull_request" not in on, "a pull request must not reach the token"
PY
    [ "$status" -eq 0 ]
}
