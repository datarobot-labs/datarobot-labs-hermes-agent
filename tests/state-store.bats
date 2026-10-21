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

    # dr: records its arguments and the token it was handed, if any.
    # `dr sync inspect` exits STUB_INSPECT (default 0), the way dr sync
    # exits 3 for a store DataRobot doesn't have; `dr sync init` prints STUB_ID.
    cat > "$WORK/bin/dr" <<'STUB'
#!/bin/sh
echo "dr $*" >> "$STUB_LOG"
echo "${DATAROBOT_API_TOKEN:-}" > "$STUB_DIR/dr.token"
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

no_leftovers() {
    [ -z "$(find "$WORK" -name '.env.*')" ]
}

@test "with no store yet, one is created for the workload and its id written to .env" {
    store
    [ "$status" -eq 0 ]
    [[ "$output" == *"Created state store $STORE (\"hermes-agent-state\")"* ]]
    grep -qx "dr sync init --name hermes-agent-state --tag hermes_state" "$STUB_LOG"
    grep -qx "DR_SYNC_CATALOG_ID=\"$STORE\"" "$ENV"
    grep -qx "DATAROBOT_API_TOKEN=\"$TOKEN\"" "$ENV"
    [ "$(stat -c %a "$ENV")" = 600 ]
    no_leftovers
}

@test "the store is named after the workload in .datarobot.yaml" {
    manifest my-bot '              - name: SLACK_HOME_CHANNEL
                value: C123'
    store
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

@test "duplicate DR_SYNC_CATALOG_ID lines become the one new id, and a re-run reuses it" {
    printf 'DR_SYNC_CATALOG_ID=\nSLACK_HOME_CHANNEL=C1\nDR_SYNC_CATALOG_ID=\n' >> "$ENV"
    store
    [ "$status" -eq 0 ]
    [ "$(grep -c '^DR_SYNC_CATALOG_ID=' "$ENV")" = 1 ]
    grep -qx "DR_SYNC_CATALOG_ID=\"$STORE\"" "$ENV"
    grep -qx 'SLACK_HOME_CHANNEL=C1' "$ENV"
    store
    [ "$status" -eq 0 ]
    [ "$(inits)" = 1 ]
}

@test "an empty DR_SYNC_CATALOG_ID line is filled in place, not added twice" {
    echo 'DR_SYNC_CATALOG_ID=' >> "$ENV"
    store
    [ "$status" -eq 0 ]
    [ "$(grep -c '^DR_SYNC_CATALOG_ID=' "$ENV")" = 1 ]
    grep -qx "DR_SYNC_CATALOG_ID=\"$STORE\"" "$ENV"
}

@test "an id from .datarobot.yaml is checked, reused and copied into .env" {
    manifest hermes-agent "              - name: DR_SYNC_CATALOG_ID
                value: \"$STORE\""
    store
    [ "$status" -eq 0 ]
    [[ "$output" == *"from .datarobot.yaml"* ]]
    [ "$(inits)" = 0 ]
    grep -qx "DR_SYNC_CATALOG_ID=\"$STORE\"" "$ENV"
    grep -qx "inspect $STORE" "$STUB_LOG"
}

@test "a manifest entry with YAML comments is still read, so no second store is made" {
    manifest hermes-agent "              - name: DR_SYNC_CATALOG_ID   # the state store
                value: \"$STORE\"   # from dr start"
    store
    [ "$status" -eq 0 ]
    [[ "$output" == *"from .datarobot.yaml"* ]]
    [ "$(inits)" = 0 ]
    grep -qx "DR_SYNC_CATALOG_ID=\"$STORE\"" "$ENV"
}

@test "an id dr stored in .datarobot.yaml as a credential stops the run instead of making a second store" {
    manifest hermes-agent '              - name: DR_SYNC_CATALOG_ID
                value: dr-credential:0123456789abcdef01234567/apiToken'
    cp "$ENV" "$WORK/before"
    store
    [ "$status" -eq 1 ]
    [[ "$output" == *"declares DR_SYNC_CATALOG_ID, but not as a plain value"* ]]
    [ "$(inits)" = 0 ]
    cmp "$WORK/before" "$ENV"
}

@test "an id declared in another YAML layout stops the run instead of making a second store" {
    for entry in "              - {name: DR_SYNC_CATALOG_ID, value: \"$STORE\"}" \
        "              - value: \"$STORE\"
                name: DR_SYNC_CATALOG_ID"; do
        manifest hermes-agent "$entry"
        cp "$ENV" "$WORK/before"
        store
        [ "$status" -eq 1 ]
        [[ "$output" == *"declares DR_SYNC_CATALOG_ID, but not as a plain value"* ]]
        [ "$(inits)" = 0 ]
        cmp "$WORK/before" "$ENV"
    done
}

@test "a comment naming DR_SYNC_CATALOG_ID in .datarobot.yaml is not a declaration" {
    manifest hermes-agent '              # DR_SYNC_CATALOG_ID is added by dr start'
    store
    [ "$status" -eq 0 ]
    [ "$(inits)" = 1 ]
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

    # The same from .datarobot.yaml, with no id in .env.
    sed -i '/^DR_SYNC_CATALOG_ID=/d' "$ENV"
    manifest hermes-agent "              - name: DR_SYNC_CATALOG_ID
                value: \"$TOKEN\""
    store
    [ "$status" -eq 1 ]
    [[ "$output" == *"DR_SYNC_CATALOG_ID in .datarobot.yaml isn't a store id"* ]]
    [[ "$output" != *"$TOKEN"* ]]
    [ ! -s "$STUB_LOG" ]
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

@test "a dr sync init that prints no store id leaves .env alone" {
    cp "$ENV" "$WORK/before"
    STUB_ID='Error: something went wrong' store
    [ "$status" -eq 1 ]
    [[ "$output" == *"didn't print a store id"* ]]
    cmp "$WORK/before" "$ENV"
    no_leftovers
}

@test "a manifest naming a different store than .env is pointed out, not changed" {
    printf 'DR_SYNC_CATALOG_ID="%s"\n' "$STORE" >> "$ENV"
    manifest hermes-agent '              - name: DR_SYNC_CATALOG_ID
                value: "abcabcabcabcabcabcabcabc"'
    cp "$WORK/.datarobot.yaml" "$WORK/before"
    store
    [ "$status" -eq 0 ]
    [[ "$output" == *"names a different state store than $ENV"* ]]
    [[ "$output" == *"Run 'dr run env' before you deploy"* ]]
    cmp "$WORK/before" "$WORK/.datarobot.yaml"
    [ "$(inits)" = 0 ]

    # The same store: nothing to say.
    manifest hermes-agent "              - name: DR_SYNC_CATALOG_ID
                value: \"$STORE\""
    store
    [ "$status" -eq 0 ]
    [[ "$output" != *"different state store"* ]]

    # Not declared at all: dr start's manifest step already names it.
    manifest hermes-agent '              - name: SLACK_HOME_CHANNEL
                value: C123'
    store
    [ "$status" -eq 0 ]
    [[ "$output" != *"different state store"* ]]
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
