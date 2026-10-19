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

@test "--check fails when the token's api-key entry also carries a value or another source" {
    configure write --yes
    cp "$PROJECT/.datarobot.yaml" "$WORK/good"
    sed -i 's#^\( *\)source: api-key$#&\n\1value: dr-credential:0123456789abcdef01234567/apiToken#' "$PROJECT/.datarobot.yaml"
    configure noop --check
    [ "$status" -ne 0 ]

    cp "$WORK/good" "$PROJECT/.datarobot.yaml"
    sed -i 's#^\( *\)source: api-key$#\1drCredentialId: 0123456789abcdef01234567\n&#' "$PROJECT/.datarobot.yaml"
    configure noop --check
    [ "$status" -ne 0 ]

    # A comment under the entry is not a key.
    cp "$WORK/good" "$PROJECT/.datarobot.yaml"
    sed -i 's#^\( *\)source: api-key$#&\n\1\# the platform fills this in#' "$PROJECT/.datarobot.yaml"
    configure noop --check
    [ "$status" -eq 0 ]
}

@test "a sync replaces an api-key entry that also carries a value" {
    configure write --yes
    sed -i 's#^\( *\)source: api-key$#&\n\1value: dr-credential:0123456789abcdef01234567/apiToken#' "$PROJECT/.datarobot.yaml"
    configure noop --sync-env
    [ "$status" -eq 0 ]
    run grep -c dr-credential "$PROJECT/.datarobot.yaml"
    [ "$output" = 0 ]
    configure noop --check
    [ "$status" -eq 0 ]
}

@test "an updated manifest keeps its permissions" {
    configure write --yes
    chmod 600 "$PROJECT/.datarobot.yaml"
    printf 'NEW_SETTING="x"\n' >> "$PROJECT/.env"
    configure write --sync-env --yes
    [ "$status" -eq 0 ]
    grep -q 'name: NEW_SETTING' "$PROJECT/.datarobot.yaml"
    [ "$(stat -c %a "$PROJECT/.datarobot.yaml")" = 600 ]
}

@test "a write that fails halfway leaves the old manifest whole and no temp file" {
    configure write --yes
    cp "$PROJECT/.datarobot.yaml" "$WORK/manifest.before"
    printf 'NEW_SETTING="x"\n' >> "$PROJECT/.env"
    # A cat that writes part of the file and fails, as on a full disk.
    printf '#!/bin/sh\nhead -c 20 "$@"\nexit 1\n' > "$WORK/bin/cat"
    chmod +x "$WORK/bin/cat"
    configure write --sync-env --yes
    [ "$status" -ne 0 ]
    cmp "$WORK/manifest.before" "$PROJECT/.datarobot.yaml"
    [ -z "$(find "$PROJECT" -name '.datarobot.yaml.*')" ]
}

# Two container groups, each with its own primary; Hermes' container is the
# one built from this repo's Dockerfile, in the second group.
two_group_manifest() {
    cat > "$PROJECT/.datarobot.yaml" <<'YAML'
artifact:
  spec:
    containerGroups:
      - name: tools
        containers:
          - name: proxy
            primary: true
            imageUri: registry.example.com/proxy:1
            environmentVars:
              - name: PROXY_MODE
                value: strict
      - name: default
        containers:
          - name: primary
            primary: true
            port: 8642
            imageBuildConfig:
              dockerfile:
                source: provided
            environmentVars:
              - name: SLACK_HOME_CHANNEL
                value: C123
YAML
}

@test "with several container groups, the key goes to the container built from ./Dockerfile" {
    two_group_manifest
    configure noop --sync-env
    [ "$status" -eq 0 ]
    run sed -n '/- name: tools/,/- name: default/p' "$PROJECT/.datarobot.yaml"
    [[ "$output" != *DATAROBOT_API_TOKEN* ]]
    run sed -n '/- name: default/,$p' "$PROJECT/.datarobot.yaml"
    [[ "$output" == *"- name: DATAROBOT_API_TOKEN"* ]]
    configure noop --check
    [ "$status" -eq 0 ]
}

