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
# Start the web UI and nginx restart loops and resolve the model and base URL through hermes config set.
# Sourced by entrypoint.sh into its shell, so it shares the variables, functions and traps.

cd "$HERMES_HOME"

# hermes-webui and nginx (docker/nginx.conf) run backgrounded, same pattern
# as the dr-sync push loop above -- the gateway below is what this script
# waits on, since ITS exit is what should end/restart the container. A crash in
# either background process costs the UI until the next boot, not the bot;
# each gets its own restart loop so a transient failure doesn't wedge it
# for the rest of the container's life.
#
# Explicit venv path (not relying on the `activate` above) because these
# are separate long-running processes, not sourced into this shell.
(
    while true; do
        /opt/hermes/.venv/bin/python3 /opt/hermes-webui/server.py \
            || echo "[entrypoint] Warning: hermes-webui exited; restarting in 2s" >&2
        sleep 2
    done
) &

# The handoff's stand-in held nginx's port until now (15-handoff.sh).
handoff_release_port
(
    while true; do
        nginx -c /opt/hermes-workload/nginx.conf \
            || echo "[entrypoint] Warning: nginx exited; restarting in 2s" >&2
        sleep 2
    done
) &

# Hermes' own ${VAR} substitution in config.yaml resolves correctly for a
# fresh `hermes config get` read, but NOT for the long-running gateway's
# conversation loop -- verified 2026-08-24: a live chat completion kept
# sending the literal string "${LLM_MODEL}" upstream, 404ing against the
# DataRobot LLM gateway, even though `hermes config get model` showed it
# fully resolved. custom_providers[].base_url isn't templated at all: it's
# a plain literal that never tracked LLM_BASE_URL to begin with.
# HERMES_MODEL -- Hermes' own documented process-level model override --
# doesn't reach this path either; the docs scope it to the cron scheduler
# only, and it was verified not to affect gateway chat completions.
# Resolve both through Hermes' own `config set` instead, so LLM_MODEL/
# LLM_BASE_URL still fully control this at every boot with zero commits to
# config.yaml -- just resolved by us instead of Hermes' broken templating.
# LLM_API_KEY is deliberately untouched here: its ${VAR} substitution and
# custom_providers[].key_env both provably work already.
hermes config set model.default "$LLM_MODEL" >&2
hermes config set custom_providers.0.base_url "$LLM_BASE_URL" >&2
