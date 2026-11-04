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

# Behaviour of scripts/ci-roll-up.sh, the decision behind the go-no-go check:
# the always-run jobs must succeed, and a conditional job must succeed when
# the change needs it and be skipped when it doesn't.

# Every job succeeded and the change needs no conditional job.
setup() {
    export CHANGES_RESULT=success LINT_RESULT=success TEST_RESULT=success
    export LICENSE_HEADER_RESULT=success SECRET_SCAN_RESULT=success
    export IMAGE_RESULT=skipped LINK_CHECK_RESULT=skipped WORKFLOW_LINT_RESULT=skipped
    export NEEDS_IMAGE=false NEEDS_LINK_CHECK=false NEEDS_WORKFLOW_LINT=false
}

roll_up() {
    run sh /repo/scripts/ci-roll-up.sh
}

@test "passes when the always-run jobs succeeded and the conditional jobs were skipped" {
    roll_up
    [ "$status" -eq 0 ]
    [[ "$output" == *"every job that had to run succeeded"* ]]
}

@test "passes when a conditional job the change needs succeeded" {
    export NEEDS_IMAGE=true IMAGE_RESULT=success
    roll_up
    [ "$status" -eq 0 ]
}

@test "fails when an always-run job failed" {
    export TEST_RESULT=failure
    roll_up
    [ "$status" -eq 1 ]
    [[ "$output" == *"test finished as 'failure'"* ]]
}

@test "fails when an always-run job was cancelled or skipped" {
    export LINT_RESULT=cancelled
    roll_up
    [ "$status" -eq 1 ]
    export LINT_RESULT=skipped
    roll_up
    [ "$status" -eq 1 ]
}

@test "fails when a conditional job the change needs failed" {
    export NEEDS_WORKFLOW_LINT=true WORKFLOW_LINT_RESULT=failure
    roll_up
    [ "$status" -eq 1 ]
    [[ "$output" == *"workflow-lint finished as 'failure'"* ]]
}

@test "fails when a conditional job the change needs was skipped" {
    export NEEDS_IMAGE=true IMAGE_RESULT=skipped
    roll_up
    [ "$status" -eq 1 ]
    [[ "$output" == *"image finished as 'skipped', and the change needs it"* ]]
}

@test "fails when a conditional job the change does not need ran anyway" {
    export IMAGE_RESULT=success
    roll_up
    [ "$status" -eq 1 ]
    [[ "$output" == *"should have been skipped"* ]]
}

@test "fails when the changes job failed, even though every other job passed" {
    export CHANGES_RESULT=failure
    roll_up
    [ "$status" -eq 1 ]
    [[ "$output" == *"changes finished as 'failure'"* ]]
}

@test "fails when a result is missing" {
    unset LINT_RESULT
    roll_up
    [ "$status" -eq 1 ]
    [[ "$output" == *"lint finished as 'unset'"* ]]
}

@test "reports every failure, not only the first" {
    export LINT_RESULT=failure TEST_RESULT=failure
    roll_up
    [ "$status" -eq 1 ]
    [[ "$output" == *"lint finished"* ]]
    [[ "$output" == *"test finished"* ]]
}