@test "--check fails when the key sits in another group's primary container" {
    two_group_manifest
    sed -i 's#^\( *\)- name: PROXY_MODE$#\1- name: DATAROBOT_API_TOKEN\n\1  source: api-key\n&#' "$PROJECT/.datarobot.yaml"
    configure noop --check
    [ "$status" -ne 0 ]
}

# The api-key entry, or a credential, with a blank line inside the entry.
blank_line_manifest() {
    cat > "$PROJECT/.datarobot.yaml" <<YAML
artifact:
  spec:
    containerGroups:
      - containers:
          - environmentVars:
              - name: DATAROBOT_API_TOKEN

                $1
              - name: SLACK_HOME_CHANNEL
                value: C123
YAML
}

@test "an api-key entry with a blank line inside is hidden from dr whole" {
    blank_line_manifest 'source: api-key'
    configure noop --sync-env
    [ "$status" -eq 0 ]
    run grep -cE 'source: api-key|DATAROBOT_API_TOKEN' "$WORK/seen/manifest"
    [ "$output" = 0 ]
    python3 -c 'import sys, yaml; yaml.safe_load(open(sys.argv[1]))' "$WORK/seen/manifest"
    configure noop --check
    [ "$status" -eq 0 ]
}

@test "a credential entry with a blank line inside is replaced whole" {
    blank_line_manifest 'value: dr-credential:0123456789abcdef01234567/apiToken'
    configure noop --sync-env
    [ "$status" -eq 0 ]
    run grep -c dr-credential "$PROJECT/.datarobot.yaml"
    [ "$output" = 0 ]
    python3 -c 'import sys, yaml; yaml.safe_load(open(sys.argv[1]))' "$PROJECT/.datarobot.yaml"
    [ "$(api_key_entries "$PROJECT/.datarobot.yaml")" = 1 ]
}

@test "a commented-out token entry is not an entry: --check passes and a sync keeps it" {
    configure write --yes
    sed -i 's#^\( *\)- name: SLACK_HOME_CHANNEL$#\1\# - name: DATAROBOT_API_TOKEN\n\1\#   value: dr-credential:0123456789abcdef01234567/apiToken\n&#' \
        "$PROJECT/.datarobot.yaml"
    grep -q '^ *# - name: DATAROBOT_API_TOKEN$' "$PROJECT/.datarobot.yaml"
    configure noop --check
    [ "$status" -eq 0 ]
    configure noop --sync-env
    [ "$status" -eq 0 ]
    [ "$(api_key_entries "$PROJECT/.datarobot.yaml")" = 1 ]
    grep -q '^ *# - name: DATAROBOT_API_TOKEN$' "$PROJECT/.datarobot.yaml"
    python3 -c 'import sys, yaml; yaml.safe_load(open(sys.argv[1]))' "$PROJECT/.datarobot.yaml"
}

@test "a credential entry with a comment inside is replaced whole" {
    cat > "$PROJECT/.datarobot.yaml" <<'YAML'
artifact:
  spec:
    containerGroups:
      - containers:
          - environmentVars:
              - name: DATAROBOT_API_TOKEN
              # rotated by hand
                value: dr-credential:0123456789abcdef01234567/apiToken
              - name: SLACK_HOME_CHANNEL
                value: C123
YAML
    configure noop --sync-env
    [ "$status" -eq 0 ]
    run grep -c dr-credential "$PROJECT/.datarobot.yaml"
    [ "$output" = 0 ]
    python3 -c 'import sys, yaml; yaml.safe_load(open(sys.argv[1]))' "$PROJECT/.datarobot.yaml"
    [ "$(api_key_entries "$PROJECT/.datarobot.yaml")" = 1 ]
    grep -A1 'name: SLACK_HOME_CHANNEL' "$PROJECT/.datarobot.yaml" | grep -q 'value: C123'
}

