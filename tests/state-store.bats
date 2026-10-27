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

# Behaviour of scripts/state-store.sh against a stub dr: a store
# id already known is checked and reused, a new one is created only when there
# is none, an id DataRobot doesn't know stops the run, and the token never
# reaches a command line.

TOKEN=canary-user-token-0123456789
STORE=0123456789abcdef01234567

setup() {
    WORK=$(mktemp -d)
    mkdir "$WORK/bin"
    ENV="$WORK/.env"
    printf 'DATAROBOT_ENDPOINT="https://dr.example.com/api/v2"\nDATAROBOT_API_TOKEN="%s"\n' "$TOKEN" > "$ENV"
    chmod 600 "$ENV"
    export STUB_DIR="$WORK" STUB_LOG="$WORK/calls"
    : > "$STUB_LOG"

    # dr: records its arguments and the token it was handed, if any, and
    # prints the "Running plugin" line real dr puts on stdout before a plugin.
    # `dr sync inspect` exits STUB_INSPECT (default 0), the way dr sync
    # exits 3 for a store DataRobot doesn't have; `dr sync init` prints STUB_ID.
    cat > "$WORK/bin/dr" <<'STUB'
#!/bin/sh
echo "dr $*" >> "$STUB_LOG"
echo "${DATAROBOT_API_TOKEN:-}" > "$STUB_DIR/dr.token"
echo "🔌 Running plugin: sync"
case "$*" in
    "sync inspect") echo "inspect $DR_SYNC_CATALOG_ID" >> "$STUB_LOG"; exit "${STUB_INSPECT:-0}" ;;
esac
echo "${STUB_ID-0123456789abcdef01234567}"
STUB
    chmod +x "$WORK/bin/dr"
}

teardown() {
    rm -rf "$WORK"
}

# store [--check]: run the script on $ENV with the stubs.
store() {
    PATH="$WORK/bin:$PATH" DATAROBOT_API_TOKEN= run sh /repo/scripts/state-store.sh "$@" "$ENV"
}

inits() {
    grep -c '^dr sync init' "$STUB_LOG" || true
}

manifest() {
    printf 'name: %s\nartifact:\n  spec:\n    containerGroups:\n      - containers:\n          - environmentVars:\n%s\n' \
        "$1" "$2" > "$WORK/.datarobot.yaml"
}

@test "with no store yet, one is created for the workload and its id written to .env" {
    store
    [ "$status" -eq 0 ]
    [[ "$output" == *"Created state store $STORE (\"hermes-agent-state\")"* ]]
    grep -qx "dr sync init --name hermes-agent-state --tag hermes_state" "$STUB_LOG"
    grep -qx "DR_SYNC_CATALOG_ID=\"$STORE\"" "$ENV"
    grep -qx "DATAROBOT_API_TOKEN=\"$TOKEN\"" "$ENV"
    [ "$(stat -c %a "$ENV")" = 600 ]
}

@test "the store is named after WORKLOAD_NAME, as the manifest will be" {
    WORKLOAD_NAME=my-bot store
    [ "$status" -eq 0 ]
    grep -qx "dr sync init --name my-bot-state --tag hermes_state" "$STUB_LOG"
}

@test "a re-run reuses the store it created and creates no second one" {
    store
    [ "$status" -eq 0 ]
    cp "$ENV" "$WORK/after-first"
    store
    [ "$status" -eq 0 ]
    [[ "$output" == *"State store $STORE (DR_SYNC_CATALOG_ID in $ENV) is in place."* ]]
    [ "$(inits)" = 1 ]
    cmp "$WORK/after-first" "$ENV"
}

@test "leftover empty DR_SYNC_CATALOG_ID lines don't hide the new id, and a re-run reuses it" {
    printf 'DR_SYNC_CATALOG_ID=\nSLACK_HOME_CHANNEL=C1\nDR_SYNC_CATALOG_ID=\n' >> "$ENV"
    store
    [ "$status" -eq 0 ]
    [ "$(grep '^DR_SYNC_CATALOG_ID=' "$ENV" | tail -n 1)" = "DR_SYNC_CATALOG_ID=\"$STORE\"" ]
    grep -qx 'SLACK_HOME_CHANNEL=C1' "$ENV"
    store
    [ "$status" -eq 0 ]
    [ "$(inits)" = 1 ]
}

@test "a manifest that already names a store, in any form, stops the run instead of making a second one" {
    for entry in '              - name: DR_SYNC_CATALOG_ID
                value: dr-credential:0123456789abcdef01234567/apiToken' \
        "              - name: DR_SYNC_CATALOG_ID
                value: \"$STORE\"" \
        "              - {name: DR_SYNC_CATALOG_ID, value: \"$STORE\"}"; do
        manifest hermes-agent "$entry"
        cp "$ENV" "$WORK/before"
        store
        [ "$status" -eq 1 ]
        [[ "$output" == *"already gives the workload a state store"* ]]
        [ "$(inits)" = 0 ]
        cmp "$WORK/before" "$ENV"
    done
}

@test "a DR_SYNC_CATALOG_ID that isn't an id is refused unprinted, and never sent" {
    printf 'DR_SYNC_CATALOG_ID="%s"\n' "$TOKEN" >> "$ENV"
    cp "$ENV" "$WORK/before"
    store
    [ "$status" -eq 1 ]
    [[ "$output" == *"DR_SYNC_CATALOG_ID in $ENV isn't a store id"* ]]
    [[ "$output" != *"$TOKEN"* ]]
    [ ! -s "$STUB_LOG" ]
    cmp "$WORK/before" "$ENV"
}

