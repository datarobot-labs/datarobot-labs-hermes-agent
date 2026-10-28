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

# Behaviour of docker/entrypoint.sh, run for real against the repo's own seed
# files. Hermes, dr-sync, curl and nginx are stubs (tests/fixtures/opt/stubs)
# that record their calls. The container runs as uid 1000 on a read-only root
# with only /tmp writable, the same constraints as the workload.

# Built from fragments so secret scanners do not flag the canary as a real key.
PEM_EDGE='-----'
PEM_KIND='RSA PRIVATE'
PEM="${PEM_EDGE}BEGIN ${PEM_KIND} KEY${PEM_EDGE}"$'\nCANARYPEMBODYAAAA\nCANARYPEMBODYBBBB=\n'"${PEM_EDGE}END ${PEM_KIND} KEY${PEM_EDGE}"

setup() {
    WORK=$(mktemp -d)
    SEED="$WORK/seed"
    mkdir -p "$SEED" "$WORK/tools"
    cp /repo/config/config.yaml /repo/config/SOUL.md /repo/config/hermes_otel.yaml.tmpl \
        /repo/config/.drsyncignore "$SEED/"
    : > "$WORK/calls.log"
    rm -rf /tmp/hermes /tmp/nginx
}

teardown() {
    pkill -f 'docker/entrypoint.sh' || true
    pkill -x sleep || true
    rm -rf "$WORK"
}

# boot VAR=value...: run the real entrypoint with exactly this environment.
# stdout and stderr go to $WORK/out and $WORK/err.
boot() {
    env -i PATH=/opt/stubs:/usr/local/bin:/usr/bin:/bin HOME=/tmp \
        HERMES_SEED="$SEED" TOOLS_HOME="$WORK/tools" \
        STUB_LOG="$WORK/calls.log" STUB_ENV="$WORK/gateway.env" \
        "$@" sh /repo/docker/entrypoint.sh > "$WORK/out" 2> "$WORK/err" < /dev/null
}

assert_absent() {
    if grep -q -- "$1" "$2"; then
        echo "found '$1' in $2"
        return 1
    fi
}

@test "the container runs as uid 1000 on a read-only root" {
    [ "$(id -u)" = 1000 ]
    run touch /opt/stubs/probe
    [ "$status" -ne 0 ]
}

@test "logs variable names and never a secret value" {
    run boot GITHUB_PRIVATE_KEY="$PEM" SLACK_BOT_TOKEN=CANARYSLACKBOT SLACK_APP_TOKEN=CANARYSLACKAPP \
        DATAROBOT_API_TOKEN=CANARYDRTOKEN LLM_API_KEY=CANARYLLMKEY API_SERVER_KEY=CANARYSERVERKEY \
        LLM_BASE_URL=https://llm.test
    [ "$status" -eq 0 ]
    grep -q 'environment variable names:.*GITHUB_PRIVATE_KEY' "$WORK/err"
    grep -q 'environment variable names:.*SLACK_BOT_TOKEN' "$WORK/err"
    for canary in CANARYPEMBODY BEGIN.RSA CANARYSLACKBOT CANARYSLACKAPP CANARYDRTOKEN CANARYLLMKEY CANARYSERVERKEY; do
        assert_absent "$canary" "$WORK/err"
        assert_absent "$canary" "$WORK/out"
    done
}

@test "lists a variable that has an empty value by name" {
    run boot EMPTY_VAR=
    [ "$status" -eq 0 ]
    grep -q 'environment variable names:.*EMPTY_VAR' "$WORK/err"
}

@test "refuses to start without HERMES_SEED" {
    run boot HERMES_SEED=
    [ "$status" -ne 0 ]
    grep -q 'HERMES_SEED must be set' "$WORK/err"
}

@test "refuses to start without TOOLS_HOME" {
    run boot TOOLS_HOME=
    [ "$status" -ne 0 ]
    grep -q 'TOOLS_HOME must be set' "$WORK/err"
}

@test "copies the seed into HERMES_HOME and creates the directories Hermes expects" {
    run boot
    [ "$status" -eq 0 ]
    [ -f /tmp/hermes/config.yaml ]
    [ -f /tmp/hermes/SOUL.md ]
    for d in sessions memories skills logs/gateways platforms/pairing webui; do
        [ -d "/tmp/hermes/$d" ]
    done
    [ -d "$WORK/tools/go/bin" ]
}

@test "starts the gateway last, without a supervisor" {
    run boot
    [ "$status" -eq 0 ]
    [ "$(tail -n 1 "$WORK/calls.log")" = "hermes gateway run --no-supervise" ]
}

@test "syncs the bundled skills before the gateway starts and logs the skill count" {
    mkdir -p "$WORK/bundled" "$SEED/skills/one" "$SEED/skills/two"
    touch "$SEED/skills/one/SKILL.md" "$SEED/skills/two/SKILL.md"
    run boot HERMES_BUNDLED_SKILLS="$WORK/bundled"
    [ "$status" -eq 0 ]
    sync_line=$(grep -n '^python /opt/hermes/tools/skills_sync.py$' "$WORK/calls.log" | cut -d: -f1)
    gateway_line=$(grep -n '^hermes gateway run' "$WORK/calls.log" | cut -d: -f1)
    [ "$sync_line" -lt "$gateway_line" ]
    grep -q 'skills in HERMES_HOME: 2$' "$WORK/err"
}

@test "a failing skills sync is logged and the boot goes on" {
    mkdir -p "$WORK/bundled"
    run boot HERMES_BUNDLED_SKILLS="$WORK/bundled" STUB_PYTHON_FAIL=1
    [ "$status" -eq 0 ]
    grep -q 'Warning: skills_sync.py failed; continuing' "$WORK/err"
    grep -q '^hermes gateway run' "$WORK/calls.log"
}

@test "a missing bundled skills directory is logged and the boot goes on without a sync" {
    run boot HERMES_BUNDLED_SKILLS="$WORK/missing"
    [ "$status" -eq 0 ]
    grep -q "Warning: bundled skills directory $WORK/missing not found; skipping the skills sync" "$WORK/err"
    assert_absent '^python' "$WORK/calls.log"
    grep -q '^hermes gateway run' "$WORK/calls.log"
}

@test "skips dr-sync with a notice when DR_SYNC_CATALOG_ID is unset" {
    run boot
    [ "$status" -eq 0 ]
    grep -q 'DR_SYNC_CATALOG_ID not set' "$WORK/err"
    assert_absent 'dr-sync' "$WORK/calls.log"
}

