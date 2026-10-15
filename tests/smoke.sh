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

# Build the workload image and boot it the way DataRobot runs it: uid 1000, a
# read-only root and only /tmp writable. `task test:image` or `tests/smoke.sh`.
# Needs only Docker; the image is about 4 GB, so the first build is slow.
#
# The container gets dummy Slack, GitHub and DataRobot values, including a
# canary PEM, and no network: Slack, the LLM self-test and OTel fail fast, and
# nothing can leave the box. It passes when /health answers 200, still does
# after the Slack adapter has failed, and the logs never show a canary value.
#
#   SMOKE_IMAGE    test this image instead of building labs-hermes:smoke
#   SMOKE_TIMEOUT        seconds to wait for /health (default 240)
#   SMOKE_SLACK_TIMEOUT  seconds to wait, after that, for Slack to fail (default 120)
#   SMOKE_GRACE          seconds /health must stay up after Slack failed (default 20)
set -eu

repo=$(cd "$(dirname "$0")/.." && pwd)
timeout=${SMOKE_TIMEOUT:-240}
slack_timeout=${SMOKE_SLACK_TIMEOUT:-120}
grace=${SMOKE_GRACE:-20}
poll=${SMOKE_POLL:-2}
container=labs-hermes-smoke-$$
volume=$container-data
logs=$(mktemp)

# Canary values. The PEM is built from fragments so secret scanners don't flag
# this file, as in tests/entrypoint.bats. They're handed to `docker run` by
# name, so they never appear on a command line either.
pem_edge='-----'
pem_kind='RSA PRIVATE'
GITHUB_PRIVATE_KEY="${pem_edge}BEGIN ${pem_kind} KEY${pem_edge}
CANARYPEMBODYAAAA
CANARYPEMBODYBBBB=
${pem_edge}END ${pem_kind} KEY${pem_edge}"
SLACK_BOT_TOKEN=xoxb-CANARYSLACKBOT
SLACK_APP_TOKEN=xapp-CANARYSLACKAPP
DATAROBOT_API_TOKEN=CANARYDRTOKEN
LLM_API_KEY=CANARYLLMKEY
export GITHUB_PRIVATE_KEY SLACK_BOT_TOKEN SLACK_APP_TOKEN DATAROBOT_API_TOKEN LLM_API_KEY
canaries='CANARYPEMBODY CANARYSLACKBOT CANARYSLACKAPP CANARYDRTOKEN CANARYLLMKEY'

cleanup() {
    docker rm --force --volumes "$container" > /dev/null 2>&1 || true
    docker volume rm "$volume" > /dev/null 2>&1 || true
    rm -f "$logs"
}
trap cleanup EXIT
trap 'exit 130' INT TERM HUP

say() {
    echo "[smoke] $*" >&2
}

fail() {
    say "FAIL: $*"
    if docker logs "$container" > "$logs" 2>&1; then
        say "last 200 lines of the container log:"
        tail -n 200 "$logs" >&2
    fi
    exit 1
}

running() {
    [ "$(docker inspect --format '{{.State.Running}}' "$container" 2>/dev/null)" = true ]
}

# The status /health answers inside the container, through nginx to the
# gateway. "000" when nothing answers yet.
health() {
    docker exec "$container" curl -sS -o /dev/null -w '%{http_code}' --max-time 5 \
        http://127.0.0.1:8642/health 2>/dev/null || true
}

image=${SMOKE_IMAGE:-}
if [ -z "$image" ]; then
    image=labs-hermes:smoke
    say "building $image"
    # The workload runs linux/amd64, as compose.yaml does locally.
    docker build --platform linux/amd64 --tag "$image" "$repo" \
        || fail "the image did not build"
fi

say "starting $image as uid 1000 on a read-only root, without a network"
# DR_SYNC_CATALOG_ID stays unset: a dummy catalog would crash-loop on download.
# WORKLOAD_ID is set, as DataRobot sets it, so OTel export takes the deployed
# path that renders the API token into its config. The base image declares
# /opt/data a VOLUME, which Docker would mount writable despite --read-only;
# DataRobot mounts nothing there, so it gets a read-only volume instead, filled
# from the image like the anonymous one would be. Named, because Docker refuses
# a read-only anonymous volume; cleanup removes it.
docker run --detach --name "$container" --platform linux/amd64 \
    --network none --read-only --user 1000:1000 --tmpfs /tmp:exec,mode=1777 \
    --mount "type=volume,source=$volume,target=/opt/data,readonly" \
    --env SLACK_BOT_TOKEN --env SLACK_APP_TOKEN --env SLACK_ALLOWED_USERS=U0SMOKE \
    --env GITHUB_APP_ID=1 --env GITHUB_INSTALLATION_IDS=1 --env GITHUB_PRIVATE_KEY \
    --env DATAROBOT_API_TOKEN --env LLM_API_KEY --env LLM_BASE_URL=http://127.0.0.1:9/v1 \
    --env WORKLOAD_ID=smoke \
    "$image" > /dev/null \
    || fail "the container did not start"

start=$(date +%s)
status=000
while :; do
    running || fail "the container exited before /health answered"
    status=$(health)
    [ "$status" != 200 ] || break
    [ $(($(date +%s) - start)) -lt "$timeout" ] \
        || fail "/health did not answer 200 within ${timeout}s (last status: $status)"
    sleep "$poll"
