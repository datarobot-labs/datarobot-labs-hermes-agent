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

# Behaviour of scripts/sync-from-github.sh and the GitLab job that runs it:
# the GitLab project gets main and the v* tags from GitHub and nothing else, a
# fast-forward at a time. Two bare repositories stand in for GitHub and GitLab.
# The script runs in an empty directory, as it does in a job whose checkout it
# must not depend on. A stub `git` refuses `ls-remote` on request, the one
# failure a local path can't produce.

setup() {
    WORK=$(mktemp -d)
    export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.com
    export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.com
    mkdir -p "$WORK/bin" "$WORK/runner"

    REAL_GIT=$(command -v git)
    export REAL_GIT
    cat > "$WORK/bin/git" <<'STUB'
#!/bin/sh
if [ -n "${STUB_FAIL_LISTING:-}" ] && [ "$1" = ls-remote ]; then
    echo "listing refused" >&2
    exit 128
fi
exec "$REAL_GIT" "$@"
STUB
    chmod +x "$WORK/bin/git"
    PATH="$WORK/bin:$PATH"

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

# Someone commits straight to the GitLab copy.
commit_on_gitlab() {
    git clone -q "$GITLAB" "$WORK/gitlab-clone" 2> /dev/null
    git -C "$WORK/gitlab-clone" commit -q --allow-empty -m "made on GitLab"
    git -C "$WORK/gitlab-clone" push -q origin main
}

# Tags the clone's main and pushes the tag to the stand-in for GitHub.
tag_on_github() {
    git -C "$CLONE" tag "$1"
    git -C "$CLONE" push -q origin "$1"
}

sync() {
    run sh -c 'cd "$1" && sh /repo/scripts/sync-from-github.sh "$2" "$3"' _ "$WORK/runner" "$GITHUB" "$GITLAB"
}

@test "pushes main and the v tags to GitLab" {
    tag_on_github v1.0.0

    sync
    [ "$status" -eq 0 ]
    [ "$(git -C "$GITLAB" rev-parse main)" = "$(git -C "$GITHUB" rev-parse main)" ]
    [ "$(git -C "$GITLAB" tag --list v1.0.0)" = v1.0.0 ]
}

@test "leaves other branches and tags without a v prefix on GitHub" {
    git -C "$CLONE" branch feature
    git -C "$CLONE" push -q origin feature
    tag_on_github nightly

    sync
    [ "$status" -eq 0 ]
    [ -z "$(git -C "$GITLAB" branch --list feature)" ]
    [ -z "$(git -C "$GITLAB" tag --list nightly)" ]
}

@test "fast-forwards GitLab when GitHub moves on" {
    sync
    [ "$status" -eq 0 ]
    commit_on_github second

    sync
    [ "$status" -eq 0 ]
    [ "$(git -C "$GITLAB" rev-parse main)" = "$(git -C "$GITHUB" rev-parse main)" ]
}

@test "refuses a GitLab main that has a commit GitHub lacks, and pushes no tag with it" {
    sync
    [ "$status" -eq 0 ]
    commit_on_gitlab
    stray=$(git -C "$GITLAB" rev-parse main)

    commit_on_github second
    tag_on_github v2.0.0

    sync
    [ "$status" -ne 0 ]
    [ "$(git -C "$GITLAB" rev-parse main)" = "$stray" ]
    [ -z "$(git -C "$GITLAB" tag --list v2.0.0)" ]
}

@test "removes a v tag from GitLab when GitHub no longer has it, and keeps the other v tags" {
    tag_on_github v1.0.0
    tag_on_github v1.1.0
    sync
    [ "$status" -eq 0 ]
    [ "$(git -C "$GITLAB" tag --list 'v*' | wc -l)" -eq 2 ]

    git -C "$CLONE" push -q origin :refs/tags/v1.0.0

    sync
    [ "$status" -eq 0 ]
    [ "$(git -C "$GITLAB" tag --list 'v*')" = v1.1.0 ]
}

@test "never deletes a tag that is not a v tag, or a branch GitHub lacks" {
    sync
    [ "$status" -eq 0 ]
    git clone -q "$GITLAB" "$WORK/gitlab-clone" 2> /dev/null
    git -C "$WORK/gitlab-clone" tag legacy
    git -C "$WORK/gitlab-clone" push -q origin legacy
    git -C "$WORK/gitlab-clone" push -q origin main:hotfix

    sync
    [ "$status" -eq 0 ]
    [ "$(git -C "$GITLAB" tag --list legacy)" = legacy ]
    [ -n "$(git -C "$GITLAB" branch --list hotfix)" ]
}

@test "deletes nothing when it can't read GitHub" {
    tag_on_github v1.0.0
    sync
    [ "$status" -eq 0 ]

    run sh -c 'cd "$1" && sh /repo/scripts/sync-from-github.sh "$2" "$3"' _ "$WORK/runner" "$WORK/no-such-repository.git" "$GITLAB"
    [ "$status" -ne 0 ]
    [ "$(git -C "$GITLAB" tag --list v1.0.0)" = v1.0.0 ]
}

@test "moves a v tag on GitLab when GitHub recreates it at another commit, and still updates main" {
    tag_on_github v1.0.0
    sync
    [ "$status" -eq 0 ]

    commit_on_github second
    git -C "$CLONE" push -q origin :refs/tags/v1.0.0
    git -C "$CLONE" push -q origin HEAD:refs/tags/v1.0.0

    sync
    [ "$status" -eq 0 ]
    [ "$(git -C "$GITLAB" rev-parse v1.0.0)" = "$(git -C "$GITHUB" rev-parse v1.0.0)" ]
    [ "$(git -C "$GITLAB" rev-parse main)" = "$(git -C "$GITHUB" rev-parse main)" ]
}

@test "stops when it can't list GitLab's tags, even though the push would go through" {
    tag_on_github v1.0.0
    sync
    [ "$status" -eq 0 ]

    git -C "$CLONE" push -q origin :refs/tags/v1.0.0
    commit_on_github second

    STUB_FAIL_LISTING=1 sync
    [ "$status" -ne 0 ]
    [ "$(git -C "$GITLAB" tag --list v1.0.0)" = v1.0.0 ]
    [ "$(git -C "$GITLAB" rev-parse main)" != "$(git -C "$GITHUB" rev-parse main)" ]
}

@test "sends what GitHub has, whatever the directory it runs in holds" {
    sync
    [ "$status" -eq 0 ]
    commit_on_github second

    # A job checkout of the GitLab project with a tag and a commit of its own.
    git clone -q "$GITLAB" "$WORK/checkout" 2> /dev/null
    git -C "$WORK/checkout" tag v9.9.9
    git -C "$WORK/checkout" commit -q --allow-empty -m "only in the checkout"

    run sh -c 'cd "$1" && sh /repo/scripts/sync-from-github.sh "$2" "$3"' _ "$WORK/checkout" "$GITHUB" "$GITLAB"
    [ "$status" -eq 0 ]
    [ -z "$(git -C "$GITLAB" tag --list v9.9.9)" ]
    [ "$(git -C "$GITLAB" rev-parse main)" = "$(git -C "$GITHUB" rev-parse main)" ]
}

@test "fails without both repositories, and pushes nothing" {
    run sh -c 'cd "$1" && sh /repo/scripts/sync-from-github.sh "$2"' _ "$WORK/runner" "$GITHUB"
    [ "$status" -ne 0 ]
    [[ "$output" == *Usage* ]]
    run git -C "$GITLAB" rev-parse --verify --quiet main
    [ "$status" -ne 0 ]
}

@test "the push never forces main, and never uses force, delete, or mirror flags, and it is atomic" {
    # The forced fetch only rewrites the local copies of GitHub's v tags.
    run sh -c "grep -v '^git fetch' /repo/scripts/sync-from-github.sh | grep -nE -e '--force|--mirror|--prune|--delete|(^|[[:space:]])\+refs'"
    [ "$status" -ne 0 ]
    grep -qxF 'set -- refs/remotes/origin/main:refs/heads/main' /repo/scripts/sync-from-github.sh
    grep -q -e '--atomic' /repo/scripts/sync-from-github.sh
}

@test "the job syncs only on a schedule or a manual run of a project that sets the variable, and a scheduled pipeline never deploys" {
    run python3 - /repo/.gitlab-ci.yml <<'PY'
import sys, yaml
ci = yaml.safe_load(open(sys.argv[1]))
sync = ci["sync-from-github"]
assert len(sync["rules"]) == 1, sync["rules"]
rule = sync["rules"][0]["if"]
assert '$SYNC_FROM_GITHUB == "true"' in rule, rule
assert '$CI_PIPELINE_SOURCE == "schedule"' in rule and '$CI_PIPELINE_SOURCE == "web"' in rule, rule
assert "push" not in rule, "a push pipeline must not sync: " + rule
assert sync["stage"] == "sync" and ci["stages"][0] == "sync", ci["stages"]
assert "@sha256:" in sync["image"], "the job that holds the token runs an unpinned image: " + sync["image"]
script = " ".join(sync["script"])
assert "scripts/sync-from-github.sh" in script, script
assert "https://gitlab-ci-token:${CI_JOB_TOKEN}@${CI_SERVER_HOST}/${CI_PROJECT_PATH}.git" in script, script
inputs = ci["include"][0]["inputs"]
gated = {
    "deploy": inputs["rules"],
    "stop": inputs["stop_rules"],
    "check-manifest": ci["check-manifest"]["rules"],
}
for name, rules in gated.items():
    for entry in rules:
        assert '$CI_PIPELINE_SOURCE != "schedule"' in entry["if"], (name, entry)
        assert "$DEPLOY_TO_DATAROBOT" in entry["if"], (name, entry)
PY
    [ "$status" -eq 0 ]
}
