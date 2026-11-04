#!/bin/sh
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

# Adds one pull request to the merge queue once it is ready, so nobody clicks
# "Merge when ready". It enqueues only when GitHub reports the merge state as
# CLEAN, so every approval and required check has passed, and it skips a draft,
# a fork, a pull request already queued, one labeled `hold`, and one whose head
# moved on. The queue still runs the required checks before it merges.
#
# It reads fields from the API and never checks out or runs the pull request.
#
# Usage: scripts/merge-queue-enqueue.sh PR_NUMBER [EXPECTED_HEAD_SHA]
# Reads REPO (owner/name) and DEFAULT_BRANCH, and WAIT_SECONDS (default 0), how
# long to wait for the merge state to settle after a check completes. Needs a
# token that may enqueue. Exits 0 when it skips a pull request.

set -eu

repo=${REPO:?REPO is not set}
default_branch=${DEFAULT_BRANCH:?DEFAULT_BRANCH is not set}
pr=${1:-}
expected_head=${2:-}
wait_seconds=${WAIT_SECONDS:-0}

skip() {
    echo "::notice::PR ${pr:-?}: $1 Skipping."
    exit 0
}

[ -n "$pr" ] || skip "No pull request is attached to this run."

read_pr() {
    # `gh pr view --json` has no isInMergeQueue field, so ask GraphQL.
    # shellcheck disable=SC2016 # $owner, $name and $number are GraphQL variables.
    gh api graphql -f owner="${repo%/*}" -f name="${repo#*/}" -F number="$pr" -f query='
      query($owner: String!, $name: String!, $number: Int!) {
        repository(owner: $owner, name: $name) {
          pullRequest(number: $number) {
            id state isDraft isCrossRepository headRefOid baseRefName mergeStateStatus isInMergeQueue
            labels(first: 50) { nodes { name } }
          }
        }
      }' --jq '.data.repository.pullRequest
        | [.id, .state, .isDraft, .isCrossRepository, .headRefOid, .baseRefName,
           .mergeStateStatus, .isInMergeQueue, ([.labels.nodes[].name] | join(","))]
        | @tsv'
}

waited=0
while :; do
    fields=$(read_pr)
    IFS='	' read -r id state draft cross head base merge queued labels <<EOF
$fields
EOF
    if [ "$merge" = CLEAN ] || [ "$waited" -ge "$wait_seconds" ]; then
        break
    fi
    sleep 5
    waited=$((waited + 5))
done

[ "$state" = OPEN ] || skip "The pull request is $state."
[ "$draft" = false ] || skip "The pull request is a draft."
[ "$cross" = false ] || skip "The pull request comes from a fork."
[ "$base" = "$default_branch" ] || skip "The base is $base, not $default_branch."
[ -z "$expected_head" ] || [ "$head" = "$expected_head" ] || skip "A newer commit exists, so this run is stale."
case ",$labels," in *,hold,*) skip "The pull request has the hold label." ;; esac
[ "$queued" = false ] || skip "The pull request is already in the merge queue."
[ "$merge" = CLEAN ] || skip "The merge state is $merge, not CLEAN."

# expectedHeadOid makes GitHub refuse the enqueue when a commit landed after the checks passed.
# shellcheck disable=SC2016 # $id and $oid are GraphQL variables.
gh api graphql -f id="$id" -f oid="$head" -f query='
  mutation($id: ID!, $oid: GitObjectID) {
    enqueuePullRequest(input: {pullRequestId: $id, expectedHeadOid: $oid}) {
      mergeQueueEntry { position }
    }
  }' > /dev/null
echo "::notice::PR $pr: added to the merge queue."
