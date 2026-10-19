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

# How scripts/install-skill.sh runs the Hermes image. docker is a stub that
# records its arguments, one per line; the image itself isn't run here.

setup() {
    WORK=$(mktemp -d)
    mkdir -p "$WORK/project/config/skills" "$WORK/bin" "$WORK/data"
    # docker records its arguments; with RUN_INNER set it also runs the
    # container's script here, against $WORK/data instead of /opt/data.
    # `docker ps` lists one install container when STUB_RUNNING is set.
    cat > "$WORK/bin/docker" <<'STUB'
#!/bin/sh
if [ "$1" = ps ]; then
    [ -z "${STUB_RUNNING:-}" ] || echo 0123456789ab
    exit 0
fi
printf '%s\n' "$@" > "$DOCKER_ARGS"
[ -n "${RUN_INNER:-}" ] || exit 0
# Like docker, hand the container script the -e NAME=value variables.
while [ "$#" -gt 0 ] && [ "$1" != -c ]; do
    case "$1" in -e) export "$2"; shift ;; esac
    shift
done
shift
script=$1
shift
exec sh -c "$script" "$@"
STUB
    # chown to the image's hermes user can't happen here; ownership is not
    # what these tests check.
    printf '#!/bin/sh\nexit 0\n' > "$WORK/bin/chown"
    chmod +x "$WORK/bin/docker" "$WORK/bin/chown"
}

teardown() {
    rm -rf "$WORK"
}

install_skill() {
    cd "$WORK/project"
    PATH="$WORK/bin:$PATH" DOCKER_ARGS="$WORK/args" \
        run sh /repo/scripts/install-skill.sh registry.example.com/hermes@sha256:abc "$@"
}

@test "runs as root with the caller's ids, binding ./config by absolute path" {
    install_skill official/creative/ascii-art
    [ "$status" -eq 0 ]
    grep -qx -- '--user' "$WORK/args"
    grep -qx -- '0:0' "$WORK/args"
    grep -qx -- "HOST_UID=$(id -u)" "$WORK/args"
    grep -qx -- "HOST_GID=$(id -g)" "$WORK/args"
    grep -qx -- "$WORK/project/config:/host-config" "$WORK/args"
    grep -qx -- 'registry.example.com/hermes@sha256:abc' "$WORK/args"
    grep -A1 -x -- '--label' "$WORK/args" | grep -qx 'labs-hermes.install-skill'
}

@test "the skill is passed as an argument, never spliced into the container's script" {
    install_skill 'x"; touch /tmp/pwned; echo "'
    [ "$status" -eq 0 ]
    # The last argument is the skill, verbatim, after the script's $0.
    [ "$(tail -n 1 "$WORK/args")" = 'x"; touch /tmp/pwned; echo "' ]
    [ "$(tail -n 2 "$WORK/args" | head -n 1)" = sh ]
    run grep -c 'touch /tmp/pwned' "$WORK/args"
    [ "$output" = 1 ]
}

@test "refuses to run outside the project root" {
    rmdir "$WORK/project/config/skills"
    install_skill official/creative/ascii-art
    [ "$status" -ne 0 ]
    [ ! -e "$WORK/args" ]
}

# An upgrade, as hermes would do it: drops old.py from the skill and adds
# new.py. With HERMES_FAIL set, it fails instead.
fake_hermes() {
    cat > "$WORK/bin/hermes" <<'STUB'
#!/bin/sh
printf '%s\n' "$@" > "$HERMES_ARGS"
[ -z "${HERMES_FAIL:-}" ] || exit 1
rm -f "$HERMES_DATA_DIR/skills/cat/demo/old.py"
echo new > "$HERMES_DATA_DIR/skills/cat/demo/new.py"
STUB
    chmod +x "$WORK/bin/hermes"
    mkdir -p "$WORK/project/config/skills/cat/demo" "$WORK/project/config/skills/other"
    echo old > "$WORK/project/config/skills/cat/demo/old.py"
    echo keep > "$WORK/project/config/skills/other/SKILL.md"
}

run_inner() {
    cd "$WORK/project"
    PATH="$WORK/bin:$PATH" DOCKER_ARGS="$WORK/args" HERMES_ARGS="$WORK/hermes-args" RUN_INNER=1 \
        HOST_CONFIG_DIR="$WORK/project/config" HERMES_DATA_DIR="$WORK/data" \
        HOST_UID="$(id -u)" HOST_GID="$(id -g)" \
        run sh /repo/scripts/install-skill.sh registry.example.com/hermes@sha256:abc cat/demo
}

@test "an upgrade that drops a file drops it from config/skills too" {
    fake_hermes
    run_inner
    [ "$status" -eq 0 ]
    [ ! -e "$WORK/project/config/skills/cat/demo/old.py" ]
    [ "$(cat "$WORK/project/config/skills/cat/demo/new.py")" = new ]
    [ "$(cat "$WORK/project/config/skills/other/SKILL.md")" = keep ]
    [ -z "$(find "$WORK/project/config" -maxdepth 1 -name '.skills.*')" ]
}

