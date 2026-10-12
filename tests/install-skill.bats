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
    cat > "$WORK/bin/docker" <<'STUB'
#!/bin/sh
printf '%s\n' "$@" > "$DOCKER_ARGS"
[ -n "${RUN_INNER:-}" ] || exit 0
while [ "$#" -gt 0 ] && [ "$1" != -c ]; do shift; done
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
    PATH="$WORK/bin:$PATH" DOCKER_ARGS="$WORK/args" RUN_INNER=1 \
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