# The workload's own key, plus a variable whose block value mentions the token.
block_value_manifest() {
    cat > "$PROJECT/.datarobot.yaml" <<'YAML'
artifact:
  spec:
    containerGroups:
      - containers:
          - environmentVars:
              - name: DATAROBOT_API_TOKEN
                source: api-key
              - name: SETUP_NOTES
                value: |
                  - name: DATAROBOT_API_TOKEN
                    value: example
              - name: SLACK_HOME_CHANNEL
                value: C123
YAML
}

@test "the token named inside another variable's block value is not an entry, and a sync keeps the value" {
    block_value_manifest
    configure noop --check
    [ "$status" -eq 0 ]
    python3 -c 'import sys, yaml; print(yaml.safe_load(open(sys.argv[1]))["artifact"]["spec"]["containerGroups"][0]["containers"][0]["environmentVars"][1]["value"], end="")' \
        "$PROJECT/.datarobot.yaml" > "$WORK/notes.before"
    configure noop --sync-env
    [ "$status" -eq 0 ]
    [ "$(api_key_entries "$PROJECT/.datarobot.yaml")" = 1 ]
    python3 -c 'import sys, yaml
envs = yaml.safe_load(open(sys.argv[1]))["artifact"]["spec"]["containerGroups"][0]["containers"][0]["environmentVars"]
print(next(e["value"] for e in envs if e["name"] == "SETUP_NOTES"), end="")' "$PROJECT/.datarobot.yaml" > "$WORK/notes.after"
    cmp "$WORK/notes.before" "$WORK/notes.after"
}

@test "an entry that names the token after another key still counts, so --check fails" {
    configure write --yes
    sed -i 's#^\( *\)- name: SLACK_HOME_CHANNEL$#\1- value: dr-credential:0123456789abcdef01234567/apiToken\n\1  name: DATAROBOT_API_TOKEN\n&#' \
        "$PROJECT/.datarobot.yaml"
    grep -q '^ *name: DATAROBOT_API_TOKEN$' "$PROJECT/.datarobot.yaml"
    configure noop --check
    [ "$status" -ne 0 ]
}

@test "in an indentationless list, the key goes in at the column of the other items" {
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
    configure noop --sync-env
    [ "$status" -eq 0 ]
    run grep -c dr-credential "$PROJECT/.datarobot.yaml"
    [ "$output" = 0 ]
    grep -qx '            - name: DATAROBOT_API_TOKEN' "$PROJECT/.datarobot.yaml"
    grep -qx '              source: api-key' "$PROJECT/.datarobot.yaml"
    python3 -c 'import sys, yaml
envs = yaml.safe_load(open(sys.argv[1]))["artifact"]["spec"]["containerGroups"][0]["containers"][0]["environmentVars"]
assert envs == [{"name": "DATAROBOT_API_TOKEN", "source": "api-key"}, {"name": "SLACK_HOME_CHANNEL", "value": "C123"}], envs' \
        "$PROJECT/.datarobot.yaml"
    configure noop --check
    [ "$status" -eq 0 ]
}

# The workload's own key in the primary container, and a sidecar whose
# environmentVars list sits on the key's own line: $1.
inline_env_manifest() {
    cat > "$PROJECT/.datarobot.yaml" <<YAML
artifact:
  spec:
    containerGroups:
      - containers:
          - name: hermes
            primary: true
            environmentVars:
              - name: DATAROBOT_API_TOKEN
                source: api-key
          - name: sidecar
            environmentVars: $1
YAML
}

@test "a token in a sidecar's one-line environmentVars list fails --check, and a sync won't write" {
    inline_env_manifest '[{name: DATAROBOT_API_TOKEN, value: "dr-credential:0123456789abcdef01234567/apiToken"}]'
    configure noop --check
    [ "$status" -ne 0 ]
    cp "$PROJECT/.datarobot.yaml" "$WORK/manifest.before"
    configure noop --sync-env
    [ "$status" -ne 0 ]
    cmp "$WORK/manifest.before" "$PROJECT/.datarobot.yaml"
}

