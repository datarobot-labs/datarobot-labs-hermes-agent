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
# and the v* tags from GitHub and nothing else, a fast-forward at a time, over
# SSH with a deploy key. Two bare repositories stand in for GitHub and GitLab,
# a clone of the first is where the script runs, as it does after
# `actions/checkout`, and a stub `ssh` takes the place of the connection: it
# saves the key and the known-hosts file it is given, then runs the git command
# on the second repository.

PINNED_HOST_KEY='gitlab.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAfuCHKVTjquxvt6CM6tdG4SLp1Btn/nOeHHE5UOzRdf'

setup() {
    WORK=$(mktemp -d)
    export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.com
    export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.com
    # Two lines, like a real private key, and no PEM header for a scanner to flag.
    GITLAB_MIRROR_KEY=$'canary-key-line-one-0123456789\ncanary-key-line-two-0123456789'
    export GITLAB_MIRROR_KEY
    export STUB_SEEN="$WORK/seen"
    mkdir -p "$STUB_SEEN" "$WORK/bin"

    cat > "$WORK/bin/ssh" <<'STUB'
#!/bin/sh
key=
known=
strict=
while [ "$#" -gt 1 ]; do
    case "$1" in
        -i) key=$2; shift ;;
        -o)
            case "$2" in
                UserKnownHostsFile=*) known=${2#UserKnownHostsFile=} ;;
                StrictHostKeyChecking=*) strict=${2#StrictHostKeyChecking=} ;;
            esac
            shift ;;
    esac
    shift
done
cp "$key" "$STUB_SEEN/key"
stat -c %a "$key" > "$STUB_SEEN/key-mode"
printf '%s\n' "$key" > "$STUB_SEEN/key-path"
cp "$known" "$STUB_SEEN/known_hosts"
printf '%s\n' "$strict" > "$STUB_SEEN/strict"
case "$1" in
    git-receive-pack*) exec sh -c "git receive-pack ${1#git-receive-pack}" ;;
    git-upload-pack*) exec sh -c "git upload-pack ${1#git-upload-pack}" ;;
esac
echo "unexpected command: $1" >&2
exit 1
STUB
    chmod +x "$WORK/bin/ssh"
    PATH="$WORK/bin:$PATH"

    GITHUB="$WORK/github.git"
    GITLAB="$WORK/gitlab.git"
    REMOTE="git@gitlab.example:$GITLAB"
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

mirror() {
    run sh -c 'cd "$1" && /repo/scripts/mirror-to-gitlab.sh "$2"' _ "$CLONE" "$REMOTE"
}

@test "pushes main and the v tags to GitLab" {
    tag_on_github v1.0.0

    mirror
    [ "$status" -eq 0 ]
    [ "$(git -C "$GITLAB" rev-parse main)" = "$(git -C "$CLONE" rev-parse origin/main)" ]
    [ "$(git -C "$GITLAB" tag --list v1.0.0)" = v1.0.0 ]
}

@test "leaves other branches and tags without a v prefix on GitHub" {
    git -C "$CLONE" branch feature
    git -C "$CLONE" push -q origin feature
    tag_on_github nightly

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
    commit_on_gitlab
    stray=$(git -C "$GITLAB" rev-parse main)

    commit_on_github second
    tag_on_github v2.0.0

    mirror
    [ "$status" -ne 0 ]
    [ "$(git -C "$GITLAB" rev-parse main)" = "$stray" ]
    [ -z "$(git -C "$GITLAB" tag --list v2.0.0)" ]
}

@test "removes a v tag from GitLab when GitHub no longer has it, and keeps the other v tags" {
    tag_on_github v1.0.0
    tag_on_github v1.1.0
    mirror
    [ "$status" -eq 0 ]
    [ "$(git -C "$GITLAB" tag --list 'v*' | wc -l)" -eq 2 ]

    git -C "$CLONE" push -q origin :refs/tags/v1.0.0
    git -C "$CLONE" tag -d v1.0.0 > /dev/null

    mirror
    [ "$status" -eq 0 ]
    [ "$(git -C "$GITLAB" tag --list 'v*')" = v1.1.0 ]
}

@test "never deletes a tag that is not a v tag, or a branch GitHub lacks" {
    mirror
    [ "$status" -eq 0 ]
    git clone -q "$GITLAB" "$WORK/gitlab-clone" 2> /dev/null
    git -C "$WORK/gitlab-clone" tag legacy
    git -C "$WORK/gitlab-clone" push -q origin legacy
    git -C "$WORK/gitlab-clone" push -q origin main:hotfix

    mirror
    [ "$status" -eq 0 ]
    [ "$(git -C "$GITLAB" tag --list legacy)" = legacy ]
    [ -n "$(git -C "$GITLAB" branch --list hotfix)" ]
}

