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

# Behaviour of scripts/check-credentials.sh: only an unresolved
# dr-credential:PLACEHOLDER reference fails, not the word anywhere else.

setup() {
    WORK=$(mktemp -d)
    M="$WORK/.datarobot.yaml"
}

teardown() {
    rm -rf "$WORK"
}

manifest() {
    printf 'name: hermes-agent\nartifact:\n  spec:\n    containerGroups:\n      - containers:\n          - environmentVars:\n%s\n' "$1" > "$M"
}

check() {
    run sh /repo/scripts/check-credentials.sh "$M"
}

@test "a resolved credential passes" {
    manifest '              - name: LLM_API_KEY
                value: dr-credential:0123456789abcdef01234567/apiToken'
    check
    [ "$status" -eq 0 ]
}

@test "an unresolved PLACEHOLDER credential fails, quoted or not" {
    for value in 'dr-credential:PLACEHOLDER/apiToken' '"dr-credential:PLACEHOLDER/apiToken"' \
        "'dr-credential:PLACEHOLDER/apiToken'" 'dr-credential:PLACEHOLDER'; do
        manifest "              - name: LLM_API_KEY
                value: $value"
        check
        [ "$status" -eq 1 ]
    done
}

@test "the word PLACEHOLDER elsewhere is not a credential" {
    manifest '              # a dr-credential:PLACEHOLDER/apiToken was fixed by hand
              - name: TEMPLATE_HINT
                value: PLACEHOLDER
              - name: NOTE
                value: dr-credential:PLACEHOLDERS-are-not-credentials'
    check
    [ "$status" -eq 0 ]
}

@test "a missing manifest is an error, not a pass" {
    check
    [ "$status" -eq 2 ]
    [[ "$output" == *"cannot read"* ]]
}
