#!/bin/sh
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

# Keeps LLM_BASE_URL in .env on the LLM gateway of the DataRobot install that
# DATAROBOT_ENDPOINT names. `dr start` runs it.
#
# The Dockerfile defaults LLM_BASE_URL to app.datarobot.com's gateway, which
# is the wrong one on any other install. The value this script writes carries
# a marker line, and every run recomputes it, so it follows a changed
# DATAROBOT_ENDPOINT. A value without the marker was set by hand and is left
# alone.
#
# Usage: scripts/llm-gateway-url.sh [env file, default .env]

set -eu

env_file=${1:-.env}
marker='# Follows DATAROBOT_ENDPOINT (set by dr start). Delete this line to set your own.'

endpoint=$(sed -n 's/^DATAROBOT_ENDPOINT=//p' "$env_file" | tail -n 1)
# dotenv allows double, single or no quotes; dr writes double, other tools
# (python-dotenv's set_key, for one) write single.
case $endpoint in
    \"*\") endpoint=${endpoint#\"} endpoint=${endpoint%\"} ;;
    \'*\') endpoint=${endpoint#\'} endpoint=${endpoint%\'} ;;
esac
if [ -z "$endpoint" ]; then
    echo "$env_file has no DATAROBOT_ENDPOINT. Run 'dr start' again." >&2
    exit 1
fi
# Every trailing slash goes, as in 30-otel.sh, so ".../api/v2//" still yields
# a real route.
while [ "$endpoint" != "${endpoint%/}" ]; do endpoint=${endpoint%/}; done
want="$endpoint/genai/llmgw"

# Every change is written in full to a file only its owner can read, next to
# .env so the swap is a rename, and removed however the script ends: it holds
# every secret .env does, and .env is never left half-written.
tmp=$(mktemp "$(dirname "$env_file")/.env.XXXXXX")
trap 'rm -f "$tmp"' EXIT
trap 'exit 130' INT TERM HUP

# Replace .env with $tmp whole, keeping .env's permissions. GNU stat first:
# BSD stat rejects -c, while GNU's -f is filesystem status, not an error.
replace_env() {
    mode=$(stat -c %a "$env_file" 2>/dev/null || stat -f %Lp "$env_file")
    chmod "$mode" "$tmp"
    mv -f "$tmp" "$env_file"
}

if ! grep -qE '^LLM_BASE_URL=' "$env_file"; then
    { cat "$env_file"; printf '\n%s\nLLM_BASE_URL="%s"\n' "$marker" "$want"; } > "$tmp"
    replace_env
    echo "Set LLM_BASE_URL to $want"
    exit 0
fi

status=0
awk -v marker="$marker" -v want="$want" '
    prev == marker && /^LLM_BASE_URL=/ {
        line = "LLM_BASE_URL=\"" want "\""
        if ($0 != line) moved = 1
        $0 = line
    }
    { print; prev = $0 }
    END { exit moved ? 10 : 0 }
' "$env_file" > "$tmp" || status=$?

case $status in
    0) ;;
    10)
        replace_env
        echo "LLM_BASE_URL now follows DATAROBOT_ENDPOINT: $want"
        # `dr run env` sets LLM_GATEWAY_SYNCING: it carries the change over next.
        [ -n "${LLM_GATEWAY_SYNCING:-}" ] ||
            echo "Run 'dr run env' to bring the change into .datarobot.yaml."
        ;;
    *) exit "$status" ;;
esac
