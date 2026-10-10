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
# Log the environment variable names, copy the baked seed into HERMES_HOME and create the directories Hermes and the toolchain expect.
# Sourced by entrypoint.sh into its shell, so it shares the variables, functions and traps.

# Names only, never values -- several of these are secrets (LLM_API_KEY,
# SLACK_*_TOKEN, DATAROBOT_API_TOKEN). This is what confirms whether a given
# environmentVars entry actually mounted anything, e.g. whether
# `source: api-key` in .datarobot.yaml produces a DATAROBOT_API_TOKEN.
# NUL-delimited so a multi-line value (the GITHUB_PRIVATE_KEY PEM) stays one
# record and only its name is printed.
echo "[entrypoint] environment variable names: $(env -0 | cut -z -d= -f1 | sort -z | tr '\0' ' ')" >&2

mkdir -p "$HERMES_HOME"

# Diagnostic for the "cp: Permission denied" crash loop seen 2026-08-21/22:
# every seed file fails to copy into $HERMES_HOME, which worked fine on the
# 2026-08-21 morning boot. Print who we are, the mode of every directory in
# play, AND whether $HERMES_HOME is already non-empty at this point -- a
# CrashLoopBackOff restarts the same pod, and if /tmp survives that restart,
# leftovers from an earlier attempt (not a fresh empty dir) would be the
# actual difference from the working boot.
echo "[entrypoint] id: $(id)" >&2
ls -ld /tmp "$HERMES_HOME" "$HERMES_SEED" >&2 2>&1 || true
echo "[entrypoint] contents of \$HERMES_HOME before the seed copy:" >&2
ls -la "$HERMES_HOME" >&2 2>&1 || true

# The baked seed: config.yaml, SOUL.md, skills/. Read-only in the image, so
# copy rather than symlink -- Hermes rewrites config.yaml in place.
cp -R "$HERMES_SEED/." "$HERMES_HOME/"

# Directories Hermes expects to exist, mirroring stage2-hook.sh's list.
for d in backups cron sessions logs logs/gateways hooks memories skills skins \
         plans workspace home pairing platforms/pairing lazy-packages webui; do
    mkdir -p "$HERMES_HOME/$d"
done

# nginx's pid file and temp dirs (see docker/nginx.conf) -- /tmp starts
# empty on every boot, same reasoning as the loop above.
mkdir -p /tmp/nginx

# Cache/config/state dirs for the bundled toolchain (go, npm, gh, glab, helm,
# kubectl, pulumi, uv). The Dockerfile points every relevant env var at
# $TOOLS_HOME; the dirs themselves have to be made here because /tmp starts
# empty on every boot. Without this, the first `go build` or `gh auth` fails
# on a missing parent rather than on anything meaningful.
mkdir -p "$TOOLS_HOME/go/bin" \
         "$TOOLS_HOME/cache" \
         "$TOOLS_HOME/config/gh" "$TOOLS_HOME/config/glab" \
         "$TOOLS_HOME/config/kube" "$TOOLS_HOME/config/helm" \
         "$TOOLS_HOME/data" "$TOOLS_HOME/state" "$TOOLS_HOME/pulumi"