@test "downloads state before the gateway and uploads it once after the gateway exits" {
    run boot DR_SYNC_CATALOG_ID=catalog123
    [ "$status" -eq 0 ]
    [ "$(grep -c '^dr-sync download /tmp/dr-sync-stage$' "$WORK/calls.log")" = 1 ]
    [ "$(grep -c '^dr-sync upload /tmp/hermes ' "$WORK/calls.log")" = 1 ]
    grep -q -- '^dr-sync upload .*--exclude \*\.db --exclude \*\.db-wal --exclude \*\.db-shm' "$WORK/calls.log"
    download_line=$(grep -n '^dr-sync download' "$WORK/calls.log" | cut -d: -f1)
    gateway_line=$(grep -n '^hermes gateway run' "$WORK/calls.log" | cut -d: -f1)
    upload_line=$(grep -n '^dr-sync upload' "$WORK/calls.log" | cut -d: -f1)
    [ "$download_line" -lt "$gateway_line" ]
    [ "$gateway_line" -lt "$upload_line" ]
    grep -q 'running final dr-sync upload' "$WORK/err"
}

@test "skills and plugins come back from the store, with the image's own laid over them" {
    mkdir -p "$SEED/skills/shipped" "$SEED/plugins/otel" "$WORK/bin" \
        "$WORK/stored/skills/shipped" "$WORK/stored/skills/learned" "$WORK/stored/plugins/otel"
    echo image > "$SEED/skills/shipped/SKILL.md"
    echo image > "$SEED/plugins/otel/plugin.yaml"
    echo stale > "$WORK/stored/skills/shipped/SKILL.md"
    echo stale > "$WORK/stored/plugins/otel/plugin.yaml"
    echo agent > "$WORK/stored/skills/learned/SKILL.md"
    # A dr-sync whose download brings back what $WORK/stored holds.
    cat > "$WORK/bin/dr-sync" <<STUB
#!/bin/sh
echo "dr-sync \$*" >> "\$STUB_LOG"
if [ "\$1" = download ]; then cp -R "$WORK/stored/." "\$2/"; fi
exit 0
STUB
    chmod +x "$WORK/bin/dr-sync"
    run boot PATH="$WORK/bin:/opt/stubs:/usr/local/bin:/usr/bin:/bin" DR_SYNC_CATALOG_ID=catalog123
    [ "$status" -eq 0 ]
    grep -q '^dr-sync download /tmp/dr-sync-stage$' "$WORK/calls.log"
    [ "$(cat /tmp/hermes/skills/shipped/SKILL.md)" = image ]
    [ "$(cat /tmp/hermes/plugins/otel/plugin.yaml)" = image ]
    [ "$(cat /tmp/hermes/skills/learned/SKILL.md)" = agent ]
    # What this image shipped, for the next boot to compare with.
    grep -qx 'skills/shipped/SKILL.md' /tmp/hermes/.dr-sync-shipped
    grep -qx 'plugins/otel/plugin.yaml' /tmp/hermes/.dr-sync-shipped
}

@test "after an image bump, a skill the new image no longer ships is removed, and nothing outside skills/ is" {
    mkdir -p "$SEED/skills/kept" "$WORK/bin" "$WORK/stored/skills/kept" "$WORK/stored/skills/dropped/sub" \
        "$WORK/stored/skills/learned" "$WORK/stored/sessions"
    echo new > "$SEED/skills/kept/SKILL.md"
    echo old > "$WORK/stored/skills/kept/SKILL.md"
    echo old > "$WORK/stored/skills/dropped/SKILL.md"
    echo old > "$WORK/stored/skills/dropped/sub/notes.md"
    echo agent > "$WORK/stored/skills/learned/SKILL.md"
    echo chat > "$WORK/stored/sessions/chat.json"
    # The list the earlier image wrote, plus entries that must never be acted on.
    printf '%s\n' skills/dropped/SKILL.md skills/dropped/sub/notes.md skills/kept/SKILL.md \
        sessions/chat.json skills/../sessions/chat.json > "$WORK/stored/.dr-sync-shipped"
    cat > "$WORK/bin/dr-sync" <<STUB
#!/bin/sh
echo "dr-sync \$*" >> "\$STUB_LOG"
if [ "\$1" = download ]; then cp -R "$WORK/stored/." "\$2/"; fi
exit 0
STUB
    chmod +x "$WORK/bin/dr-sync"
    run boot PATH="$WORK/bin:/opt/stubs:/usr/local/bin:/usr/bin:/bin" DR_SYNC_CATALOG_ID=catalog123
    [ "$status" -eq 0 ]
    [ ! -e /tmp/hermes/skills/dropped ]
    [ "$(cat /tmp/hermes/skills/kept/SKILL.md)" = new ]
    [ "$(cat /tmp/hermes/skills/learned/SKILL.md)" = agent ]
    [ "$(cat /tmp/hermes/sessions/chat.json)" = chat ]
    # The dropped skill stays listed: the store keeps its file, and the next
    # download brings it back.
    grep -qx 'skills/dropped/SKILL.md' /tmp/hermes/.dr-sync-shipped
    grep -qx 'skills/kept/SKILL.md' /tmp/hermes/.dr-sync-shipped
    ! grep -qx 'skills/learned/SKILL.md' /tmp/hermes/.dr-sync-shipped || false
}

@test "a skill dropped two images ago, still in the store, is removed again" {
    mkdir -p "$SEED/skills/kept" "$WORK/bin" "$WORK/stored/skills/dropped"
    echo new > "$SEED/skills/kept/SKILL.md"
    echo old > "$WORK/stored/skills/dropped/SKILL.md"
    # The previous image already didn't ship it; the list still has it.
    printf '%s\n' skills/dropped/SKILL.md skills/kept/SKILL.md > "$WORK/stored/.dr-sync-shipped"
    cat > "$WORK/bin/dr-sync" <<STUB
#!/bin/sh
echo "dr-sync \$*" >> "\$STUB_LOG"
if [ "\$1" = download ]; then cp -R "$WORK/stored/." "\$2/"; fi
exit 0
STUB
    chmod +x "$WORK/bin/dr-sync"
    run boot PATH="$WORK/bin:/opt/stubs:/usr/local/bin:/usr/bin:/bin" DR_SYNC_CATALOG_ID=catalog123
    [ "$status" -eq 0 ]
    [ ! -e /tmp/hermes/skills/dropped ]
    grep -qx 'skills/dropped/SKILL.md' /tmp/hermes/.dr-sync-shipped
}

