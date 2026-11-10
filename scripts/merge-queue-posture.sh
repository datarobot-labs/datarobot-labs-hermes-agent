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

# Decides whether the rules on the default branch are safe for the merge queue
# App. The App can add a pull request to the queue, so it must never work where
# the rules would let an unreviewed or unchecked change through. It needs three
# things: a merge queue, at least one required status check, and a review
# control, which is either a required approval or a required `Bouncer` check.
#
# Usage: scripts/merge-queue-posture.sh
# Reads REPO (owner/name) and BASE (the default branch). Writes `ready=true` or
# `ready=false` to $GITHUB_OUTPUT, or to the terminal when that is not set, and
# says why on a warning line. Exits 0 either way: a repo that is not set up is
# not a failure. Exits 1 when it can't read the rules.

set -eu

repo=${REPO:?REPO is not set}
base=${BASE:?BASE is not set}
out=${GITHUB_OUTPUT:-/dev/stdout}

rules=$(gh api "repos/$repo/rules/branches/$base" --jq '
  [ any(.[]; .type == "merge_queue"),
    ([.[] | select(.type == "required_status_checks") | .parameters.required_status_checks[]?] | length),
    ([.[] | select(.type == "pull_request") | .parameters.required_approving_review_count] | max // 0),
    any(.[] | select(.type == "required_status_checks") | .parameters.required_status_checks[]?; .context == "Bouncer")
  ] | @tsv') || { echo "Could not read the rules of $base." >&2; exit 1; }

IFS='	' read -r queue checks approvals gate <<EOF
$rules
EOF

problems=""
[ "$queue" = true ] || problems="$problems no merge queue rule;"
[ "${checks:-0}" -ge 1 ] || problems="$problems no required status check;"
if [ "${approvals:-0}" -lt 1 ] && [ "$gate" != true ]; then
    problems="$problems no required approval and no required Bouncer check;"
fi

if [ -n "$problems" ]; then
    echo "::warning::The rules on $base are not safe for the merge queue App:$problems it stays idle."
    echo "ready=false" >> "$out"
else
    echo "ready=true" >> "$out"
fi
