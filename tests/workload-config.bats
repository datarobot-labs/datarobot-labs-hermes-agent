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

# Behaviour of scripts/workload-config.sh: the deploying user's
# DATAROBOT_API_TOKEN never reaches `dr workload config`, and the manifest
# declares the workload's own key instead. `dr` is a stub that records what it
# was shown and edits the manifest the way the real command does.

CANARY=canary-user-token-0123456789

setup() {
    WORK=$(mktemp -d)
    PROJECT="$WORK/project"
    mkdir -p "$PROJECT" "$WORK/bin"
    cp /repo/Dockerfile "$PROJECT/"
    printf 'DATAROBOT_ENDPOINT="https://example.datarobot.com/api/v2"\nDATAROBOT_API_TOKEN="%s"\nSLACK_HOME_CHANNEL="C123"\n' \
        "$CANARY" > "$PROJECT/.env"

    # dr workload config --dir DIR ...: saves DIR's .env and manifest as it
    # found them, then acts per STUB_DR: "write" lists every .env name in a
    # fresh manifest, "noop" changes nothing, "fail" exits 1.
    cat > "$WORK/bin/dr" <<'STUB'
#!/bin/sh
dir=
prev=
for arg in "$@"; do
    [ "$prev" = --dir ] && dir=$arg
    prev=$arg
done
cp "$dir/.env" "$STUB_SEEN/env"
[ ! -f "$dir/.datarobot.yaml" ] || cp "$dir/.datarobot.yaml" "$STUB_SEEN/manifest"
case "$STUB_DR" in
    fail) exit 1 ;;
    noop) exit 0 ;;
esac
{
    printf 'name: hermes-agent\nartifact:\n  spec:\n    containerGroups:\n      - name: default\n        containers:\n          - name: primary\n            environmentVars:\n'
    sed -nE 's/^([A-Z_]+)=.*/              - name: \1\n                value: x/p' "$dir/.env"
    printf 'runtime: {}\n'
} > "$dir/.datarobot.yaml"
STUB
    chmod +x "$WORK/bin/dr"
    mkdir -p "$WORK/seen"
}

teardown() {
    rm -rf "$WORK"
}

# configure MODE ARGS...: run the script in the project with the stub in MODE.
configure() {
    local mode=$1
    shift
    cd "$PROJECT"
    PATH="$WORK/bin:$PATH" STUB_DR=$mode STUB_SEEN="$WORK/seen" \
        run sh /repo/scripts/workload-config.sh "$@"
}

api_key_entries() {
    grep -A1 -E '^[[:space:]]*- name: DATAROBOT_API_TOKEN$' "$1" | grep -cE '^[[:space:]]*source: api-key$'
}

@test "dr never sees the user's DATAROBOT_API_TOKEN, and .env stays as it was" {
    cp "$PROJECT/.env" "$WORK/env.before"
    configure write --yes
    [ "$status" -eq 0 ]
    run grep -c "$CANARY" "$WORK/seen/env"
    [ "$output" = 0 ]
    grep -q '^SLACK_HOME_CHANNEL=' "$WORK/seen/env"
    cmp "$WORK/env.before" "$PROJECT/.env"
}

@test "a new manifest declares the token as the workload's own key, once" {
    configure write --yes
    [ "$status" -eq 0 ]
    [ "$(api_key_entries "$PROJECT/.datarobot.yaml")" = 1 ]
    run grep -c "$CANARY" "$PROJECT/.datarobot.yaml"
    [ "$output" = 0 ]
    grep -q 'name: SLACK_HOME_CHANNEL' "$PROJECT/.datarobot.yaml"
}

@test "dr doesn't see the api-key entry, so --sync-env can't remove it" {
    configure write --yes
    configure write --sync-env --yes
    [ "$status" -eq 0 ]
    run grep -c DATAROBOT_API_TOKEN "$WORK/seen/manifest"
    [ "$output" = 0 ]
    [ "$(api_key_entries "$PROJECT/.datarobot.yaml")" = 1 ]
}

@test "the manifest is left byte for byte when dr changes nothing" {
    # The api-key entry sits last; writing the file back would move it first.
    cat > "$PROJECT/.datarobot.yaml" <<'EOF'
artifact:
  spec:
    containerGroups:
      - containers:
          - environmentVars:
              - name: SLACK_HOME_CHANNEL
                value: C123  # hand edit
              - name: DATAROBOT_API_TOKEN
                source: api-key
EOF
    cp "$PROJECT/.datarobot.yaml" "$WORK/manifest.before"
    configure noop --sync-env
    [ "$status" -eq 0 ]
    cmp "$WORK/manifest.before" "$PROJECT/.datarobot.yaml"
}

