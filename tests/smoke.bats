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

# Behaviour of tests/smoke.sh against a stub `docker`: what it checks, and
# that each check fails when it should. The real image run is
# `task test:image`, in .github/workflows/image.yml.

setup() {
    WORK=$(mktemp -d)
    mkdir "$WORK/bin"
    # A healthy boot's log: the skills step reports what HERMES_HOME holds,
    # and OTel export is on, as on a deployed workload.
    printf '%s\n' '[entrypoint] skills in HERMES_HOME: 3' \
        '[entrypoint] hermes-otel export enabled: entity=workload-smoke endpoint=x' > "$WORK/container.log"
    export STUB_DIR="$WORK" STUB_LOG="$WORK/docker.calls"
    # STUB_HEALTH: the /health status of each probe in turn; the last repeats.
    # STUB_EXIT_AFTER: the container stops after this many `inspect` calls.
    cat > "$WORK/bin/docker" <<'EOF'
#!/bin/sh
echo "docker $*" >> "$STUB_LOG"
count() {
    n=$(($(cat "$STUB_DIR/$1" 2>/dev/null || echo 0) + 1))
    echo "$n" > "$STUB_DIR/$1"
}
case "$1" in
    build) exit "${STUB_BUILD_STATUS:-0}" ;;
    run)
        # What the container would get: `--env NAME` forwards NAME from this
        # environment, `--env NAME=value` sets it.
        : > "$STUB_DIR/run.env"
        while [ $# -gt 0 ]; do
            if [ "$1" = --env ]; then
                case "$2" in
                    *=*) printf '%s\n' "$2" ;;
                    *) ! printenv "$2" > /dev/null || printf '%s=%s\n' "$2" "$(printenv "$2")" ;;
                esac >> "$STUB_DIR/run.env"
                shift
            fi
            shift
        done
        exit "${STUB_RUN_STATUS:-0}" ;;
    inspect)
        count inspects
        if [ -n "${STUB_EXIT_AFTER:-}" ] && [ "$n" -gt "$STUB_EXIT_AFTER" ]; then
            echo false
        else
            echo true
        fi ;;
    exec)
        shift 2
        case "$1" in
            curl)
                count probes
                # shellcheck disable=SC2086
                set -- ${STUB_HEALTH:-200}
                [ "$n" -le $# ] || n=$#
                eval "printf '%s' \"\${$n}\"" ;;
            id) echo "${STUB_UID:-1000}" ;;
            touch)
                [ "${STUB_TOUCH_STATUS:-1}" -ne 0 ] || exit 0
                echo "touch: cannot touch '$2': ${STUB_TOUCH_ERROR:-Read-only file system}" >&2
                exit 1 ;;
        esac ;;
    logs) cat "$STUB_DIR/container.log" ;;
esac
exit 0
EOF
    chmod +x "$WORK/bin/docker"
}

teardown() {
    rm -rf "$WORK"
}

smoke() {
    run env PATH="$WORK/bin:$PATH" SMOKE_IMAGE="${SMOKE_IMAGE-labs-hermes:test}" \
        SMOKE_GRACE=0 SMOKE_POLL=0 sh /repo/tests/smoke.sh
}

@test "a container that answers /health passes, run as uid 1000 on a read-only root without a network" {
    STUB_HEALTH="000 000 200" smoke
    [ "$status" -eq 0 ]
    [[ "$output" == *"[smoke] ok"* ]]
    run grep '^docker run ' "$STUB_LOG"
    [[ "$output" == *" --read-only "* ]]
    [[ "$output" == *" --user 1000:1000 "* ]]
    [[ "$output" == *" --network none "* ]]
    [[ "$output" == *" --tmpfs /tmp:exec,mode=1777 "* ]]
    [[ "$output" == *" labs-hermes:test" ]]
    ! grep -q '^docker build ' "$STUB_LOG"
    grep -q '^docker rm --force ' "$STUB_LOG"
}

@test "without SMOKE_IMAGE it builds the image for linux/amd64 first" {
    SMOKE_IMAGE= smoke
    [ "$status" -eq 0 ]
    grep -q '^docker build --platform linux/amd64 --tag labs-hermes:smoke /repo$' "$STUB_LOG"
    grep -q '^docker run .* labs-hermes:smoke$' "$STUB_LOG"
}

@test "a failed build fails" {
    SMOKE_IMAGE= STUB_BUILD_STATUS=1 smoke
    [ "$status" -eq 1 ]
    [[ "$output" == *"FAIL: the image did not build"* ]]
    ! grep -q '^docker run ' "$STUB_LOG"
}

