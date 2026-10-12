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

# Behaviour of scripts/llm-gateway-url.sh: LLM_BASE_URL follows
# DATAROBOT_ENDPOINT, a hand-set value is left alone, and rewriting .env never
# leaves a copy of its secrets behind.

MARKER='# Follows DATAROBOT_ENDPOINT (set by dr start). Delete this line to set your own.'

setup() {
    WORK=$(mktemp -d)
    ENV="$WORK/.env"
    printf 'DATAROBOT_ENDPOINT="https://one.example.com/api/v2"\nSLACK_BOT_TOKEN="secret-canary"\n' > "$ENV"
    chmod 600 "$ENV"
}

teardown() {
    rm -rf "$WORK"
}

gateway() {
    run sh /repo/scripts/llm-gateway-url.sh "$ENV"
}

no_leftovers() {
    [ -z "$(find "$WORK" -name '.env.*')" ]
}

@test "the first run adds LLM_BASE_URL for the endpoint's install, under the marker" {
    gateway
    [ "$status" -eq 0 ]
    grep -qxF "$MARKER" "$ENV"
    grep -A1 -xF "$MARKER" "$ENV" | grep -qx 'LLM_BASE_URL="https://one.example.com/api/v2/genai/llmgw"'
}

@test "a second run with the same endpoint changes nothing" {
    gateway
    cp "$ENV" "$WORK/before"
    gateway
    [ "$status" -eq 0 ]
    cmp "$WORK/before" "$ENV"
    no_leftovers
}

@test "the value follows a changed endpoint, keeping .env's permissions" {
    gateway
    sed -i 's#^DATAROBOT_ENDPOINT=.*#DATAROBOT_ENDPOINT="https://two.example.com/api/v2/"#' "$ENV"
    gateway
    [ "$status" -eq 0 ]
    [[ "$output" == *"now follows DATAROBOT_ENDPOINT"* ]]
    grep -qx 'LLM_BASE_URL="https://two.example.com/api/v2/genai/llmgw"' "$ENV"
    grep -qx 'SLACK_BOT_TOKEN="secret-canary"' "$ENV"
    [ "$(stat -c %a "$ENV")" = 600 ]
    no_leftovers
}

@test "a value without the marker was set by hand and stays" {
    printf 'LLM_BASE_URL="https://my-gateway.example.com/v1"\n' >> "$ENV"
    cp "$ENV" "$WORK/before"
    gateway
    [ "$status" -eq 0 ]
    cmp "$WORK/before" "$ENV"
    no_leftovers
}

@test "an interrupted rewrite leaves .env as it was and no copy of it behind" {
    gateway
    sed -i 's#one.example.com#two.example.com#' "$ENV"
    sed -i 's#^LLM_BASE_URL=.*#LLM_BASE_URL="https://one.example.com/api/v2/genai/llmgw"#' "$ENV"
    cp "$ENV" "$WORK/before"
    # An awk that hangs, so the run can be stopped mid-rewrite.
    mkdir "$WORK/bin"
    printf '#!/bin/sh\nexec sleep 30\n' > "$WORK/bin/awk"
    chmod +x "$WORK/bin/awk"

    PATH="$WORK/bin:$PATH" sh /repo/scripts/llm-gateway-url.sh "$ENV" 3>&- &
    pid=$!
    for _ in $(seq 50); do
        tmp=$(find "$WORK" -name '.env.*' | head -n 1)
        [ -z "$tmp" ] || break
        sleep 0.1
    done
    [ -n "$tmp" ]
    # Readable by its owner only while it holds the secrets.
    [ "$(stat -c %a "$tmp")" = 600 ]

    kill -TERM "$pid"
    pkill -f 'sleep 30' || true
    wait "$pid" || true
    no_leftovers
    cmp "$WORK/before" "$ENV"
}

@test "under dr run env, the move is reported without the 'run dr run env' hint" {
    gateway
    sed -i 's#^DATAROBOT_ENDPOINT=.*#DATAROBOT_ENDPOINT="https://two.example.com/api/v2"#' "$ENV"
    LLM_GATEWAY_SYNCING=1 run sh /repo/scripts/llm-gateway-url.sh "$ENV"
    [ "$status" -eq 0 ]
    [[ "$output" == *"now follows DATAROBOT_ENDPOINT"* ]]
    [[ "$output" != *"Run 'dr run env'"* ]]
}
