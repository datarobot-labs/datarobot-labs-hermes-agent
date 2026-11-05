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

@test ".env names count indented, exported or quoted, and not in a comment" {
    printf '  SLACK_HOME_CHANNEL=C1\nexport DR_SYNC_CATALOG_ID="0123456789abcdef01234567"\nNOTE=x # GHOST=1\n# OLD=1\n' >> "$ENV"
    manifest '              - name: DATAROBOT_ENDPOINT
              - name: SLACK_BOT_TOKEN'
    drift
    [ "$status" -eq 1 ]
    [ "$output" = "DR_SYNC_CATALOG_ID
NOTE
SLACK_HOME_CHANNEL" ]
}

@test "entries with their keys reordered, or in a flow list on one line or several, are declared" {
    manifest '              - value: https://dr.example.com/api/v2
                name: DATAROBOT_ENDPOINT
              - {value: dr-credential:0123456789abcdef01234567/apiToken, name: SLACK_BOT_TOKEN}'
    drift
    [ "$status" -eq 0 ]
    printf 'name: hermes-agent\nartifact:\n  spec:\n    containerGroups:\n      - containers:\n          - environmentVars: [{name: DATAROBOT_ENDPOINT, value: x}, {value: y, name: "SLACK_BOT_TOKEN"}]\n' > "$WORK/.datarobot.yaml"
    drift
    [ "$status" -eq 0 ]
    printf 'name: hermes-agent\nartifact:\n  spec:\n    containerGroups:\n      - containers:\n          - environmentVars: [\n              {name: DATAROBOT_ENDPOINT}, # a comment\n              {name: SLACK_BOT_TOKEN}]\n' > "$WORK/.datarobot.yaml"
    drift
    [ "$status" -eq 0 ]
}

@test "a name only a sidecar declares isn't declared: it never reaches Hermes" {
    cat > "$WORK/.datarobot.yaml" <<'YAML'
name: hermes-agent
artifact:
  spec:
    containerGroups:
      - containers:
          - name: hermes
            primary: true
            environmentVars:
              - name: DATAROBOT_ENDPOINT
          - name: sidecar
            environmentVars:
              - name: SLACK_BOT_TOKEN
YAML
    drift
    [ "$status" -eq 1 ]
    [ "$output" = SLACK_BOT_TOKEN ]
    sed -i '/primary: true/d' "$WORK/.datarobot.yaml"
    drift
    [ "$status" -eq 2 ]
    [[ "$output" == *"Can't tell which container"* ]]
}
