#!/usr/bin/env bats
# Behaviour of docker/entrypoint.sh, run for real against the repo's own seed
# files. Hermes, dr-sync, curl and nginx are stubs (tests/fixtures/opt/stubs)
# that record their calls. The container runs as uid 1000 on a read-only root
# with only /tmp writable, the same constraints as the workload.

PEM=$'-----BEGIN RSA PRIVATE KEY-----\nCANARYPEMBODYAAAA\nCANARYPEMBODYBBBB=\n-----END RSA PRIVATE KEY-----'

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

@test "skips dr-sync with a notice when DR_SYNC_CATALOG_ID is unset" {
    run boot
    [ "$status" -eq 0 ]
    grep -q 'DR_SYNC_CATALOG_ID not set' "$WORK/err"
    assert_absent 'dr-sync' "$WORK/calls.log"
}

@test "downloads state once on boot when DR_SYNC_CATALOG_ID is set" {
    run boot DR_SYNC_CATALOG_ID=catalog123
    [ "$status" -eq 0 ]
    [ "$(grep -c '^dr-sync download /tmp/hermes$' "$WORK/calls.log")" = 1 ]
    assert_absent 'dr-sync upload' "$WORK/calls.log"
}

@test "a failed dr-sync download does not stop the boot" {
    run boot DR_SYNC_CATALOG_ID=catalog123 STUB_DRSYNC_FAIL=1
    [ "$status" -eq 0 ]
    grep -q 'dr-sync download failed; starting fresh' "$WORK/err"
    grep -q '^hermes gateway run' "$WORK/calls.log"
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
    run boot DATAROBOT_API_TOKEN=drtok LLM_PROVIDER=NVIDIA
    [ "$status" -eq 0 ]
    grep -q '^LLM_API_KEY=drtok$' "$WORK/gateway.env"
    grep -q '^NVIDIA_API_KEY=drtok$' "$WORK/gateway.env"
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
