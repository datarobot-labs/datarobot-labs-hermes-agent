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

# Behaviour of scripts/state-store.sh against stub curl and dr-sync: a store
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

    # curl: answers a store probe with STUB_HTTP (default 200), saving the
    # header it read on stdin; a download writes a file that is no tarball.
    cat > "$WORK/bin/curl" <<'STUB'
#!/bin/sh
echo "curl $*" >> "$STUB_LOG"
case " $* " in
    *" -H @- "*) cat > "$STUB_DIR/curl.stdin" ;;
esac
case " $* " in
    *" -o /dev/null "*) printf '%s' "${STUB_HTTP:-200}" ;;
    *)
        prev=
        for a in "$@"; do [ "$prev" = -o ] && echo "not a release" > "$a"; prev=$a; done
        ;;
esac
STUB
    # dr-sync: records its arguments and the token it was given, prints STUB_ID.
    cat > "$WORK/bin/dr-sync" <<'STUB'
#!/bin/sh
echo "dr-sync $*" >> "$STUB_LOG"
echo "$DATAROBOT_API_TOKEN" > "$STUB_DIR/dr-sync.token"
echo "${STUB_ID-0123456789abcdef01234567}"
STUB
    chmod +x "$WORK/bin/curl" "$WORK/bin/dr-sync"
}

teardown() {
    rm -rf "$WORK"
}

# store [--check]: run the script on $ENV with the stubs.
store() {
    PATH="$WORK/bin:$PATH" DR_SYNC_BIN="${DR_SYNC_BIN-$WORK/bin/dr-sync}" \
        run sh /repo/scripts/state-store.sh "$@" "$ENV"
}

inits() {
    grep -c '^dr-sync init' "$STUB_LOG" || true
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
    grep -qx "dr-sync init --name hermes-agent-state --tag hermes_state" "$STUB_LOG"
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
    grep -qx "dr-sync init --name my-bot-state --tag hermes_state" "$STUB_LOG"
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
    grep -q "catalogItems/$STORE/" "$STUB_LOG"
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

        # And it still counts as set when persistence is turned off.
        printf 'PERSIST_STATE=no\n' >> "$ENV"
        store --check
        [ "$status" -eq 1 ]
        [[ "$output" == *"still set in .datarobot.yaml"* ]]
        cp "$WORK/before" "$ENV"
    done
}

@test "a comment naming DR_SYNC_CATALOG_ID in .datarobot.yaml is not a declaration" {
    manifest hermes-agent '              # DR_SYNC_CATALOG_ID is added by dr start'
    store
    [ "$status" -eq 0 ]
    [ "$(inits)" = 1 ]
}

@test "an id DataRobot no longer knows stops the run and is never replaced" {
    for code in 404 410; do
        printf 'DR_SYNC_CATALOG_ID="%s"\n' "$STORE" >> "$ENV"
        cp "$ENV" "$WORK/before"
        STUB_HTTP=$code store
        [ "$status" -eq 1 ]
        [[ "$output" == *"DataRobot has no state store $STORE (HTTP $code)"* ]]
        [[ "$output" == *"State store not found"* ]]
        cmp "$WORK/before" "$ENV"
    done
    [ "$(inits)" = 0 ]
}

@test "an id that can't be checked, say with a bad login, changes nothing" {
    printf 'DR_SYNC_CATALOG_ID="%s"\n' "$STORE" >> "$ENV"
    cp "$ENV" "$WORK/before"
    STUB_HTTP=401 store
    [ "$status" -eq 1 ]
    [[ "$output" == *"Could not check state store $STORE (HTTP 401); nothing was changed."* ]]
    [ "$(inits)" = 0 ]
    cmp "$WORK/before" "$ENV"
}

@test "the token reaches curl on stdin and dr-sync in its environment, never a command line" {
    store
    [ "$status" -eq 0 ]
    store
    [ "$status" -eq 0 ]
    ! grep -q "$TOKEN" "$STUB_LOG" || false
    [[ "$output" != *"$TOKEN"* ]]
    grep -qx "Authorization: Bearer $TOKEN" "$WORK/curl.stdin"
    [ "$(cat "$WORK/dr-sync.token")" = "$TOKEN" ]
}

@test "PERSIST_STATE=no turns it all off" {
    for answer in no No false 0 off; do
        printf 'PERSIST_STATE=%s\n' "$answer" > "$ENV.persist"
        cat "$ENV.persist" >> "$ENV"
        cp "$ENV" "$WORK/before"
        store
        [ "$status" -eq 0 ]
        [[ "$output" == *"Persistence is off"* ]]
        cmp "$WORK/before" "$ENV"
        sed -i '/^PERSIST_STATE=/d' "$ENV"
    done
    rm -f "$ENV.persist"
    [ ! -s "$STUB_LOG" ]
}

@test "PERSIST_STATE=no with a store id still set says the workload still persists" {
    printf 'PERSIST_STATE=no\nDR_SYNC_CATALOG_ID="%s"\n' "$STORE" >> "$ENV"
    store
    [ "$status" -eq 0 ]
    [[ "$output" == *"DR_SYNC_CATALOG_ID is still set in $ENV, so the workload"* ]]
    [[ "$output" != *"starts fresh"* ]]
    store --check
    [ "$status" -eq 1 ]

    # Gone from .env but still in the manifest: the deployed workload has it.
    sed -i '/^DR_SYNC_CATALOG_ID=/d' "$ENV"
    manifest hermes-agent "              - name: DR_SYNC_CATALOG_ID
                value: \"$STORE\""
    store --check
    [ "$status" -eq 1 ]
    [[ "$output" == *"still set in .datarobot.yaml"* ]]

    rm "$WORK/.datarobot.yaml"
    store --check
    [ "$status" -eq 0 ]
    [[ "$output" == *"Persistence is off"* ]]
    [ ! -s "$STUB_LOG" ]
}

@test "a dr-sync that prints no store id leaves .env alone" {
    cp "$ENV" "$WORK/before"
    STUB_ID='Error: something went wrong' store
    [ "$status" -eq 1 ]
    [[ "$output" == *"didn't print a store id"* ]]
    cmp "$WORK/before" "$ENV"
    no_leftovers
}

@test "a downloaded dr-sync that fails its checksum is never run" {
    cp "$ENV" "$WORK/before"
    DR_SYNC_BIN= store
    [ "$status" -eq 1 ]
    [[ "$output" == *"doesn't match its checksum"* ]]
    grep -q '^curl -fsSL -o .*/dr-sync.tar.gz https://github.com/datarobot-labs/datarobot-sync/releases/download/v' "$STUB_LOG"
    [ "$(inits)" = 0 ]
    cmp "$WORK/before" "$ENV"
}

@test "without DataRobot credentials in .env it stops before calling anything" {
    printf 'PERSIST_STATE=yes\n' > "$ENV"
    DATAROBOT_ENDPOINT= DATAROBOT_API_TOKEN= store
    [ "$status" -eq 1 ]
    [[ "$output" == *"no DATAROBOT_ENDPOINT or DATAROBOT_API_TOKEN"* ]]
    [ ! -s "$STUB_LOG" ]
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

    STUB_HTTP=404 store --check
    [ "$status" -eq 1 ]
    [ "$(inits)" = 0 ]
}
