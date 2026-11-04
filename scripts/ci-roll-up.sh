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

# Decides the go-no-go check of .github/workflows/ci.yml from the results of its
# jobs. The always-run jobs must succeed. The jobs that run only for some
# changes must succeed when the change needs them, and must be skipped when it
# doesn't, so a skip that should not have happened fails the check.
#
# Usage: scripts/ci-roll-up.sh
# Reads <JOB>_RESULT for every job (success, failure, cancelled or skipped) and
# NEEDS_<JOB> (true or false) for the conditional ones. Exits 1 on any failure.

set -eu

failed=0

fail() {
    echo "go-no-go: $1" >&2
    failed=1
}

# always JOB RESULT
always() {
    [ "$2" = success ] || fail "$1 finished as '${2:-unset}', not success."
}

# conditional JOB RESULT NEEDED
conditional() {
    if [ "$3" = true ]; then
        [ "$2" = success ] || fail "$1 finished as '${2:-unset}', and the change needs it."
    else
        [ "$2" = skipped ] || fail "$1 finished as '${2:-unset}', and should have been skipped."
    fi
}

always changes "${CHANGES_RESULT:-}"
always lint "${LINT_RESULT:-}"
always test "${TEST_RESULT:-}"
always license-header "${LICENSE_HEADER_RESULT:-}"
always secret-scan "${SECRET_SCAN_RESULT:-}"
conditional image "${IMAGE_RESULT:-}" "${NEEDS_IMAGE:-}"
conditional link-check "${LINK_CHECK_RESULT:-}" "${NEEDS_LINK_CHECK:-}"
conditional workflow-lint "${WORKFLOW_LINT_RESULT:-}" "${NEEDS_WORKFLOW_LINT:-}"

[ "$failed" -eq 0 ] && echo "go-no-go: every job that had to run succeeded."
exit "$failed"
