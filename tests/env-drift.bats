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

# Behaviour of scripts/env-drift.sh: the .env names the manifest doesn't
# declare, by name only, and never a value.

setup() {
    WORK=$(mktemp -d)
    ENV="$WORK/.env"
    printf 'DATAROBOT_API_TOKEN="canary-user-token"\nDATAROBOT_ENDPOINT="https://dr.example.com/api/v2"\nSLACK_BOT_TOKEN="xoxb-canary"\n' > "$ENV"
}

teardown() {
    rm -rf "$WORK"
}

# manifest <entry lines>: a manifest whose container declares them.
manifest() {
    printf 'name: hermes-agent\nartifact:\n  spec:\n    containerGroups:\n      - containers:\n          - environmentVars:\n%s\n' "$1" > "$WORK/.datarobot.yaml"
}

drift() {
    run sh /repo/scripts/env-drift.sh "$ENV"
}

@test "a manifest that declares every .env name passes, the token aside, in any form dr reads" {
    manifest '              - name: DATAROBOT_ENDPOINT
                value: https://dr.example.com/api/v2
              - {name: "SLACK_BOT_TOKEN", value: dr-credential:0123456789abcdef01234567/apiToken}'
    drift
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "the names the manifest lacks are listed, once each, empty or exported ones too" {
    printf 'DR_SYNC_CATALOG_ID="0123456789abcdef01234567"\nexport SLACK_HOME_CHANNEL=C1\nGATEWAY_ALLOW_ALL_USERS=\nDR_SYNC_CATALOG_ID=\n' >> "$ENV"
    manifest '              - name: DATAROBOT_ENDPOINT
                value: https://dr.example.com/api/v2
              - name: SLACK_BOT_TOKEN # a credential
                value: dr-credential:0123456789abcdef01234567/apiToken'
    drift
    [ "$status" -eq 1 ]
    [ "$output" = "DR_SYNC_CATALOG_ID
GATEWAY_ALLOW_ALL_USERS
SLACK_HOME_CHANNEL" ]
}

@test "a name only in a comment, a value or a longer name isn't declared, and no value is printed" {
    manifest '              # - name: SLACK_BOT_TOKEN
              - name: DATAROBOT_ENDPOINT_OLD
                value: SLACK_BOT_TOKEN
              - name: DATAROBOT_API_TOKEN
                source: api-key'
    drift
    [ "$status" -eq 1 ]
    [ "$output" = "DATAROBOT_ENDPOINT
SLACK_BOT_TOKEN" ]
    [[ "$output" != *canary* ]]
}

@test "an unreadable .env or manifest is an error, not drift" {
    drift
    [ "$status" -eq 2 ]
    [[ "$output" == *"Can't read $WORK/.datarobot.yaml"* ]]
    manifest '              - name: DATAROBOT_ENDPOINT'
    rm "$ENV"
    drift
    [ "$status" -eq 2 ]
}