@test "a stored path of another type than the image's stays out, and the boot goes on" {
    mkdir -p "$SEED/skills/now-a-dir" "$SEED/skills/linked" "$WORK/bin" "$WORK/stored/skills/now-a-file" \
        "$WORK/stored/skills/learned" "$WORK/stored/sessions" "$WORK/elsewhere"
    echo image > "$SEED/skills/now-a-dir/SKILL.md"
    echo image > "$SEED/skills/now-a-file"
    echo image > "$SEED/skills/linked/SKILL.md"
    echo stored > "$WORK/stored/skills/now-a-dir"
    echo stored > "$WORK/stored/skills/now-a-file/SKILL.md"
    ln -s "$WORK/elsewhere" "$WORK/stored/skills/linked"
    echo agent > "$WORK/stored/skills/learned/SKILL.md"
    echo chat > "$WORK/stored/sessions/chat.json"
    # Like the real dr-sync, this download fails when it would write a path
    # over one of another type.
    cat > "$WORK/bin/dr-sync" <<STUB
#!/bin/sh
echo "dr-sync \$*" >> "\$STUB_LOG"
if [ "\$1" = download ]; then cp -R "$WORK/stored/." "\$2/" || exit 1; fi
exit 0
STUB
    chmod +x "$WORK/bin/dr-sync"
    run boot PATH="$WORK/bin:/opt/stubs:/usr/local/bin:/usr/bin:/bin" DR_SYNC_CATALOG_ID=catalog123 DR_SYNC_DOWNLOAD_ATTEMPTS=1
    [ "$status" -eq 0 ]
    [ "$(cat /tmp/hermes/skills/now-a-dir/SKILL.md)" = image ]
    [ "$(cat /tmp/hermes/skills/now-a-file)" = image ]
    [ ! -L /tmp/hermes/skills/linked ]
    [ "$(cat /tmp/hermes/skills/linked/SKILL.md)" = image ]
    [ "$(cat /tmp/hermes/skills/learned/SKILL.md)" = agent ]
    [ "$(cat /tmp/hermes/sessions/chat.json)" = chat ]
    grep -q 'the store has a file at skills/now-a-dir, where the image has a directory' "$WORK/err"
    grep -q 'the store has a directory at skills/now-a-file, where the image has a file' "$WORK/err"
    [ ! -e /tmp/dr-sync-stage ]
}

@test "a stored symlink at the image's path stays out: no write through it, no failed merge" {
    mkdir -p "$SEED/skills/.hub" "$SEED/skills/a-dir" "$WORK/bin" "$WORK/stored/skills/.hub"
    echo image-lock > "$SEED/skills/.hub/lock.json"
    echo image > "$SEED/skills/a-dir/SKILL.md"
    # Over a file, pointing at the agent's config; over a directory, dangling.
    ln -s /tmp/hermes/config.yaml "$WORK/stored/skills/.hub/lock.json"
    ln -s /nonexistent "$WORK/stored/skills/a-dir"
    cat > "$WORK/bin/dr-sync" <<STUB
#!/bin/sh
echo "dr-sync \$*" >> "\$STUB_LOG"
if [ "\$1" = download ]; then cp -R "$WORK/stored/." "\$2/" || exit 1; fi
exit 0
STUB
    chmod +x "$WORK/bin/dr-sync"
    run boot PATH="$WORK/bin:/opt/stubs:/usr/local/bin:/usr/bin:/bin" DR_SYNC_CATALOG_ID=catalog123 DR_SYNC_DOWNLOAD_ATTEMPTS=1
    [ "$status" -eq 0 ]
    [ ! -L /tmp/hermes/skills/.hub/lock.json ]
    [ "$(cat /tmp/hermes/skills/.hub/lock.json)" = image-lock ]
    cmp /repo/config/config.yaml /tmp/hermes/config.yaml
    [ ! -L /tmp/hermes/skills/a-dir ]
    [ "$(cat /tmp/hermes/skills/a-dir/SKILL.md)" = image ]
    grep -q 'the store has a symlink at skills/.hub/lock.json' "$WORK/err"
    grep -q 'the store has a symlink at skills/a-dir' "$WORK/err"
}

@test "the download is moved into HERMES_HOME, not copied, so the state is never in /tmp twice" {
    mkdir -p "$WORK/bin" "$WORK/stored/sessions" "$WORK/stored/skills/learned"
    echo chat > "$WORK/stored/sessions/chat.json"
    echo agent > "$WORK/stored/skills/learned/SKILL.md"
    # Records the inode each file has in the stage.
    cat > "$WORK/bin/dr-sync" <<STUB
#!/bin/sh
echo "dr-sync \$*" >> "\$STUB_LOG"
if [ "\$1" = download ]; then
    cp -R "$WORK/stored/." "\$2/" || exit 1
    stat -c %i "\$2/sessions/chat.json" "\$2/skills/learned/SKILL.md" > "$WORK/inodes"
fi
exit 0
STUB
    chmod +x "$WORK/bin/dr-sync"
    run boot PATH="$WORK/bin:/opt/stubs:/usr/local/bin:/usr/bin:/bin" DR_SYNC_CATALOG_ID=catalog123
    [ "$status" -eq 0 ]
    [ "$(stat -c %i /tmp/hermes/sessions/chat.json /tmp/hermes/skills/learned/SKILL.md)" = "$(cat "$WORK/inodes")" ]
    [ ! -e /tmp/dr-sync-stage ]
    [ ! -e /tmp/dr-sync-stage.list ]
}

@test "the hub's lock is merged with the venv's Python after the overlay, from a copy of the stored one" {
    run grep -n 'hub-lock.py\|cp -R "\$HERMES_SEED/\$d/\." ' /repo/docker/entrypoint.d/20-state-sync.sh
    [ "$status" -eq 0 ]
    overlay=$(echo "$output" | grep -m1 'cp -R' | cut -d: -f1)
    merge=$(echo "$output" | grep -m1 'hub-lock.py' | cut -d: -f1)
    [ "$overlay" -lt "$merge" ]
    grep -q '/opt/hermes/.venv/bin/python3 "\$ENTRYPOINT_DIR/hub-lock.py"' /repo/docker/entrypoint.d/20-state-sync.sh
    mkdir -p "$SEED/skills/.hub" "$WORK/bin" "$WORK/stored/skills/.hub"
    echo '{"version": 1, "installed": {}}' > "$SEED/skills/.hub/lock.json"
    echo '{"version": 1, "installed": {"x": {}}}' > "$WORK/stored/skills/.hub/lock.json"
    cat > "$WORK/bin/dr-sync" <<STUB
#!/bin/sh
echo "dr-sync \$*" >> "\$STUB_LOG"
if [ "\$1" = download ]; then cp -R "$WORK/stored/." "\$2/" || exit 1; fi
exit 0
STUB
    chmod +x "$WORK/bin/dr-sync"
    run boot PATH="$WORK/bin:/opt/stubs:/usr/local/bin:/usr/bin:/bin" DR_SYNC_CATALOG_ID=catalog123
    [ "$status" -eq 0 ]
    [ ! -e /tmp/dr-sync-hub-lock.json ]
}

