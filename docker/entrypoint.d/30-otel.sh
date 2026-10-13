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
# Derive the OTel entity and endpoint, and render hermes_otel.yaml from its template when export can work.
# Sourced by entrypoint.sh into its shell, so it shares the variables, functions and traps.

# hermes-otel (baked into the seed by the Dockerfile) reads its OTLP backend
# config from $HERMES_HOME/hermes_otel.yaml. That file's DataRobot headers
# carry DATAROBOT_API_TOKEN, a secret, so only a template ships in the seed
# -- rendered into the real file here, once the token exists as a real env
# var, the same reasoning as LLM_API_KEY never landing in a file on disk.
# A workload's traces live under its own "workload-<id>" entity -- the same
# service.name the platform's gateway spans use -- so default the OTel entity
# to this workload when one wasn't set explicitly (e.g. to a Use Case). The
# platform injects WORKLOAD_ID at runtime, so this needs no manual wiring.
if [ -z "${DATAROBOT_ENTITY_ID:-}" ] && [ -n "${WORKLOAD_ID:-}" ]; then
    DATAROBOT_ENTITY_ID="workload-${WORKLOAD_ID}"
fi

# Derive the OTel endpoint from the API endpoint so export follows whichever
# install this runs on (app, staging, on-prem) instead of a pinned host --
# the same derivation DataRobot's own dr_otel_config does: trim trailing
# slashes, strip the /api/v2 suffix, then add /otel. The trailing-slash trim
# matters: without it a "https://host/api/v2/" endpoint would not match the
# /api/v2 suffix and would yield "/api/v2//otel".
if [ -z "${DATAROBOT_OTEL_ENDPOINT:-}" ] && [ -n "${DATAROBOT_ENDPOINT:-}" ]; then
    _dr_base="$DATAROBOT_ENDPOINT"
    while [ "$_dr_base" != "${_dr_base%/}" ]; do _dr_base="${_dr_base%/}"; done
    DATAROBOT_OTEL_ENDPOINT="${_dr_base%/api/v2}/otel"
    unset _dr_base
fi

# Enable export only when everything a successful upload needs is present: an
# entity to attribute traces to, the API token the auth header carries, and an
# endpoint. Export is on by default now (the entity derives from WORKLOAD_ID),
# so guarding on the token matters -- without it every trace, metric and log
# POST would 401 and flood the logs for every workload, not just one that had
# opted in. DATAROBOT_API_TOKEN is platform-injected; see the Secrets section.
if [ -n "${DATAROBOT_ENTITY_ID:-}" ] \
    && [ -n "${DATAROBOT_API_TOKEN:-}" ] \
    && [ -n "${DATAROBOT_OTEL_ENDPOINT:-}" ] \
    && [ -f "$HERMES_HOME/hermes_otel.yaml.tmpl" ]; then
    export DATAROBOT_ENTITY_ID DATAROBOT_OTEL_ENDPOINT
    # envsubst needs the literal variable names, so the single quotes are intended.
    # shellcheck disable=SC2016
    envsubst '${DATAROBOT_OTEL_ENDPOINT} ${DATAROBOT_ENTITY_ID} ${DATAROBOT_API_TOKEN}' \
        < "$HERMES_HOME/hermes_otel.yaml.tmpl" > "$HERMES_HOME/hermes_otel.yaml"
    echo "[entrypoint] hermes-otel export enabled: entity=${DATAROBOT_ENTITY_ID} endpoint=${DATAROBOT_OTEL_ENDPOINT}" >&2
else
    echo "[entrypoint] hermes-otel export disabled: need an entity (DATAROBOT_ENTITY_ID or WORKLOAD_ID), DATAROBOT_API_TOKEN, and an OTel endpoint (DATAROBOT_OTEL_ENDPOINT or DATAROBOT_ENDPOINT)" >&2
fi