@test "an id DataRobot can't give, gone or behind a bad login, stops the run and is never replaced" {
    printf 'DR_SYNC_CATALOG_ID="%s"\n' "$STORE" >> "$ENV"
    cp "$ENV" "$WORK/before"
    STUB_INSPECT=3 store
    [ "$status" -eq 1 ]
    [[ "$output" == *"DataRobot can't give state store $STORE"* ]]
    [[ "$output" == *"State store not found"* ]]
    grep -qx "inspect $STORE" "$STUB_LOG"
    [ "$(inits)" = 0 ]
    cmp "$WORK/before" "$ENV"
}

@test "the script hands dr no token: dr sync runs with dr's own login" {
    store
    [ "$status" -eq 0 ]
    store
    [ "$status" -eq 0 ]
    ! grep -q "$TOKEN" "$STUB_LOG" || false
    [[ "$output" != *"$TOKEN"* ]]
    [ -z "$(cat "$WORK/dr.token")" ]
}

@test "an id split over lines in .env is refused, and only the last line of dr sync init counts" {
    printf 'DR_SYNC_CATALOG_ID="%s\n%s"\n' "junk" "$STORE" >> "$ENV"
    STUB_ID="$STORE
trailing" store
    [ "$status" -eq 1 ]
    [ "$(inits)" = 0 ]
    sed -i '/^DR_SYNC_CATALOG_ID=/,$d' "$ENV"
    STUB_ID="$STORE
trailing" store
    [ "$status" -eq 1 ]
    [[ "$output" == *"didn't print a store id"* ]]
    ! grep -q '^DR_SYNC_CATALOG_ID=' "$ENV" || false
}

@test "a dr sync init that prints no store id leaves .env alone" {
    cp "$ENV" "$WORK/before"
    STUB_ID='Error: something went wrong' store
    [ "$status" -eq 1 ]
    [[ "$output" == *"didn't print a store id"* ]]
    cmp "$WORK/before" "$ENV"
}

@test "--check reports, and never creates a store or touches .env" {
    cp "$ENV" "$WORK/before"
    store --check
    [ "$status" -eq 1 ]
    [[ "$output" == *"No state store yet"* ]]
    [ "$(inits)" = 0 ]
    cmp "$WORK/before" "$ENV"

    printf 'DR_SYNC_CATALOG_ID="%s"\n' "$STORE" >> "$ENV"
    store --check
    [ "$status" -eq 0 ]

    # A manifest that doesn't carry the id yet means the workload doesn't persist.
    manifest hermes-agent '              - name: SLACK_HOME_CHANNEL
                value: C123'
    store --check
    [ "$status" -eq 1 ]
    [[ "$output" == *"Run 'dr run env'"* ]]

    manifest hermes-agent "              - name: DR_SYNC_CATALOG_ID
                value: \"$STORE\""
    store --check
    [ "$status" -eq 0 ]

    STUB_INSPECT=3 store --check
    [ "$status" -eq 1 ]
    [ "$(inits)" = 0 ]
}

@test "--if-set passes a .env with no store unchecked, as a .env from before dr start made one" {
    cp "$ENV" "$WORK/before"
    store --if-set
    [ "$status" -eq 0 ]
    [[ "$output" == *"no state store to check"* ]]
    [ ! -s "$STUB_LOG" ]
    cmp "$WORK/before" "$ENV"

    # The manifest's own store deploys as before: there is nothing here to check it with.
    manifest hermes-agent "              - name: DR_SYNC_CATALOG_ID
                value: dr-credential:0123456789abcdef01234567/apiToken"
    store --if-set
    [ "$status" -eq 0 ]
    [ ! -s "$STUB_LOG" ]
}

@test "--if-set checks a store .env names: DataRobot has it, and the manifest carries it" {
    printf 'DR_SYNC_CATALOG_ID="%s"\n' "$STORE" >> "$ENV"
    cp "$ENV" "$WORK/before"
    store --if-set
    [ "$status" -eq 0 ]
    grep -qx "inspect $STORE" "$STUB_LOG"

    STUB_INSPECT=3 store --if-set
    [ "$status" -eq 1 ]
    [[ "$output" == *"DataRobot can't give state store $STORE"* ]]

    manifest hermes-agent '              - name: SLACK_HOME_CHANNEL
                value: C123'
    store --if-set
    [ "$status" -eq 1 ]
    [[ "$output" == *"Run 'dr run env'"* ]]

    manifest hermes-agent "              - name: DR_SYNC_CATALOG_ID
                value: dr-credential:0123456789abcdef01234567/apiToken"
    store --if-set
    [ "$status" -eq 0 ]
    [ "$(inits)" = 0 ]
    cmp "$WORK/before" "$ENV"
}

@test "--if-set refuses a malformed id unprinted, and never sends it" {
    printf 'DR_SYNC_CATALOG_ID="%s"\n' "$TOKEN" >> "$ENV"
    store --if-set
    [ "$status" -eq 1 ]
    [[ "$output" != *"$TOKEN"* ]]
    [ ! -s "$STUB_LOG" ]
}

@test "an exported DR_SYNC_CATALOG_ID counts like any other: reused, and --if-set checks it" {
    printf 'export DR_SYNC_CATALOG_ID="%s"\n' "$STORE" >> "$ENV"
    store
    [ "$status" -eq 0 ]
    [ "$(inits)" = 0 ]

    STUB_INSPECT=3 store --if-set
    [ "$status" -eq 1 ]
    [[ "$output" == *"DataRobot can't give state store $STORE"* ]]
}