@test "a stored hub lock nobody can read doesn't stop the boot" {
    mkdir -p "$SEED/skills/.hub" "$WORK/bin" "$WORK/stored/skills/.hub"
    echo image-lock > "$SEED/skills/.hub/lock.json"
    echo stored-lock > "$WORK/stored/skills/.hub/lock.json"
    cat > "$WORK/bin/dr-sync" <<STUB
#!/bin/sh
echo "dr-sync \$*" >> "\$STUB_LOG"
if [ "\$1" = download ]; then
    cp -R "$WORK/stored/." "\$2/" || exit 1
    chmod 000 "\$2/skills/.hub/lock.json"
fi
exit 0
STUB
    chmod +x "$WORK/bin/dr-sync"
    run boot PATH="$WORK/bin:/opt/stubs:/usr/local/bin:/usr/bin:/bin" DR_SYNC_CATALOG_ID=catalog123
    [ "$status" -eq 0 ]
    [ "$(cat /tmp/hermes/skills/.hub/lock.json)" = image-lock ]
    [ ! -e /tmp/dr-sync-hub-lock.json ]
}

@test "the download reads the image's .drsyncignore, as it did in HERMES_HOME" {
    mkdir -p "$WORK/bin"
    cat > "$WORK/bin/dr-sync" <<STUB
#!/bin/sh
echo "dr-sync \$*" >> "\$STUB_LOG"
if [ "\$1" = download ]; then cmp "\$2/.drsyncignore" "$SEED/.drsyncignore" || exit 1; fi
exit 0
STUB
    chmod +x "$WORK/bin/dr-sync"
    run boot PATH="$WORK/bin:/opt/stubs:/usr/local/bin:/usr/bin:/bin" DR_SYNC_CATALOG_ID=catalog123 DR_SYNC_DOWNLOAD_ATTEMPTS=1
    [ "$status" -eq 0 ]
}

# handoff_setup <self id>: the stubs for a pod named lrs-<self id>-... in a
# workload whose proton list, call by call, is $WORK/protons.1, .2, ... (the
# last one repeating). dr-sync serves a handoff marker once $WORK/marker
# exists. The full download fails from the call $WORK/fail-download-from on,
# and the store's download holds a directory or a symlink at the marker's path when
# $WORK/stored-marker says so. With $WORK/slow-first, the first upload takes
# that many seconds and records in $WORK/first-saw whether the marker was
# there when it ended.
handoff_setup() {
    mkdir -p "$WORK/bin"
    printf '#!/bin/sh\necho lrs-%s-5bcd5b4cbc-lf49d\n' "$1" > "$WORK/bin/hostname"
    cat > "$WORK/bin/fakepy" <<STUB
#!/bin/sh
case "\$2" in
    protons)
        n=\$(( \$(cat "$WORK/calls" 2>/dev/null || echo 0) + 1 ))
        echo "\$n" > "$WORK/calls"
        f="$WORK/protons.\$n"
        [ -f "\$f" ] || f=\$(ls "$WORK"/protons.* | sort -t. -k2 -n | tail -n 1)
        cat "\$f"
        ;;
esac
STUB
    cat > "$WORK/bin/dr-sync" <<STUB
#!/bin/sh
echo "dr-sync \$*" >> "\$STUB_LOG"
case "\$*" in
    *"--prefix .dr-sync-handoff"*)
        if [ -f "$WORK/hang" ]; then sleep 60; fi
        if [ -f "$WORK/marker" ]; then cp "$WORK/marker" "\$2/.dr-sync-handoff"; fi
        ;;
    "download /tmp/dr-sync-stage")
        n=\$(( \$(cat "$WORK/downloads" 2>/dev/null || echo 0) + 1 ))
        echo "\$n" > "$WORK/downloads"
        if [ "\$n" -ge "\$(cat "$WORK/fail-download-from" 2>/dev/null || echo 99)" ]; then exit 1; fi
        case "\$(cat "$WORK/stored-marker" 2>/dev/null)" in
            dir) mkdir -p "\$2/.dr-sync-handoff" && touch "\$2/.dr-sync-handoff/x" ;;
            symlink) ln -s "$WORK/target" "\$2/.dr-sync-handoff" ;;
        esac
        ;;
    upload*)
        n=\$(( \$(cat "$WORK/uploads" 2>/dev/null || echo 0) + 1 ))
        echo "\$n" > "$WORK/uploads"
        if [ "\$n" = 1 ] && [ -f "$WORK/slow-first" ]; then
            sleep "\$(cat "$WORK/slow-first")"
            if [ -e "\$2/.dr-sync-handoff" ]; then echo yes; else echo no; fi > "$WORK/first-saw"
        fi
        if [ "\$n" -le "\$(cat "$WORK/fail-uploads" 2>/dev/null || echo 0)" ]; then exit 1; fi
        cp "\$2/.dr-sync-handoff" "$WORK/uploaded-marker" 2>/dev/null || true
        ;;
esac
exit 0
STUB
    chmod +x "$WORK/bin/hostname" "$WORK/bin/fakepy" "$WORK/bin/dr-sync"
}

handoff_boot() {
    boot PATH="$WORK/bin:/opt/stubs:/usr/local/bin:/usr/bin:/bin" DR_SYNC_CATALOG_ID=catalog123 WORKLOAD_ID=w1 \
        HERMES_PYTHON="$WORK/bin/fakepy" HANDOFF_POLL_SECONDS=1 HANDOFF_TIMEOUT_SECONDS=20 "$@"
}

# long_gateway: a gateway that runs until it is told to stop.
long_gateway() {
    printf '#!/bin/sh\necho "hermes $*" >> "$STUB_LOG"\n[ "$1 $2" = "gateway run" ] || exit 0\ntrap "exit 0" TERM\nsleep 60 &\nwait $!\n' \
        > "$WORK/bin/hermes"
    chmod +x "$WORK/bin/hermes"
}

# boot_until <pattern> [VAR=value...]: boot in the background until the
# pattern is in stderr or the calls log, UNTIL_COUNT times (once by default),
# then stop the entrypoint as the platform would.
boot_until() {
    local pattern=$1
    shift
    handoff_boot "$@" &
    local pid=$!
    for _ in $(seq 150); do
        [ "$(cat "$WORK/err" "$WORK/calls.log" 2>/dev/null | grep -c -- "$pattern")" -ge "${UNTIL_COUNT:-1}" ] && break
        sleep 0.2
    done
    kill -TERM "$(pgrep -P "$pid" | head -n 1)" 2>/dev/null || true
    wait "$pid" || true
}

# line <pattern> [n]: the line number of the pattern's nth match in calls.log.
line() {
    grep -n -- "$1" "$WORK/calls.log" | sed -n "${2:-1}p" | cut -d: -f1
}