@test "a failing dr fails the script and leaves the manifest alone" {
    configure write --yes
    cp "$PROJECT/.datarobot.yaml" "$WORK/manifest.before"
    configure fail --sync-env
    [ "$status" -ne 0 ]
    cmp "$WORK/manifest.before" "$PROJECT/.datarobot.yaml"
}

@test "a token held as a credential is replaced by the workload's own key" {
    configure write --yes
    sed -i 's#^\( *\)source: api-key$#\1value: dr-credential:0123456789abcdef01234567/apiToken#' \
        "$PROJECT/.datarobot.yaml"
    configure write --sync-env --yes
    [ "$status" -eq 0 ]
    run grep -c dr-credential "$PROJECT/.datarobot.yaml"
    [ "$output" = 0 ]
    [ "$(api_key_entries "$PROJECT/.datarobot.yaml")" = 1 ]
}

# A manifest that hands the workload a token from .env as a credential.
credential_manifest() {
    cat > "$PROJECT/.datarobot.yaml" <<'YAML'
artifact:
  spec:
    containerGroups:
      - containers:
          - environmentVars:
              - name: DATAROBOT_API_TOKEN
                value: dr-credential:0123456789abcdef01234567/apiToken
              - name: SLACK_HOME_CHANNEL
                value: C123
YAML
}

@test "a credential dr keeps, say because the removal was declined, is still replaced" {
    credential_manifest
    configure noop --sync-env
    [ "$status" -eq 0 ]
    run grep -c dr-credential "$PROJECT/.datarobot.yaml"
    [ "$output" = 0 ]
    [ "$(api_key_entries "$PROJECT/.datarobot.yaml")" = 1 ]
    grep -q 'name: SLACK_HOME_CHANNEL' "$PROJECT/.datarobot.yaml"
}

@test "a dry run writes nothing, even to a manifest that needs fixing" {
    credential_manifest
    cp "$PROJECT/.datarobot.yaml" "$WORK/manifest.before"
    configure noop --sync-env --dry-run
    [ "$status" -eq 0 ]
    cmp "$WORK/manifest.before" "$PROJECT/.datarobot.yaml"
}

@test "--check passes only when the workload's own key is the sole token entry" {
    configure write --yes
    configure noop --check
    [ "$status" -eq 0 ]

    credential_manifest
    configure noop --check
    [ "$status" -ne 0 ]

    # The api-key entry plus a second, flow-style one carrying a credential.
    configure write --yes
    sed -i 's#^\( *\)- name: SLACK_HOME_CHANNEL$#\1- {name: DATAROBOT_API_TOKEN, value: "dr-credential:0123456789abcdef01234567/apiToken"}\n&#' \
        "$PROJECT/.datarobot.yaml"
    configure noop --check
    [ "$status" -ne 0 ]
}

# Two containers under artifact, the sidecar first, and runtime's own list.
two_container_manifest() {
    cat > "$PROJECT/.datarobot.yaml" <<'YAML'
artifact:
  spec:
    containerGroups:
      - name: default
        containers:
          - name: sidecar
            environmentVars:
              - name: SIDE
                value: x
          - name: primary
            primary: true
            environmentVars:
              - name: SLACK_HOME_CHANNEL
                value: C123
runtime:
  containerGroups:
    - name: default
      containers:
        - name: primary
          resourceAllocation: {cpu: 1, memory: 2GB}
YAML
}

@test "the key goes to the primary container, not the first one listed" {
    two_container_manifest
    configure noop --sync-env
    [ "$status" -eq 0 ]
    run sed -n '/- name: sidecar/,/- name: primary/p' "$PROJECT/.datarobot.yaml"
    [[ "$output" != *DATAROBOT_API_TOKEN* ]]
    run sed -n '/- name: primary/,/^runtime:/p' "$PROJECT/.datarobot.yaml"
    [[ "$output" == *"- name: DATAROBOT_API_TOKEN"* ]]
    configure noop --check
    [ "$status" -eq 0 ]
}

@test "--check fails when the key sits in a sidecar instead of the primary container" {
    two_container_manifest
    sed -i 's#^\( *\)- name: SIDE$#\1- name: DATAROBOT_API_TOKEN\n\1  source: api-key\n&#' "$PROJECT/.datarobot.yaml"
    configure noop --check
    [ "$status" -ne 0 ]
}

@test "with no way to tell the primary container, nothing is written" {
    two_container_manifest
    sed -i '/primary: true/d' "$PROJECT/.datarobot.yaml"
    cp "$PROJECT/.datarobot.yaml" "$WORK/manifest.before"
    configure noop --sync-env
    [ "$status" -ne 0 ]
    [[ "$output" == *"primary: true"* ]]
    cmp "$WORK/manifest.before" "$PROJECT/.datarobot.yaml"
}