@test "deletes nothing when it can't list GitHub's tags" {
    tag_on_github v1.0.0
    mirror
    [ "$status" -eq 0 ]

    git -C "$CLONE" remote set-url origin "$WORK/no-such-repository.git"
    mirror
    [ "$status" -ne 0 ]
    [ "$(git -C "$GITLAB" tag --list v1.0.0)" = v1.0.0 ]

    # Bash ignores `set -e` in a command that sits before `||`, which sh here does not,
    # so the script's own check has to stop it.
    run bash -c 'cd "$1" && bash /repo/scripts/mirror-to-gitlab.sh "$2"' _ "$CLONE" "$REMOTE"
    [ "$status" -ne 0 ]
    [ "$(git -C "$GITLAB" tag --list v1.0.0)" = v1.0.0 ]
}

@test "fails on a tag the clone lacks, and deletes nothing from GitLab" {
    tag_on_github v1.0.0
    mirror
    [ "$status" -eq 0 ]

    # A clone made without its tags.
    git -C "$CLONE" tag -d v1.0.0 > /dev/null
    commit_on_github second

    mirror
    [ "$status" -ne 0 ]
    [ "$(git -C "$GITLAB" tag --list v1.0.0)" = v1.0.0 ]
    [ "$(git -C "$GITLAB" rev-parse main)" != "$(git -C "$CLONE" rev-parse origin/main)" ]
}

@test "fails without a key, and pushes nothing" {
    unset GITLAB_MIRROR_KEY

    mirror
    [ "$status" -ne 0 ]
    [[ "$output" == *"GITLAB_MIRROR_KEY is empty"* ]]
    run git -C "$GITLAB" rev-parse --verify --quiet main
    [ "$status" -ne 0 ]
}

@test "gives ssh the key in a private file, and checks the host against the pinned GitLab key" {
    mirror
    [ "$status" -eq 0 ]
    [ "$(cat "$STUB_SEEN/key")" = "$GITLAB_MIRROR_KEY" ]
    [ "$(cat "$STUB_SEEN/key-mode")" = 600 ]
    [ "$(cat "$STUB_SEEN/strict")" = yes ]
    [ "$(cat "$STUB_SEEN/known_hosts")" = "$PINNED_HOST_KEY" ]
}

@test "removes the key file when the push is done, and when it fails" {
    mirror
    [ "$status" -eq 0 ]
    [ ! -e "$(cat "$STUB_SEEN/key-path")" ]

    commit_on_gitlab
    commit_on_github second
    mirror
    [ "$status" -ne 0 ]
    [ ! -e "$(cat "$STUB_SEEN/key-path")" ]
}

@test "never prints the key" {
    mirror
    [ "$status" -eq 0 ]
    [[ "$output" != *canary-key-line* ]]

    # A refused push prints git's error, which is the other place it could leak.
    commit_on_gitlab
    commit_on_github second
    mirror
    [ "$status" -ne 0 ]
    [[ "$output" != *canary-key-line* ]]
}

@test "the push never forces, deletes, or mirrors, and it is atomic" {
    run grep -nE -e '--force|--mirror|--prune|--delete|(^|[[:space:]])\+refs' /repo/scripts/mirror-to-gitlab.sh
    [ "$status" -ne 0 ]
    grep -q -e '--atomic' /repo/scripts/mirror-to-gitlab.sh
}

@test "the SSH options check the host key against the pinned file, never against nothing" {
    grep -q 'StrictHostKeyChecking=yes' /repo/scripts/mirror-to-gitlab.sh
    run grep -nE 'StrictHostKeyChecking=(no|accept-new)|UserKnownHostsFile=/dev/null' /repo/scripts/mirror-to-gitlab.sh
    [ "$status" -ne 0 ]
}

@test "the workflow runs only in this repository, reads the key from an environment, and runs on main, the v tags, and a schedule" {
    run python3 - /repo/.github/workflows/mirror-to-gitlab.yml <<'PY'
import sys, yaml
workflow = yaml.safe_load(open(sys.argv[1]))
on = workflow.get("on", workflow.get(True))  # YAML 1.1 reads a bare `on` as true
job = workflow["jobs"]["mirror"]
assert "github.repository ==" in job["if"], job["if"]
assert "github.ref == 'refs/heads/main'" in job["if"], job["if"]
assert job["environment"] == "gitlab-mirror", job["environment"]
assert on["push"] == {"branches": ["main"]}, "a tag push would run the tagged code with the key: " + str(on["push"])
assert "schedule" in on, "no weekly run to report an expired key"
assert "pull_request" not in on, "a pull request must not reach the key"
push = [step for step in job["steps"] if "mirror-to-gitlab.sh" in step.get("run", "")]
assert len(push) == 1, push
assert push[0]["env"] == {"GITLAB_MIRROR_KEY": "${{ secrets.GITLAB_MIRROR_KEY }}"}, push[0]["env"]
PY
    [ "$status" -eq 0 ]
}