@test "with no other generation, a pod downloads once and uploads as usual" {
    handoff_setup aaaaaaaaaaaaaaaaaaaaaaaa
    printf 'aaaaaaaaaaaaaaaaaaaaaaaa running\nbbbbbbbbbbbbbbbbbbbbbbbb stopped\n' > "$WORK/protons.1"
    run handoff_boot
    [ "$status" -eq 0 ]
    ! grep -q 'booting on its current state' "$WORK/err" || false
    ! grep -q -- '--prefix .dr-sync-handoff' "$WORK/calls.log" || false
    [ "$(grep -c '^dr-sync download /tmp/dr-sync-stage$' "$WORK/calls.log")" = 1 ]
    [ "$(cat "$WORK/uploads")" = 1 ]
}

@test "during a rollout, a pod serves on the store as it is, uploads nothing, then reloads what the old one hands off" {
    handoff_setup aaaaaaaaaaaaaaaaaaaaaaaa
    long_gateway
    printf 'aaaaaaaaaaaaaaaaaaaaaaaa running\nbbbbbbbbbbbbbbbbbbbbbbbb draining\n' > "$WORK/protons.1"
    # The old generation's final upload lands after a few polls.
    ( sleep 3; echo bbbbbbbbbbbbbbbbbbbbbbbb > "$WORK/marker" ) &
    # A 1 s interval: no periodic upload either, until the reload.
    UNTIL_COUNT=2 boot_until '^hermes gateway run' DR_SYNC_INTERVAL_SECONDS=1
    grep -q 'generation bbbbbbbbbbbbbbbbbbbbbbbb may still write the state store; booting on its current state, uploading nothing until it hands off' "$WORK/err"
    grep -qE 'state store handed off after [0-9]+s; reloading it' "$WORK/err"
    grep -q 'reloading the state store to take it over' "$WORK/err"
    # The bundled skills are synced again over the state the reload brought.
    [ "$(grep -c 'skills in HERMES_HOME' "$WORK/err")" = 2 ]
    # Download, gateway, the marker, download again, gateway again, and only
    # then an upload: the final one, on the platform's stop.
    [ "$(line '^dr-sync download /tmp/dr-sync-stage$')" -lt "$(line '^hermes gateway run')" ]
    [ "$(line '^hermes gateway run')" -lt "$(line 'dr-sync-handoff-check')" ]
    [ "$(line 'dr-sync-handoff-check')" -lt "$(line '^dr-sync download /tmp/dr-sync-stage$' 2)" ]
    [ "$(line '^dr-sync download /tmp/dr-sync-stage$' 2)" -lt "$(line '^hermes gateway run' 2)" ]
    [ "$(line '^hermes gateway run' 2)" -lt "$(line '^dr-sync upload')" ]
}

@test "a marker from an earlier rollout doesn't count; the old generation stopping does" {
    handoff_setup aaaaaaaaaaaaaaaaaaaaaaaa
    long_gateway
    echo cccccccccccccccccccccccc > "$WORK/marker"
    printf 'aaaaaaaaaaaaaaaaaaaaaaaa running\nbbbbbbbbbbbbbbbbbbbbbbbb draining\n' > "$WORK/protons.1"
    printf 'aaaaaaaaaaaaaaaaaaaaaaaa running\nbbbbbbbbbbbbbbbbbbbbbbbb stopping\n' > "$WORK/protons.2"
    printf 'aaaaaaaaaaaaaaaaaaaaaaaa running\nbbbbbbbbbbbbbbbbbbbbbbbb stopped\n' > "$WORK/protons.3"
    boot_until 'reloading the state store to take it over'
    grep -qE 'state store handed off after [0-9]+s' "$WORK/err"
    [ "$(cat "$WORK/calls")" -ge 3 ]
    [ "$(grep -c '^dr-sync download /tmp/dr-sync-stage$' "$WORK/calls.log")" = 2 ]
}

@test "with no handoff before the timeout, the pod warns and takes the store over anyway" {
    handoff_setup aaaaaaaaaaaaaaaaaaaaaaaa
    long_gateway
    printf 'aaaaaaaaaaaaaaaaaaaaaaaa running\nbbbbbbbbbbbbbbbbbbbbbbbb running\n' > "$WORK/protons.1"
    boot_until 'reloading the state store to take it over' HANDOFF_TIMEOUT_SECONDS=2
    grep -qE 'Warning: no handoff from bbbbbbbbbbbbbbbbbbbbbbbb after [0-9]+s; taking the state store over anyway' "$WORK/err"
    [ "$(grep -c '^dr-sync download /tmp/dr-sync-stage$' "$WORK/calls.log")" = 2 ]
}

@test "a hung marker download can't hold the takeover past the deadline" {
    handoff_setup aaaaaaaaaaaaaaaaaaaaaaaa
    long_gateway
    printf 'aaaaaaaaaaaaaaaaaaaaaaaa running\nbbbbbbbbbbbbbbbbbbbbbbbb draining\n' > "$WORK/protons.1"
    : > "$WORK/hang"
    start=$(date +%s)
    boot_until 'reloading the state store to take it over' HANDOFF_TIMEOUT_SECONDS=3
    [ $(($(date +%s) - start)) -lt 20 ]
    grep -q 'Warning: no handoff from bbbbbbbbbbbbbbbbbbbbbbbb' "$WORK/err"
    [ "$(grep -c '^dr-sync download /tmp/dr-sync-stage$' "$WORK/calls.log")" = 2 ]
}

@test "a new pod whose gateway fails during a rollout exits with its status and never uploads" {
    handoff_setup aaaaaaaaaaaaaaaaaaaaaaaa
    printf '#!/bin/sh\necho "hermes $*" >> "$STUB_LOG"\n[ "$1 $2" = "gateway run" ] || exit 0\nexit 3\n' > "$WORK/bin/hermes"
    chmod +x "$WORK/bin/hermes"
    printf 'aaaaaaaaaaaaaaaaaaaaaaaa running\nbbbbbbbbbbbbbbbbbbbbbbbb draining\n' > "$WORK/protons.1"
    echo bbbbbbbbbbbbbbbbbbbbbbbb > "$WORK/marker"
    run handoff_boot
    [ "$status" -eq 3 ]
    ! grep -q '^dr-sync upload' "$WORK/calls.log" || false
    ! grep -q 'reloading the state store' "$WORK/err" || false
}

@test "a new pod stopped by the platform before the handoff never uploads" {
    handoff_setup aaaaaaaaaaaaaaaaaaaaaaaa
    long_gateway
    printf 'aaaaaaaaaaaaaaaaaaaaaaaa running\nbbbbbbbbbbbbbbbbbbbbbbbb running\n' > "$WORK/protons.1"
    boot_until 'skills in HERMES_HOME'
    ! grep -q '^dr-sync upload' "$WORK/calls.log" || false
    ! grep -q 'reloading the state store' "$WORK/err" || false
}

