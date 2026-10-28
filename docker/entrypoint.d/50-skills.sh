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
# Activate the Hermes virtualenv and sync the bundled skills into HERMES_HOME.
# Sourced by entrypoint.sh into its shell, so it shares the variables, functions and traps.

# shellcheck disable=SC1091
. /opt/hermes/.venv/bin/activate

# Bundled skills ship in the install tree and are synced into HERMES_HOME. The
# seed carries only the Labs skills, so everything else depends on this sync.
# Best-effort: a failure here costs skills, not the bot, so it is logged and the
# boot goes on. Hermes reads HERMES_BUNDLED_SKILLS first, so the check does too.
# Run again after a rollout's reload (entrypoint.sh), over the state it brought.
bundled_skills="${HERMES_BUNDLED_SKILLS:-/opt/hermes/skills}"
sync_bundled_skills() {
    if [ -d "$bundled_skills" ]; then
        python /opt/hermes/tools/skills_sync.py \
            || echo "[entrypoint] Warning: skills_sync.py failed; continuing" >&2
    else
        echo "[entrypoint] Warning: bundled skills directory $bundled_skills not found; skipping the skills sync" >&2
    fi
    echo "[entrypoint] skills in HERMES_HOME: $(find "$HERMES_HOME/skills" -name SKILL.md | wc -l)" >&2
}
sync_bundled_skills