@test "one-line environmentVars lists without the token are fine" {
    inline_env_manifest '[{name: LOG_LEVEL, value: info}]'
    configure noop --check
    [ "$status" -eq 0 ]
    inline_env_manifest '[]'
    configure noop --check
    [ "$status" -eq 0 ]
}

@test "a one-line environmentVars list continued on later lines fails --check" {
    inline_env_manifest '[{name: LOG_LEVEL, value: info},'
    printf '              {name: DATAROBOT_API_TOKEN, value: x}]\n' >> "$PROJECT/.datarobot.yaml"
    configure noop --check
    [ "$status" -ne 0 ]
}

# The state store's id from scripts/state-store.sh: hex, so dr's detector
# would take it for a secret.
STORE=0123456789abcdef01234567

store_entries() {
    grep -cE '^ *- name: DR_SYNC_CATALOG_ID$' "$1" || true
}

@test "dr never sees the state store's id, and the manifest declares it once, as a plain value" {
    printf 'DR_SYNC_CATALOG_ID="%s"\n' "$STORE" >> "$PROJECT/.env"
    configure write --yes
    [ "$status" -eq 0 ]
    ! grep -q DR_SYNC_CATALOG_ID "$WORK/seen/env" || false
    [ "$(store_entries "$PROJECT/.datarobot.yaml")" = 1 ]
    grep -A1 -E '^ *- name: DR_SYNC_CATALOG_ID$' "$PROJECT/.datarobot.yaml" | grep -qx "                value: \"$STORE\""
    run grep -c 'dr-credential' "$PROJECT/.datarobot.yaml"
    [ "$output" = 0 ]
    python3 -c 'import sys, yaml
envs = yaml.safe_load(open(sys.argv[1]))["artifact"]["spec"]["containerGroups"][0]["containers"][0]["environmentVars"]
assert {"name": "DR_SYNC_CATALOG_ID", "value": sys.argv[2]} in envs, envs' "$PROJECT/.datarobot.yaml" "$STORE"
    configure noop --check
    [ "$status" -eq 0 ]
}

@test "a store id the manifest holds as a credential becomes the plain value, hidden from dr" {
    printf 'DR_SYNC_CATALOG_ID="%s"\n' "$STORE" >> "$PROJECT/.env"
    configure write --yes
    sed -i "s#^\( *\)value: \"$STORE\"\$#\1value: dr-credential:abcabcabcabcabcabcabcabc/apiToken#" "$PROJECT/.datarobot.yaml"
    grep -q 'dr-credential:abcabcabcabcabcabcabcabc' "$PROJECT/.datarobot.yaml"
    configure noop --sync-env
    [ "$status" -eq 0 ]
    ! grep -q DR_SYNC_CATALOG_ID "$WORK/seen/manifest" || false
    ! grep -q 'dr-credential:abcabcabcabcabcabcabcabc' "$PROJECT/.datarobot.yaml" || false
    [ "$(store_entries "$PROJECT/.datarobot.yaml")" = 1 ]
    grep -q "value: \"$STORE\"" "$PROJECT/.datarobot.yaml"
}

@test "with the store id already right, the manifest is left byte for byte" {
    printf 'DR_SYNC_CATALOG_ID="%s"\n' "$STORE" >> "$PROJECT/.env"
    configure write --yes
    cp "$PROJECT/.datarobot.yaml" "$WORK/manifest.before"
    configure noop --sync-env
    [ "$status" -eq 0 ]
    cmp "$WORK/manifest.before" "$PROJECT/.datarobot.yaml"
}

@test "a store entry with YAML comments is read as right, and kept byte for byte with them" {
    printf 'DR_SYNC_CATALOG_ID="%s"\n' "$STORE" >> "$PROJECT/.env"
    configure write --yes
    sed -i "s#^\( *\)- name: DR_SYNC_CATALOG_ID\$#\1- name: DR_SYNC_CATALOG_ID   \# the state store#; s#^\( *\)value: \"$STORE\"\$#\1value: \"$STORE\"   \# from dr start#" "$PROJECT/.datarobot.yaml"
    grep -q 'DR_SYNC_CATALOG_ID   # the state store' "$PROJECT/.datarobot.yaml"
    cp "$PROJECT/.datarobot.yaml" "$WORK/manifest.before"
    configure noop --sync-env
    [ "$status" -eq 0 ]
    cmp "$WORK/manifest.before" "$PROJECT/.datarobot.yaml"
    configure noop --check
    [ "$status" -eq 0 ]
}