@test "a reload whose download fails is fatal, and nothing is uploaded" {
    handoff_setup aaaaaaaaaaaaaaaaaaaaaaaa
    long_gateway
    printf 'aaaaaaaaaaaaaaaaaaaaaaaa running\nbbbbbbbbbbbbbbbbbbbbbbbb draining\n' > "$WORK/protons.1"
    echo bbbbbbbbbbbbbbbbbbbbbbbb > "$WORK/marker"
    echo 2 > "$WORK/fail-download-from"
    run handoff_boot DR_SYNC_DOWNLOAD_ATTEMPTS=1
    [ "$status" -eq 1 ]
    grep -q 'FATAL: dr-sync download failed after 1 attempts' "$WORK/err"
    ! grep -q '^dr-sync upload' "$WORK/calls.log" || false
}

@test "a draining generation stops its gateway, uploads its marker last, and idles until stopped" {
    handoff_setup aaaaaaaaaaaaaaaaaaaaaaaa
    printf 'aaaaaaaaaaaaaaaaaaaaaaaa running\n' > "$WORK/protons.1"
    printf 'aaaaaaaaaaaaaaaaaaaaaaaa draining\nbbbbbbbbbbbbbbbbbbbbbbbb running\n' > "$WORK/protons.2"
    # A gateway that runs until it is told to stop.
    printf '#!/bin/sh\necho "hermes $*" >> "$STUB_LOG"\n[ "$1 $2" = "gateway run" ] || exit 0\ntrap "exit 0" TERM\nsleep 60 &\nwait $!\n' \
        > "$WORK/bin/hermes"
    chmod +x "$WORK/bin/hermes"
    handoff_boot &
    pid=$!
    for _ in $(seq 100); do
        grep -q 'idling until the platform stops this generation' "$WORK/err" 2>/dev/null && break
        sleep 0.2
    done
    grep -q 'this generation is draining; handing the state store off' "$WORK/err"
    [ "$(cat "$WORK/uploaded-marker")" = aaaaaaaaaaaaaaaaaaaaaaaa ]
    # Still running: it must not exit and be started again. The platform's
    # stop is a TERM to the entrypoint itself, not to this test's subshell.
    # boot runs the entrypoint as its child; both are still there while it idles.
    kill -0 "$pid"
    entrypoint=$(pgrep -P "$pid" | head -n 1)
    [ -n "$entrypoint" ]
    kill -TERM "$entrypoint"
    status=0
    wait "$pid" || status=$?
    [ "$status" -eq 0 ]
}

@test "a gateway that exits on its own while the generation drains still hands off" {
    handoff_setup aaaaaaaaaaaaaaaaaaaaaaaa
    printf 'aaaaaaaaaaaaaaaaaaaaaaaa running\n' > "$WORK/protons.1"
    printf 'aaaaaaaaaaaaaaaaaaaaaaaa draining\n' > "$WORK/protons.2"
    # The stub gateway exits at once, before the watcher's first poll (60 s away).
    handoff_boot HANDOFF_POLL_SECONDS=60 &
    pid=$!
    for _ in $(seq 100); do
        grep -q 'idling until' "$WORK/err" 2>/dev/null && break
        sleep 0.2
    done
    grep -q 'this generation is draining; handing the state store off' "$WORK/err"
    grep -q 'state store handed off; idling until' "$WORK/err"
    [ "$(cat "$WORK/uploaded-marker")" = aaaaaaaaaaaaaaaaaaaaaaaa ]
    kill -0 "$pid"
    kill -TERM "$(pgrep -P "$pid" | head -n 1)"
    wait "$pid" || true
}

@test "a failed handoff upload is retried until the marker lands" {
    handoff_setup aaaaaaaaaaaaaaaaaaaaaaaa
    printf 'aaaaaaaaaaaaaaaaaaaaaaaa running\n' > "$WORK/protons.1"
    printf 'aaaaaaaaaaaaaaaaaaaaaaaa draining\n' > "$WORK/protons.2"
    echo 2 > "$WORK/fail-uploads"
    printf '#!/bin/sh\necho "hermes $*" >> "$STUB_LOG"\n[ "$1 $2" = "gateway run" ] || exit 0\ntrap "exit 0" TERM\nsleep 60 &\nwait $!\n' \
        > "$WORK/bin/hermes"
    chmod +x "$WORK/bin/hermes"
    handoff_boot &
    pid=$!
    for _ in $(seq 100); do
        grep -q 'idling until' "$WORK/err" 2>/dev/null && break
        sleep 0.2
    done
    grep -q 'handoff upload failed (attempt 1); retrying' "$WORK/err"
    grep -q 'handoff upload failed (attempt 2); retrying' "$WORK/err"
    grep -q 'state store handed off; idling until' "$WORK/err"
    [ "$(cat "$WORK/uploads")" = 3 ]
    [ "$(cat "$WORK/uploaded-marker")" = aaaaaaaaaaaaaaaaaaaaaaaa ]
    kill -TERM "$(pgrep -P "$pid" | head -n 1)"
    wait "$pid" || true
}

@test "when every handoff upload fails, the pod says so, keeps no marker, and still idles" {
    handoff_setup aaaaaaaaaaaaaaaaaaaaaaaa
    printf 'aaaaaaaaaaaaaaaaaaaaaaaa running\n' > "$WORK/protons.1"
    printf 'aaaaaaaaaaaaaaaaaaaaaaaa draining\n' > "$WORK/protons.2"
    echo 99 > "$WORK/fail-uploads"
    printf '#!/bin/sh\necho "hermes $*" >> "$STUB_LOG"\n[ "$1 $2" = "gateway run" ] || exit 0\ntrap "exit 0" TERM\nsleep 60 &\nwait $!\n' \
        > "$WORK/bin/hermes"
    chmod +x "$WORK/bin/hermes"
    handoff_boot HANDOFF_UPLOAD_ATTEMPTS=2 &
    pid=$!
    for _ in $(seq 100); do
        grep -q 'idling until' "$WORK/err" 2>/dev/null && break
        sleep 0.2
    done
    grep -q 'the handoff upload kept failing, so the next generation waits for this one to stop' "$WORK/err"
    [ "$(cat "$WORK/uploads")" = 2 ]
    [ ! -e /tmp/hermes/.dr-sync-handoff ]
    kill -0 "$pid"
    kill -TERM "$(pgrep -P "$pid" | head -n 1)"
    wait "$pid" || true
}

# drain_and_idle [VAR=value...]: boot a pod whose generation starts draining
# at the watcher's second poll, with a gateway that runs until it is told to
# stop, and wait for it to idle. Leaves the boot's pid in $pid.
drain_and_idle() {
    handoff_setup aaaaaaaaaaaaaaaaaaaaaaaa
    printf 'aaaaaaaaaaaaaaaaaaaaaaaa running\n' > "$WORK/protons.1"
    printf 'aaaaaaaaaaaaaaaaaaaaaaaa running\n' > "$WORK/protons.2"
    printf 'aaaaaaaaaaaaaaaaaaaaaaaa draining\n' > "$WORK/protons.3"
    printf '#!/bin/sh\necho "hermes $*" >> "$STUB_LOG"\n[ "$1 $2" = "gateway run" ] || exit 0\ntrap "exit 0" TERM\nsleep 60 &\nwait $!\n' \
        > "$WORK/bin/hermes"
    chmod +x "$WORK/bin/hermes"
}

