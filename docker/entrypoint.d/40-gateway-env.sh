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

# shellcheck shell=sh
# Set the API server key and the LLM credentials the gateway reads, and self-test the LLM gateway.
# Sourced by entrypoint.sh into its shell, so it shares the variables, functions and traps.

# The gateway's api_server refuses to start without a usable API_SERVER_KEY,
# and that server is what answers the platform's /health probe. The key is
# a real credential:
# generate a fresh one per boot rather than persisting or injecting it.
# Nothing outside the container needs it -- the probe path is unauthenticated.
if [ -z "${API_SERVER_KEY:-}" ]; then
    API_SERVER_KEY=$(od -An -tx1 -N32 /dev/urandom | tr -d ' \n')
    export API_SERVER_KEY
fi

# Default LLM_API_KEY to the platform-injected DATAROBOT_API_TOKEN (`source:
# api-key` in .datarobot.yaml) rather than requiring a separately managed
# dr-credential: LLM_BASE_URL's default is the DataRobot LLM gateway itself,
# which accepts a normal DataRobot API token, and this one is rotated by the
# platform instead of going stale in a credential nobody remembers to renew.
#
# Only for a gateway on the DataRobot install's own origin, though: the token
# is a DataRobot credential, and an LLM_BASE_URL anywhere else would receive
# it as a bearer token on every call. Another gateway needs its own key.
if [ -z "${LLM_API_KEY:-}" ]; then
    dr_origin=$(printf '%s' "${DATAROBOT_ENDPOINT:-}" | sed -nE 's#^(https?://[^/?#]+).*#\1#p' | tr '[:upper:]' '[:lower:]')
    llm_origin=$(printf '%s' "${LLM_BASE_URL:-}" | sed -nE 's#^(https?://[^/?#]+).*#\1#p' | tr '[:upper:]' '[:lower:]')
    if [ -n "$dr_origin" ] && [ "$dr_origin" = "$llm_origin" ]; then
        LLM_API_KEY=${DATAROBOT_API_TOKEN:-}
    elif [ -n "${LLM_BASE_URL:-}" ]; then
        echo "[entrypoint] LLM_BASE_URL is not on DATAROBOT_ENDPOINT's host, so DATAROBOT_API_TOKEN is not sent to it; set LLM_API_KEY for that gateway" >&2
    fi
fi
export LLM_API_KEY="${LLM_API_KEY:-}"

# Some Hermes provider names (e.g. "NVIDIA") are also recognized as
# built-in providers with their own credential lookup by convention --
# <PROVIDER>_API_KEY -- independent of custom_providers[].key_env. Verified
# 2026-08-24: setting LLM_PROVIDER=NVIDIA made Hermes look for
# NVIDIA_API_KEY specifically and ignore our custom_providers entry
# entirely. Alias it dynamically, keyed off whatever LLM_PROVIDER actually
# is, so either lookup path finds the same credential.
if [ -n "${LLM_PROVIDER:-}" ] && [ -n "${LLM_API_KEY:-}" ]; then
    provider_key_var=$(printf '%s' "$LLM_PROVIDER" | tr '[:lower:]' '[:upper:]' | tr -c 'A-Z0-9' '_')_API_KEY
    eval "export ${provider_key_var}=\"\$LLM_API_KEY\""
fi

# Diagnostic for the 401s seen 2026-08-24: README.md flags `source: api-key`
# as unverified -- confirm DATAROBOT_API_TOKEN is actually non-empty here,
# and that it's actually accepted by the gateway LLM_BASE_URL points at.
# Length and HTTP status only, never the token value.
echo "[entrypoint] DATAROBOT_API_TOKEN length: ${#DATAROBOT_API_TOKEN}; LLM_API_KEY length: ${#LLM_API_KEY}" >&2
if [ -n "${LLM_API_KEY:-}" ] && [ -n "${LLM_BASE_URL:-}" ]; then
    llm_selftest_status=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 \
        -X POST "${LLM_BASE_URL}/chat/completions" \
        -H "Authorization: Bearer ${LLM_API_KEY}" \
        -H "Content-Type: application/json" \
        -d "{\"model\":\"${LLM_MODEL:-anthropic/claude-opus-4-8}\",\"messages\":[{\"role\":\"user\",\"content\":\"ping\"}],\"max_tokens\":1}" \
        2>/dev/null || echo "curl_failed")
    echo "[entrypoint] LLM gateway self-test: HTTP $llm_selftest_status" >&2
fi