done
say "/health answered 200 after $(($(date +%s) - start))s"

# With dummy tokens and no network, Slack's connection fails. Wait until the
# gateway says so (in a real run: "gateway.run: ✗ slack failed to connect"),
# rather than for a fixed time that a slower adapter could outlast. Then the
# gateway has to keep serving: its exit is the container's exit.
slack_start=$(date +%s)
until docker logs "$container" 2>&1 | grep -qF 'slack failed to connect'; do
    running || fail "the container exited before Slack reported its connection failure"
    [ $(($(date +%s) - slack_start)) -lt "$slack_timeout" ] \
        || fail "Slack did not report its connection failure within ${slack_timeout}s of /health answering"
    sleep "$poll"
done
say "Slack failed to connect, as it must without a network"
sleep "$grace"
running || fail "the container exited within ${grace}s of Slack failing"
status=$(health)
[ "$status" = 200 ] || fail "/health answered $status ${grace}s after Slack failed"
say "/health still answers 200 ${grace}s after Slack failed"

uid=$(docker exec "$container" id -u) || fail "could not read the container's uid"
[ "$uid" = 1000 ] || fail "the container runs as uid $uid, not 1000"
# Both paths belong to uid 1000 (see the Dockerfile), so only a read-only
# filesystem can refuse these writes. A permission error would prove nothing,
# so the error itself has to say so.
read_only() {
    if probe=$(docker exec "$container" touch "$1/.smoke" 2>&1); then
        fail "$1 is writable"
    fi
    case "$probe" in
        *"Read-only file system"*) ;;
        *) fail "could not probe $1: $probe" ;;
    esac
}
read_only /opt/hermes-seed
read_only /opt/data
say "runs as uid 1000 on a read-only root, /opt/data included"

docker logs "$container" > "$logs" 2>&1 || fail "could not read the container log"
for canary in $canaries; do
    if grep -qF "$canary" "$logs"; then
        fail "the container log shows the value of a secret (canary $canary)"
    fi
done
if grep -q 'BEGIN.RSA' "$logs"; then
    fail "the container log shows the private key"
fi
say "no secret value in $(wc -l < "$logs" | tr -d ' ') log lines"

# docker/entrypoint.d/50-skills.sh logs how many skills HERMES_HOME holds
# after the sync. No line means the skills step never ran; zero means the
# bundled skills were lost.
skills=$(sed -n 's/.*skills in HERMES_HOME: \([0-9][0-9]*\).*/\1/p' "$logs" | tail -n 1)
[ -n "$skills" ] || fail "the entrypoint did not log a skill count"
[ "$skills" -gt 0 ] || fail "HERMES_HOME holds no skills after boot"
# The seed's Labs skills keep the count above zero on their own, so it can't
# show that the base image's bundled skills arrived. 50-skills.sh warns when
# that sync fails or finds nothing to sync from, and a sync that copies nothing
# leaves no more skills than the seed holds. tests/static.bats keeps the Labs
# skills from duplicating bundled ones, so the difference is what the base
# image brought.
if grep -qF -e 'skills_sync.py failed' -e 'bundled skills directory' "$logs"; then
    fail "the base image's bundled skills did not sync"
fi
seeded=$(docker exec "$container" sh -c 'find /opt/hermes-seed/skills -name SKILL.md | wc -l') \
    || fail "could not count the seed's skills"
seeded=$(echo "$seeded" | tr -d ' ')
[ "$skills" -gt "$seeded" ] \
    || fail "no bundled skills reached HERMES_HOME ($skills skills, $seeded of them from the seed)"
say "$skills skills in HERMES_HOME, $((skills - seeded)) of them bundled with the base image"

# The secret scan above only covers the deployed OTel path if it ran:
# docker/entrypoint.d/30-otel.sh renders the API token into hermes_otel.yaml
# there, and the plugin loads it.
grep -q 'hermes-otel export enabled' "$logs" \
    || fail "OTel export was not enabled, as it is on a deployed workload"
# That line is the entrypoint rendering the config. The plugin loading it is
# its own line once its hooks are in (in a real run: "[hermes-otel] Registered
# 13 hooks"); without it, export was configured but never ran.
grep -qE '\[hermes-otel\] Registered [0-9]+ hooks' "$logs" \
    || fail "the hermes-otel plugin never registered its hooks"
say "OTel export enabled and the hermes-otel plugin loaded, as on a deployed workload"

# The whole log of a healthy boot, to read what Hermes reports (CI sets
# SMOKE_SHOW_LOG). The secrets in this run are canaries, so it is safe to show.
# On GitHub Actions it goes in a collapsed group, with workflow commands off:
# a container line starting with "::" must not act as one.
if [ "${SMOKE_SHOW_LOG:-}" = 1 ]; then
    if [ "${GITHUB_ACTIONS:-}" = true ]; then
        resume="smoke-log-$$-$(date +%s)"
        echo "::group::Container log"
        echo "::stop-commands::$resume"
        cat "$logs"
        echo "::$resume::"
        echo "::endgroup::"
    else
        say "container log:"
        cat "$logs" >&2
    fi
fi

say "ok"