wait_idle() {
    for _ in $(seq 150); do
        grep -q 'idling until' "$WORK/err" 2>/dev/null && break
        sleep 0.2
    done
}

@test "a periodic upload in flight at the drain can't carry the marker, and the final upload waits for it" {
    drain_and_idle
    # The periodic upload starts a second in and holds the lock past the
    # final upload's old 5 s wait; the drain comes while it runs.
    echo 8 > "$WORK/slow-first"
    handoff_boot DR_SYNC_INTERVAL_SECONDS=1 &
    pid=$!
    wait_idle
    grep -q 'state store handed off; idling until' "$WORK/err"
    [ "$(cat "$WORK/first-saw")" = no ]
    [ "$(cat "$WORK/uploads")" = 2 ]
    [ "$(cat "$WORK/uploaded-marker")" = aaaaaaaaaaaaaaaaaaaaaaaa ]
    ! grep -q 'could not get the sync lock' "$WORK/err" || false
    kill -TERM "$(pgrep -P "$pid" | head -n 1)"
    wait "$pid" || true
}

@test "the marker is written as a fresh file over a directory or a symlink the store left at its path" {
    for kind in dir symlink; do
        rm -rf /tmp/hermes /tmp/dr-sync-* "$WORK/uploads" "$WORK/uploaded-marker" "$WORK/calls"
        drain_and_idle
        echo "$kind" > "$WORK/stored-marker"
        echo keep > "$WORK/target"
        : > "$WORK/err"
        handoff_boot &
        pid=$!
        wait_idle
        grep -q 'state store handed off; idling until' "$WORK/err"
        [ "$(cat "$WORK/uploaded-marker")" = aaaaaaaaaaaaaaaaaaaaaaaa ]
        [ -f /tmp/hermes/.dr-sync-handoff ] && [ ! -L /tmp/hermes/.dr-sync-handoff ]
        [ "$(cat "$WORK/target")" = keep ]
        kill -TERM "$(pgrep -P "$pid" | head -n 1)"
        wait "$pid" || true
    done
}

@test "a handoff flag left in /tmp by an earlier run doesn't stop the next one from serving" {
    : > /tmp/dr-sync-handed-off
    run boot DR_SYNC_CATALOG_ID=catalog123
    [ "$status" -eq 0 ]
    ! grep -q 'idling until' "$WORK/err" || false
    [ ! -e /tmp/dr-sync-handed-off ]
}

@test "a download that keeps failing is fatal and the gateway never starts" {
    run boot DR_SYNC_CATALOG_ID=catalog123 STUB_DRSYNC_FAIL=1 DR_SYNC_DOWNLOAD_ATTEMPTS=1
    [ "$status" -ne 0 ]
    grep -q 'FATAL: dr-sync download failed after 1 attempts' "$WORK/err"
    assert_absent '^hermes gateway run' "$WORK/calls.log"
}

@test "a failed download is retried and the boot goes on when a later attempt succeeds" {
    run boot DR_SYNC_CATALOG_ID=catalog123 STUB_DRSYNC_FAIL_FIRST=1
    [ "$status" -eq 0 ]
    [ "$(grep -c '^dr-sync download' "$WORK/calls.log")" = 2 ]
    grep -q 'dr-sync download failed (attempt 1/5); retrying in 5s' "$WORK/err"
    grep -q '^hermes gateway run' "$WORK/calls.log"
}

@test "restores a downloaded database snapshot over its live path and drops the stale WAL" {
    mkdir -p "$SEED/sessions" "$SEED/.dr-sync-snapshots/sessions"
    echo live > "$SEED/sessions/chat.db"
    echo stale > "$SEED/sessions/chat.db-wal"
    echo snapshot > "$SEED/.dr-sync-snapshots/sessions/chat.db.snap"
    run boot DR_SYNC_CATALOG_ID=catalog123
    [ "$status" -eq 0 ]
    [ "$(cat /tmp/hermes/sessions/chat.db)" = snapshot ]
    [ ! -e /tmp/hermes/sessions/chat.db-wal ]
    grep -q 'restored database sessions/chat.db.snap' "$WORK/err"
}

@test "the final upload takes a snapshot of every live database first" {
    mkdir -p "$SEED/sessions"
    echo live > "$SEED/sessions/chat.db"
    run boot DR_SYNC_CATALOG_ID=catalog123
    [ "$status" -eq 0 ]
    [ "$(cat /tmp/hermes/.dr-sync-snapshots/sessions/chat.db.snap)" = live ]
    backup_line=$(grep -n '^sqlite3 /tmp/hermes/sessions/chat.db .backup' "$WORK/calls.log" | cut -d: -f1)
    upload_line=$(grep -n '^dr-sync upload' "$WORK/calls.log" | cut -d: -f1)
    [ "$backup_line" -lt "$upload_line" ]
}

@test "a failed backup keeps the previous snapshot and the upload still runs" {
    mkdir -p "$SEED/sessions" "$SEED/.dr-sync-snapshots/sessions"
    echo live > "$SEED/sessions/chat.db"
    echo previous > "$SEED/.dr-sync-snapshots/sessions/chat.db.snap"
    run boot DR_SYNC_CATALOG_ID=catalog123 STUB_SQLITE_FAIL=1
    [ "$status" -eq 0 ]
    grep -q 'snapshot of /tmp/hermes/sessions/chat.db failed; keeping the previous snapshot' "$WORK/err"
    [ "$(cat /tmp/hermes/.dr-sync-snapshots/sessions/chat.db.snap)" = previous ]
    [ ! -e /tmp/hermes/.dr-sync-snapshots/sessions/chat.db.snap.tmp ]
    grep -q '^dr-sync upload' "$WORK/calls.log"
}

@test "a failed backup with no previous snapshot blocks the upload" {
    mkdir -p "$SEED/sessions"
    echo live > "$SEED/sessions/chat.db"
    run boot DR_SYNC_CATALOG_ID=catalog123 STUB_SQLITE_FAIL=1
    [ "$status" -eq 0 ]
    grep -q 'snapshot of /tmp/hermes/sessions/chat.db failed and no previous snapshot exists' "$WORK/err"
    grep -q 'Warning: final dr-sync upload failed' "$WORK/err"
    assert_absent '^dr-sync upload' "$WORK/calls.log"
}

