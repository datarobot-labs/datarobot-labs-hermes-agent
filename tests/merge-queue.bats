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

# Decisions of scripts/merge-queue-enqueue.sh and scripts/merge-queue-posture.sh.
# A stand-in for `gh` returns canned answers for the fields the scripts read,
# so these tests cover the decisions. The `--jq` filters that turn the API
# responses into those fields run only against GitHub.

setup() {
    WORK=$(mktemp -d)
    export STUB_LOG="$WORK/gh.log" GITHUB_OUTPUT="$WORK/output"
    : > "$STUB_LOG"
    : > "$GITHUB_OUTPUT"
    mkdir "$WORK/bin"
    cat > "$WORK/bin/gh" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "$STUB_LOG"
case "$*" in
    *enqueuePullRequest*) [ -z "${STUB_ENQUEUE_FAILS:-}" ] || exit 1 ;;
    *graphql*) printf '%s\n' "$STUB_PR" ;;
    *rules/branches*) [ -z "${STUB_RULES_FAIL:-}" ] || exit 1; printf '%s\n' "$STUB_RULES" ;;
esac
STUB
    chmod +x "$WORK/bin/gh"
    export PATH="$WORK/bin:$PATH" REPO=acme/widgets DEFAULT_BRANCH=main BASE=main
    pr_fields CLEAN false false main false ""
}

teardown() {
    rm -rf "$WORK"
}

# pr_fields MERGE_STATE DRAFT CROSS BASE QUEUED LABELS [STATE] [HEAD]
pr_fields() {
    STUB_PR=$(printf 'PR_1\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s' "${7:-OPEN}" "$2" "$3" "${8:-abc123}" "$4" "$1" "$5" "$6")
    export STUB_PR
}

enqueue() {
    run sh /repo/scripts/merge-queue-enqueue.sh "$@"
}

enqueued() {
    grep -q enqueuePullRequest "$STUB_LOG"
}

@test "a clean pull request is added to the queue with the head it was checked at" {
    enqueue 7 abc123
    [ "$status" -eq 0 ]
    enqueued
    grep -q 'oid=abc123' "$STUB_LOG"
}

@test "a clean pull request is added when no expected head is given, as in the scheduled sweep" {
    enqueue 7
    [ "$status" -eq 0 ]
    enqueued
}

@test "a pull request that is not clean stays out" {
    pr_fields BLOCKED false false main false ""
    enqueue 7
    [ "$status" -eq 0 ]
    ! enqueued || false
    [[ "$output" == *"BLOCKED, not CLEAN"* ]]
}

@test "a draft stays out" {
    pr_fields CLEAN true false main false ""
    enqueue 7
    [ "$status" -eq 0 ]
    ! enqueued || false
}

@test "a pull request from a fork stays out" {
    pr_fields CLEAN false true main false ""
    enqueue 7
    [ "$status" -eq 0 ]
    ! enqueued || false
    [[ "$output" == *"fork"* ]]
}

@test "a pull request for another base branch stays out" {
    pr_fields CLEAN false false release false ""
    enqueue 7
    [ "$status" -eq 0 ]
    ! enqueued || false
}

@test "a pull request that is closed or merged stays out" {
    pr_fields CLEAN false false main false "" MERGED
    enqueue 7
    [ "$status" -eq 0 ]
    ! enqueued || false
}

@test "a pull request with the hold label stays out, among other labels" {
    pr_fields CLEAN false false main false "bug,hold,dependencies"
    enqueue 7
    [ "$status" -eq 0 ]
    ! enqueued || false
}

@test "a label that only contains hold does not hold the pull request" {
    pr_fields CLEAN false false main false "holdout,onhold"
    enqueue 7
    [ "$status" -eq 0 ]
    enqueued
}

@test "a pull request already in the queue is not added again" {
    pr_fields CLEAN false false main true ""
    enqueue 7
    [ "$status" -eq 0 ]
    ! enqueued || false
}

@test "a run for an older commit is stale and adds nothing" {
    pr_fields CLEAN false false main false "" OPEN newhead
    enqueue 7 abc123
    [ "$status" -eq 0 ]
    ! enqueued || false
    [[ "$output" == *"newer commit"* ]]
}

@test "a run with no pull request attached adds nothing and reads nothing" {
    enqueue ""
    [ "$status" -eq 0 ]
    [ ! -s "$STUB_LOG" ]
}

@test "a refused enqueue fails the script, so the run shows it" {
    export STUB_ENQUEUE_FAILS=1
    enqueue 7 abc123
    [ "$status" -ne 0 ]
}

posture() {
    export STUB_RULES="$1"
    run sh /repo/scripts/merge-queue-posture.sh
}

@test "the posture is ready with a queue, a required check and a required approval" {
    posture "$(printf 'true\t2\t1\tfalse')"
    [ "$status" -eq 0 ]
    grep -qx 'ready=true' "$GITHUB_OUTPUT"
}

@test "the posture is ready when the Bouncer check replaces the approval" {
    posture "$(printf 'true\t2\t0\ttrue')"
    [ "$status" -eq 0 ]
    grep -qx 'ready=true' "$GITHUB_OUTPUT"
}

@test "the posture is not ready without a merge queue" {
    posture "$(printf 'false\t2\t1\tfalse')"
    [ "$status" -eq 0 ]
    grep -qx 'ready=false' "$GITHUB_OUTPUT"
    [[ "$output" == *"no merge queue rule"* ]]
}

@test "the posture is not ready without a required status check" {
    posture "$(printf 'true\t0\t1\tfalse')"
    [ "$status" -eq 0 ]
    grep -qx 'ready=false' "$GITHUB_OUTPUT"
    [[ "$output" == *"no required status check"* ]]
}

@test "the posture is not ready when nothing reviews the change" {
    posture "$(printf 'true\t2\t0\tfalse')"
    [ "$status" -eq 0 ]
    grep -qx 'ready=false' "$GITHUB_OUTPUT"
    [[ "$output" == *"no required approval"* ]]
}

@test "the posture reports every problem it finds" {
    posture "$(printf 'false\t0\t0\tfalse')"
    [[ "$output" == *"no merge queue rule"* ]]
    [[ "$output" == *"no required status check"* ]]
    [[ "$output" == *"no required approval"* ]]
}

@test "the posture fails when the rules can't be read, and says nothing is ready" {
    export STUB_RULES_FAIL=1
    posture ""
    [ "$status" -eq 1 ]
    ! grep -q 'ready=true' "$GITHUB_OUTPUT" || false
}