@test "skills already in the image's data dir don't end up in config/skills" {
    fake_hermes
    mkdir -p "$WORK/data/skills/bundled-by-image"
    echo bundled > "$WORK/data/skills/bundled-by-image/SKILL.md"
    run_inner
    [ "$status" -eq 0 ]
    [ ! -e "$WORK/project/config/skills/bundled-by-image" ]
}

@test "a failed install leaves config/skills exactly as it was" {
    fake_hermes
    cp -a "$WORK/project/config/skills" "$WORK/before"
    HERMES_FAIL=1 run_inner
    [ "$status" -ne 0 ]
    diff -r "$WORK/before" "$WORK/project/config/skills"
    [ -z "$(find "$WORK/project/config" -maxdepth 1 -name '.skills.*')" ]
}

@test "a second install refuses to start and leaves the first one's staging alone" {
    fake_hermes
    mkdir "$WORK/project/config/.skills.lock" "$WORK/project/config/.skills.old"
    echo backup > "$WORK/project/config/.skills.old/marker"
    cp -a "$WORK/project/config/skills" "$WORK/before"
    STUB_RUNNING=1 run_inner
    [ "$status" -eq 75 ]
    [[ "$output" == *"Another skill install is running"* ]]
    diff -r "$WORK/before" "$WORK/project/config/skills"
    # The other run's backup and lock are left alone.
    [ "$(cat "$WORK/project/config/.skills.old/marker")" = backup ]
    [ -d "$WORK/project/config/.skills.lock" ]
}

@test "the lock is released after an install, whether it worked or not" {
    fake_hermes
    run_inner
    [ "$status" -eq 0 ]
    [ ! -e "$WORK/project/config/.skills.lock" ]
    HERMES_FAIL=1 run_inner
    [ "$status" -ne 0 ]
    [ ! -e "$WORK/project/config/.skills.lock" ]
}

@test "after a run killed between its renames, the next one restores config/skills and goes on" {
    fake_hermes
    # What the kill leaves: the previous tree in .skills.old, no skills, the lock.
    mv "$WORK/project/config/skills" "$WORK/project/config/.skills.old"
    mkdir "$WORK/project/config/.skills.lock"
    run_inner
    [ "$status" -eq 0 ]
    [[ "$output" == *"Restored config/skills from an interrupted install."* ]]
    [ "$(cat "$WORK/project/config/skills/other/SKILL.md")" = keep ]
    [ "$(cat "$WORK/project/config/skills/cat/demo/new.py")" = new ]
    [ -z "$(find "$WORK/project/config" -maxdepth 1 -name '.skills.*')" ]
}

@test "with .skills.old next to config/skills and nothing running, it stops and touches neither" {
    fake_hermes
    mkdir "$WORK/project/config/.skills.old"
    echo backup > "$WORK/project/config/.skills.old/marker"
    cp -a "$WORK/project/config/skills" "$WORK/before"
    run_inner
    [ "$status" -eq 1 ]
    [[ "$output" == *"left from an interrupted install, next to config/skills"* ]]
    diff -r "$WORK/before" "$WORK/project/config/skills"
    [ "$(cat "$WORK/project/config/.skills.old/marker")" = backup ]
}

@test "only what Hermes needs is staged: host binaries, runtime state and credentials stay out" {
    fake_hermes
    c="$WORK/project/config"
    echo cfg > "$c/config.yaml"
    mkdir -p "$c/bin" "$c/.local/share" "$c/.cua-driver" "$c/lazy-packages" "$c/sessions" "$c/logs" "$c/cache" \
        "$c/skills/other/bin" "$c/skills/other/sessions"
    touch "$c/bin/uv" "$c/.local/share/x" "$c/.cua-driver/d" "$c/lazy-packages/p" "$c/sessions/s" "$c/logs/l" \
        "$c/cache/c" "$c/.env" "$c/auth.json" "$c/state.db" "$c/state.db-wal" "$c/config.yaml.bak.1" \
        "$c/skills/other/bin/tool" "$c/skills/other/sessions/notes"
    run_inner
    [ "$status" -eq 0 ]
    d="$WORK/data"
    [ "$(cat "$d/config.yaml")" = cfg ]
    [ -f "$d/skills/other/bin/tool" ]
    [ -f "$d/skills/other/sessions/notes" ]
    for gone in bin .local .cua-driver lazy-packages sessions logs cache .env auth.json state.db state.db-wal \
        config.yaml.bak.1 .skills.lock; do
        [ ! -e "$d/$gone" ] || { echo "staged: $gone"; return 1; }
    done
    # The skill a skill ships keeps its own bin folder in config/skills too.
    [ -f "$c/skills/other/bin/tool" ]
}

@test "without a terminal, the install is confirmed with --yes, never forced" {
    fake_hermes
    run_inner < /dev/null
    [ "$status" -eq 0 ]
    grep -qx -- 'INSTALL_YES=1' "$WORK/args"
    [ "$(cat "$WORK/hermes-args")" = "$(printf 'skills\ninstall\n--yes\ncat/demo')" ]
    ! grep -qx -- '--force' "$WORK/hermes-args" || false
}