@test "renders the OTel config from the API endpoint, trimming a trailing slash" {
    run boot DATAROBOT_API_TOKEN=tok DATAROBOT_ENDPOINT=https://example.test/api/v2/ WORKLOAD_ID=abc
    [ "$status" -eq 0 ]
    grep -q 'hermes-otel export enabled: entity=workload-abc endpoint=https://example.test/otel' "$WORK/err"
    [ -f /tmp/hermes/hermes_otel.yaml ]
    grep -q 'https://example.test/otel' /tmp/hermes/hermes_otel.yaml
    assert_absent '//otel' /tmp/hermes/hermes_otel.yaml
    python3 -c 'import sys, yaml; yaml.safe_load(open("/tmp/hermes/hermes_otel.yaml"))'
}

@test "an explicit DATAROBOT_ENTITY_ID wins over the workload entity" {
    run boot DATAROBOT_API_TOKEN=tok DATAROBOT_ENDPOINT=https://example.test/api/v2 WORKLOAD_ID=abc \
        DATAROBOT_ENTITY_ID=experiment_container-123
    [ "$status" -eq 0 ]
    grep -q 'entity=experiment_container-123' "$WORK/err"
    assert_absent 'workload-abc' "$WORK/err"
}

@test "leaves OTel export off without an API token" {
    run boot DATAROBOT_ENDPOINT=https://example.test/api/v2 WORKLOAD_ID=abc
    [ "$status" -eq 0 ]
    grep -q 'hermes-otel export disabled' "$WORK/err"
    [ ! -e /tmp/hermes/hermes_otel.yaml ]
}

@test "generates an API_SERVER_KEY of 64 hex characters when none is given" {
    run boot
    [ "$status" -eq 0 ]
    grep -Eq '^API_SERVER_KEY=[0-9a-f]{64}$' "$WORK/gateway.env"
}

@test "keeps a provided API_SERVER_KEY" {
    run boot API_SERVER_KEY=providedkey
    [ "$status" -eq 0 ]
    grep -q '^API_SERVER_KEY=providedkey$' "$WORK/gateway.env"
}

@test "LLM_API_KEY defaults to DATAROBOT_API_TOKEN and is aliased to the provider key" {
    run boot DATAROBOT_API_TOKEN=drtok LLM_PROVIDER=NVIDIA \
        DATAROBOT_ENDPOINT=https://dr.example.com/api/v2 \
        LLM_BASE_URL=https://DR.example.com/api/v2/genai/llmgw
    [ "$status" -eq 0 ]
    grep -q '^LLM_API_KEY=drtok$' "$WORK/gateway.env"
    grep -q '^NVIDIA_API_KEY=drtok$' "$WORK/gateway.env"
}

@test "without LLM_BASE_URL, the gateway follows DATAROBOT_ENDPOINT and gets the token" {
    run boot DATAROBOT_API_TOKEN=drtok \
        DATAROBOT_ENDPOINT=https://staging.example.com/api/v2/
    [ "$status" -eq 0 ]
    grep -q '^hermes config set custom_providers.0.base_url https://staging.example.com/api/v2/genai/llmgw$' "$WORK/calls.log"
    grep -q '^LLM_API_KEY=drtok$' "$WORK/gateway.env"
}

@test "DATAROBOT_API_TOKEN is never sent to a gateway on another host" {
    run boot DATAROBOT_API_TOKEN=CANARYDRTOKEN \
        DATAROBOT_ENDPOINT=https://dr.example.com/api/v2 \
        LLM_BASE_URL=https://llm.example.org/v1
    [ "$status" -eq 0 ]
    grep -q '^LLM_API_KEY=$' "$WORK/gateway.env"
    grep -q 'set LLM_API_KEY for that gateway' "$WORK/err"
    # No self-test either: it would carry the key as a bearer token.
    assert_absent 'LLM gateway self-test' "$WORK/err"
}

@test "an explicit default port is the same origin, so the token still applies" {
    run boot DATAROBOT_API_TOKEN=drtok \
        DATAROBOT_ENDPOINT=https://dr.example.com/api/v2 \
        LLM_BASE_URL=https://dr.example.com:443/api/v2/genai/llmgw
    [ "$status" -eq 0 ]
    grep -q '^LLM_API_KEY=drtok$' "$WORK/gateway.env"
}

@test "an IPv6 install's own gateway gets the token, with or without the default port" {
    run boot DATAROBOT_API_TOKEN=drtok \
        DATAROBOT_ENDPOINT='https://[2001:db8::1]/api/v2' \
        LLM_BASE_URL='https://[2001:DB8::1]:443/api/v2/genai/llmgw'
    [ "$status" -eq 0 ]
    grep -q '^LLM_API_KEY=drtok$' "$WORK/gateway.env"
}

@test "a different IPv6 host gets no token" {
    run boot DATAROBOT_API_TOKEN=CANARYDRTOKEN \
        DATAROBOT_ENDPOINT='https://[2001:db8::1]/api/v2' \
        LLM_BASE_URL='https://[2001:db8::2]/v1'
    [ "$status" -eq 0 ]
    grep -q '^LLM_API_KEY=$' "$WORK/gateway.env"
}

@test "a user@ prefix naming the install's host doesn't fool the origin check" {
    run boot DATAROBOT_API_TOKEN=CANARYDRTOKEN \
        DATAROBOT_ENDPOINT=https://dr.example.com/api/v2 \
        LLM_BASE_URL=https://dr.example.com@evil.test/v1
    [ "$status" -eq 0 ]
    grep -q '^LLM_API_KEY=$' "$WORK/gateway.env"
}

@test "a lookalike host that merely starts with the install's host gets no token" {
    run boot DATAROBOT_API_TOKEN=CANARYDRTOKEN \
        DATAROBOT_ENDPOINT=https://dr.example.com/api/v2 \
        LLM_BASE_URL=https://dr.example.com.evil.test/v1
    [ "$status" -eq 0 ]
    grep -q '^LLM_API_KEY=$' "$WORK/gateway.env"
}

@test "an explicit LLM_API_KEY is not replaced" {
    run boot DATAROBOT_API_TOKEN=drtok LLM_API_KEY=ownkey
    [ "$status" -eq 0 ]
    grep -q '^LLM_API_KEY=ownkey$' "$WORK/gateway.env"
}

@test "passes LLM_MODEL and LLM_BASE_URL to Hermes through config set" {
    run boot LLM_MODEL=my-model LLM_BASE_URL=https://llm.test LLM_API_KEY=k
    [ "$status" -eq 0 ]
    grep -q '^hermes config set model.default my-model$' "$WORK/calls.log"
    grep -q '^hermes config set custom_providers.0.base_url https://llm.test$' "$WORK/calls.log"
    grep -q 'LLM gateway self-test: HTTP 200' "$WORK/err"
}

@test "nginx.conf passes nginx -t" {
    mkdir -p /tmp/nginx
    run /usr/sbin/nginx -e /dev/stderr -t -c /repo/docker/nginx.conf
    [ "$status" -eq 0 ]
}