@test "a changed store id in .env is carried over, and one gone from .env is removed" {
    printf 'DR_SYNC_CATALOG_ID="%s"\n' "$STORE" >> "$PROJECT/.env"
    configure write --yes
    sed -i 's/^DR_SYNC_CATALOG_ID=.*/DR_SYNC_CATALOG_ID=fedcba9876543210fedcba98/' "$PROJECT/.env"
    configure noop --sync-env
    [ "$status" -eq 0 ]
    [ "$(store_entries "$PROJECT/.datarobot.yaml")" = 1 ]
    grep -q 'value: "fedcba9876543210fedcba98"' "$PROJECT/.datarobot.yaml"

    sed -i '/^DR_SYNC_CATALOG_ID=/d' "$PROJECT/.env"
    configure noop --sync-env
    [ "$status" -eq 0 ]
    [ "$(store_entries "$PROJECT/.datarobot.yaml")" = 0 ]
}

@test "a store id that can't be one is refused before dr runs" {
    for bad in 'abc" injected' not-a-store 0123456789ABCDEF01234567 0123456789abcdef0123456; do
        sed -i '/^DR_SYNC_CATALOG_ID=/d' "$PROJECT/.env"
        printf 'DR_SYNC_CATALOG_ID="%s"\n' "$bad" >> "$PROJECT/.env"
        configure write --yes
        [ "$status" -ne 0 ]
        [[ "$output" == *"isn't a store id"* ]]
        [ ! -e "$WORK/seen/env" ]
        [ ! -e "$PROJECT/.datarobot.yaml" ]
    done
}

@test "a caller's --dir is refused before dr runs, in either form" {
    for args in "--yes --dir ." "--yes --dir=." "--sync-env --dir=$PROJECT"; do
        rm -f "$WORK/seen/env"
        # shellcheck disable=SC2086
        configure write $args
        [ "$status" -eq 2 ]
        [[ "$output" == *"--dir isn't accepted"* ]]
        [ ! -e "$WORK/seen/env" ]
        [ ! -e "$PROJECT/.datarobot.yaml" ]
    done
}

@test "an unreadable .env stops the run before dr sees an empty one" {
    configure write --yes
    cp "$PROJECT/.datarobot.yaml" "$WORK/manifest.before"
    rm -f "$WORK/seen/env"
    chmod 000 "$PROJECT/.env"
    configure write --sync-env --yes
    chmod 600 "$PROJECT/.env"
    [ "$status" -ne 0 ]
    [[ "$output" == *"Couldn't read .env"* ]]
    [ ! -e "$WORK/seen/env" ]
    cmp "$WORK/manifest.before" "$PROJECT/.datarobot.yaml"
}

@test "an .env holding only the token is fine: dr gets an empty one" {
    printf 'DATAROBOT_API_TOKEN="%s"\n' "$CANARY" > "$PROJECT/.env"
    configure noop --yes
    [ "$status" -eq 0 ]
    [ ! -s "$WORK/seen/env" ]
}

@test "--dry-run=true is a preview too, and --dry-run=false a normal write" {
    credential_manifest
    cp "$PROJECT/.datarobot.yaml" "$WORK/manifest.before"
    for flag in --dry-run=true --dry-run=1 --dry-run=TRUE; do
        configure noop --sync-env "$flag"
        [ "$status" -eq 0 ]
        cmp "$WORK/manifest.before" "$PROJECT/.datarobot.yaml"
    done
    configure noop --sync-env --dry-run=false
    [ "$status" -eq 0 ]
    [ "$(api_key_entries "$PROJECT/.datarobot.yaml")" = 1 ]
}