@test "every canary reaches the container through --env NAME, never on docker's command line" {
    smoke
    [ "$status" -eq 0 ]
    ! grep -q CANARY "$STUB_LOG"
    grep -qx 'SLACK_BOT_TOKEN=xoxb-CANARYSLACKBOT' "$WORK/run.env"
    grep -qx 'SLACK_APP_TOKEN=xapp-CANARYSLACKAPP' "$WORK/run.env"
    grep -qx 'DATAROBOT_API_TOKEN=CANARYDRTOKEN' "$WORK/run.env"
    grep -qx 'LLM_API_KEY=CANARYLLMKEY' "$WORK/run.env"
    grep -qx 'CANARYPEMBODYAAAA' "$WORK/run.env"
}

@test "the container gets a WORKLOAD_ID, and a boot without OTel export fails" {
    smoke
    [ "$status" -eq 0 ]
    grep -qx 'WORKLOAD_ID=smoke' "$WORK/run.env"
    [[ "$output" == *"OTel export enabled, as on a deployed workload"* ]]

    sed -i '/hermes-otel export enabled/d' "$WORK/container.log"
    echo '[entrypoint] hermes-otel export disabled: need an entity' >> "$WORK/container.log"
    smoke
    [ "$status" -eq 1 ]
    [[ "$output" == *"FAIL: OTel export was not enabled, as it is on a deployed workload"* ]]
}

@test "a canary token in the log fails" {
    echo 'slack: auth failed for xoxb-CANARYSLACKBOT' > "$WORK/container.log"
    smoke
    [ "$status" -eq 1 ]
    [[ "$output" == *"FAIL: the container log shows the value of a secret (canary CANARYSLACKBOT)"* ]]
}

@test "the private key's header in the log fails" {
    edge='-----'
    echo "${edge}BEGIN RSA PRIVATE KEY${edge}" > "$WORK/container.log"
    smoke
    [ "$status" -eq 1 ]
    [[ "$output" == *"FAIL: the container log shows the private key"* ]]
}

@test "a container that exits before /health answers fails" {
    STUB_HEALTH=000 STUB_EXIT_AFTER=2 smoke
    [ "$status" -eq 1 ]
    [[ "$output" == *"FAIL: the container exited before /health answered"* ]]
}

@test "/health that never answers 200 fails after SMOKE_TIMEOUT" {
    STUB_HEALTH=502 SMOKE_TIMEOUT=1 smoke
    [ "$status" -eq 1 ]
    [[ "$output" == *"FAIL: /health did not answer 200 within 1s (last status: 502)"* ]]
}

@test "a container that exits after becoming healthy fails" {
    STUB_EXIT_AFTER=1 smoke
    [ "$status" -eq 1 ]
    [[ "$output" == *"FAIL: the container exited within 0s of becoming healthy"* ]]
}

@test "/health that stops answering after the grace period fails" {
    STUB_HEALTH="200 503" smoke
    [ "$status" -eq 1 ]
    [[ "$output" == *"FAIL: /health answered 503 0s after becoming healthy"* ]]
}

@test "a container running as another uid fails" {
    STUB_UID=0 smoke
    [ "$status" -eq 1 ]
    [[ "$output" == *"FAIL: the container runs as uid 0, not 1000"* ]]
}

@test "a writable root filesystem fails" {
    STUB_TOUCH_STATUS=0 smoke
    [ "$status" -eq 1 ]
    [[ "$output" == *"FAIL: the root filesystem is writable"* ]]
}

@test "the write probe targets a path uid 1000 owns, so only a read-only root refuses it" {
    smoke
    [ "$status" -eq 0 ]
    grep -q '^docker exec [^ ]* touch /opt/hermes-seed/.smoke$' "$STUB_LOG"

    STUB_TOUCH_ERROR='Permission denied' smoke
    [ "$status" -eq 1 ]
    [[ "$output" == *"FAIL: could not probe the root filesystem: touch: cannot touch '/opt/hermes-seed/.smoke': Permission denied"* ]]
}

@test "a log without the skill count fails" {
    echo '[entrypoint] boot' > "$WORK/container.log"
    smoke
    [ "$status" -eq 1 ]
    [[ "$output" == *"FAIL: the entrypoint did not log a skill count"* ]]
}

@test "zero skills fails, and the count is reported" {
    sed -i 's/HERMES_HOME: 3/HERMES_HOME: 0/' "$WORK/container.log"
    smoke
    [ "$status" -eq 1 ]
    [[ "$output" == *"FAIL: HERMES_HOME holds no skills after boot"* ]]

    sed -i 's/HERMES_HOME: 0/HERMES_HOME: 42/' "$WORK/container.log"
    smoke
    [ "$status" -eq 0 ]
    [[ "$output" == *"42 skills in HERMES_HOME"* ]]
}

@test "a failure prints the container log and still removes the container" {
    echo 'gateway: boom' > "$WORK/container.log"
    STUB_UID=0 smoke
    [ "$status" -eq 1 ]
    [[ "$output" == *"gateway: boom"* ]]
    grep -q '^docker rm --force ' "$STUB_LOG"
}
