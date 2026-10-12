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

# Tests for scripts/deploy.sh, the steps of the reusable deploy workflow. Each
# test runs one step the way the workflow does, in a scratch tree, with a stub
# `dr` and a stub `curl` first on PATH.

setup() {
    work=$(mktemp -d)
    export CONFIG_DIR="$work/deploy-config" APP_DIR="$work/app" WORK_DIR="$work/tmp"
    export DEPLOY_DIR=deploy TARGET=prod MODE=plan LOCK=true
    export DEPLOY_OUTPUT_FILE="$work/out" DEPLOY_SUMMARY_FILE="$work/summary"
    export DATAROBOT_API_TOKEN=test-token-not-real
    mkdir -p "$WORK_DIR" "$APP_DIR/config" "$work/bin" \
        "$CONFIG_DIR/deploy/environments/prod" "$CONFIG_DIR/deploy/overrides/config"
    : > "$work/out"
    : > "$work/summary"
    printf 'v1.2.3\n' > "$CONFIG_DIR/deploy/VERSION"
    printf 'workloadId: abc123 # managed by the CLI\nname: hermes\n' > "$CONFIG_DIR/deploy/environments/prod/.datarobot.yaml"

    # A dr that records its arguments, prints a plan and exits with STUB_DR_STATUS.
    # STUB_DR_WRITES_ID makes it write a workloadId into the manifest, like a first deploy.
    cat > "$work/bin/dr" <<'STUB'
#!/bin/sh
[ "$1" = --version ] && { echo "dr stub"; exit 0; }
echo "$*" > "$STUB_DIR/dr-args"
while [ $# -gt 0 ]; do
    [ "$1" = --dir ] && dir=$2
    shift
done
echo "plan line one"
if [ -n "${STUB_DR_WRITES_ID:-}" ]; then
    printf 'workloadId: fed456 # managed by the CLI\n' > "$dir/.datarobot.yaml"
fi
exit "${STUB_DR_STATUS:-0}"
STUB
    chmod +x "$work/bin/dr"
    export STUB_DIR="$work"
    export PATH="$work/bin:$PATH"
}

step() {
    run bash /repo/scripts/deploy.sh "$@"
}

# --- dispatch -----------------------------------------------------------------

@test "an unknown step fails and lists the steps" {
    step no_such_step
    [ "$status" -eq 1 ]
    [[ "$output" == *"unknown step 'no_such_step'"* ]]
    [[ "$output" == *"run_up"* ]]
}

@test "no step fails" {
    step
    [ "$status" -eq 1 ]
}

@test "sourcing the script defines the steps and runs none" {
    run bash -c 'source /repo/scripts/deploy.sh && declare -F deploy::run_up'
    [ "$status" -eq 0 ]
    [ "$output" = "deploy::run_up" ]
}

@test "errors become GitHub annotations only on GitHub Actions" {
    MODE=nope step check_inputs
    [[ "$output" == "error: "* ]]
    GITHUB_ACTIONS=true MODE=nope step check_inputs
    [[ "$output" == "::error::"* ]]
}

# --- check_inputs -------------------------------------------------------------

@test "check_inputs accepts a valid mode, target and directory" {
    step check_inputs
    [ "$status" -eq 0 ]
    MODE=apply TARGET=staging-2 DEPLOY_DIR=deploy/hermes step check_inputs
    [ "$status" -eq 0 ]
    DEPLOY_DIR=. step check_inputs
    [ "$status" -eq 0 ]
}

@test "check_inputs rejects a mode other than plan or apply" {
    MODE=deploy step check_inputs
    [ "$status" -eq 1 ]
    [[ "$output" == *"mode must be plan or apply"* ]]
}

@test "check_inputs rejects targets that could escape the environments folder" {
    for bad in '' Prod 'a b' 'x;y' '../prod' 'prod/x'; do
        TARGET="$bad" step check_inputs
        [ "$status" -eq 1 ]
        [[ "$output" == *"target must match"* ]]
    done
}

@test "check_inputs rejects an absolute deploy-dir and one with .." {
    for bad in '' /etc ../up deploy/../../up; do
        DEPLOY_DIR="$bad" step check_inputs
        [ "$status" -eq 1 ]
        [[ "$output" == *"deploy-dir must be a relative path"* ]]
    done
}

# --- read_version -------------------------------------------------------------

@test "read_version emits a tag and trims whitespace" {
    printf '  v1.2.3 \n\n' > "$CONFIG_DIR/deploy/VERSION"
    step read_version
    [ "$status" -eq 0 ]
    [ "$(cat "$work/out")" = "ref=v1.2.3" ]
}

@test "read_version accepts a 40 character commit SHA" {
    sha=0123456789abcdef0123456789abcdef01234567
    echo "$sha" > "$CONFIG_DIR/deploy/VERSION"
    step read_version
    [ "$status" -eq 0 ]
    [ "$(cat "$work/out")" = "ref=$sha" ]
}

@test "read_version rejects a branch name, a short version and a short SHA" {
    for bad in main v1.2 1.2.3 abc1234 ''; do
        echo "$bad" > "$CONFIG_DIR/deploy/VERSION"
        step read_version
        [ "$status" -eq 1 ]
        [[ "$output" == *"VERSION must hold"* ]]
    done
    [ ! -s "$work/out" ]
}

@test "read_version fails when VERSION is missing" {
    rm "$CONFIG_DIR/deploy/VERSION"
    step read_version
    [ "$status" -eq 1 ]
    [[ "$output" == *"VERSION is missing"* ]]
}

# --- apply_overrides ----------------------------------------------------------

@test "apply_overrides copies allowed overrides and the manifest into the checkout" {
    ov="$CONFIG_DIR/deploy/overrides/config"
    mkdir -p "$ov/skills/note"
    echo persona > "$ov/SOUL.md"
    echo skill > "$ov/skills/note/SKILL.md"
    echo cfg > "$ov/config.yaml"
    echo reqs > "$ov/requirements.txt"
    echo upstream > "$APP_DIR/config/SOUL.md"
    step apply_overrides
    [ "$status" -eq 0 ]
    [ "$(cat "$APP_DIR/config/SOUL.md")" = persona ]
    [ -f "$APP_DIR/config/skills/note/SKILL.md" ]
    [ -f "$APP_DIR/config/config.yaml" ]
    [ -f "$APP_DIR/config/requirements.txt" ]
    grep -q 'workloadId: abc123' "$APP_DIR/.datarobot.yaml"
}

@test "apply_overrides places the manifest when there are no overrides" {
    rmdir "$CONFIG_DIR/deploy/overrides/config"
    step apply_overrides
    [ "$status" -eq 0 ]
    [ -f "$APP_DIR/.datarobot.yaml" ]
}

@test "apply_overrides refuses the Dockerfile, docker/, .drsyncignore and hidden files" {
    for f in Dockerfile docker/entrypoint.sh .drsyncignore .env; do
        rm -rf "$CONFIG_DIR/deploy/overrides/config" "$APP_DIR/.datarobot.yaml"
        mkdir -p "$CONFIG_DIR/deploy/overrides/config/$(dirname "$f")"
        echo x > "$CONFIG_DIR/deploy/overrides/config/$f"
        step apply_overrides
        [ "$status" -eq 1 ]
        [[ "$output" == *"cannot be overridden"* ]]
        [ ! -e "$APP_DIR/.datarobot.yaml" ]
    done
}

@test "apply_overrides refuses a symlink, even a dangling one that points at a protected file" {
    ln -s SOUL.md.missing "$CONFIG_DIR/deploy/overrides/config/.drsyncignore"
    step apply_overrides
    [ "$status" -eq 1 ]
    [[ "$output" == *"symbolic links"* ]]
    [ ! -e "$APP_DIR/.datarobot.yaml" ]
}

@test "apply_overrides refuses a manifest that is a symlink" {
    manifest="$CONFIG_DIR/deploy/environments/prod/.datarobot.yaml"
    mv "$manifest" "$work/real.yaml"
    ln -s "$work/real.yaml" "$manifest"
    step apply_overrides
    [ "$status" -eq 1 ]
    [[ "$output" == *"must not be a symbolic link"* ]]
}

@test "apply_overrides fails when the manifest for the target is missing" {
    rm "$CONFIG_DIR/deploy/environments/prod/.datarobot.yaml"
    step apply_overrides
    [ "$status" -eq 1 ]
    [[ "$output" == *"is missing"* ]]
}

# --- install_dr ---------------------------------------------------------------

@test "install_dr downloads the pinned installer and installs the pinned version" {
    # A curl that writes an installer. The installer records what it was given.
    cat > "$work/bin/curl" <<'STUB'
#!/bin/sh
echo "$*" > "$STUB_DIR/curl-args"
while [ $# -gt 0 ]; do
    [ "$1" = -o ] && out=$2
    shift
done
printf '#!/bin/sh\necho "$1 $INSTALL_DIR" > "$STUB_DIR/installer-args"\n' > "$out"
STUB
    chmod +x "$work/bin/curl"
    DR_CLI_VERSION=v0.12.0 DR_CLI_INSTALLER_REF=d3fdb737e570a619e1f3944848f8e74adb701009 DR_BIN_DIR="$work/dr-bin" step install_dr
    [ "$status" -eq 0 ]
    grep -q 'cli/d3fdb737e570a619e1f3944848f8e74adb701009/install.sh' "$work/curl-args"
    [ "$(cat "$work/installer-args")" = "v0.12.0 $work/dr-bin" ]
}

@test "install_dr fails without a pinned version" {
    step install_dr
    [ "$status" -ne 0 ]
    [[ "$output" == *"DR_CLI_VERSION"* ]]
}

# --- run_up -------------------------------------------------------------------

@test "run_up plans with --dry-run and without --lock" {
    cp "$CONFIG_DIR/deploy/environments/prod/.datarobot.yaml" "$APP_DIR/.datarobot.yaml"
    MODE=plan step run_up
    [ "$status" -eq 0 ]
    args=$(cat "$work/dr-args")
    [[ "$args" == *"workload up"* ]]
    [[ "$args" == *"--dry-run"* ]]
    [[ "$args" != *"--lock"* ]]
    [[ "$args" == *"--yes"* ]]
}

@test "run_up applies with --lock when LOCK is true" {
    cp "$CONFIG_DIR/deploy/environments/prod/.datarobot.yaml" "$APP_DIR/.datarobot.yaml"
    MODE=apply LOCK=true step run_up
    [ "$status" -eq 0 ]
    args=$(cat "$work/dr-args")
    [[ "$args" == *"--lock"* ]]
    [[ "$args" != *"--dry-run"* ]]
}

@test "run_up applies without --lock when LOCK is false" {
    cp "$CONFIG_DIR/deploy/environments/prod/.datarobot.yaml" "$APP_DIR/.datarobot.yaml"
    MODE=apply LOCK=false step run_up
    [ "$status" -eq 0 ]
    [[ "$(cat "$work/dr-args")" != *"--lock"* ]]
}

@test "run_up refuses to run without a token and never calls dr" {
    DATAROBOT_API_TOKEN= step run_up
    [ "$status" -eq 1 ]
    [[ "$output" == *"DATAROBOT_API_TOKEN is empty"* ]]
    [ ! -e "$work/dr-args" ]
}

@test "run_up writes the plan to the summary and emits the workload id" {
    cp "$CONFIG_DIR/deploy/environments/prod/.datarobot.yaml" "$APP_DIR/.datarobot.yaml"
    MODE=apply step run_up
    [ "$status" -eq 0 ]
    grep -q '### dr workload up (apply, prod, v1.2.3)' "$work/summary"
    grep -q 'plan line one' "$work/summary"
    [ "$(cat "$work/out")" = "workload-id=abc123" ]
}

@test "run_up emits the id that a first deploy writes into the manifest" {
    printf 'name: hermes\n' > "$APP_DIR/.datarobot.yaml"
    MODE=apply STUB_DR_WRITES_ID=1 step run_up
    [ "$status" -eq 0 ]
    [ "$(cat "$work/out")" = "workload-id=fed456" ]
}

@test "run_up returns the exit status of dr after it has written the summary" {
    cp "$CONFIG_DIR/deploy/environments/prod/.datarobot.yaml" "$APP_DIR/.datarobot.yaml"
    MODE=apply STUB_DR_STATUS=3 step run_up
    [ "$status" -eq 3 ]
    grep -q 'plan line one' "$work/summary"
    grep -q 'workload-id=abc123' "$work/out"
}

# --- keep_manifest ------------------------------------------------------------

@test "keep_manifest reports no change when the run left the manifest alone" {
    cp "$CONFIG_DIR/deploy/environments/prod/.datarobot.yaml" "$APP_DIR/.datarobot.yaml"
    step keep_manifest
    [ "$status" -eq 0 ]
    [ "$(cat "$work/out")" = "manifest-changed=false" ]
    [ ! -e "$WORK_DIR/manifest-prod.yaml" ]
    [ ! -s "$work/summary" ]
}

@test "keep_manifest keeps a copy and says to commit it when the run changed the manifest" {
    printf 'name: hermes\n' > "$CONFIG_DIR/deploy/environments/prod/.datarobot.yaml"
    printf 'workloadId: fed456 # managed by the CLI\nname: hermes\n' > "$APP_DIR/.datarobot.yaml"
    step keep_manifest
    [ "$status" -eq 0 ]
    grep -q '^manifest-changed=true$' "$work/out"
    grep -q "^manifest-path=$WORK_DIR/manifest-prod.yaml$" "$work/out"
    grep -q 'workloadId: fed456' "$WORK_DIR/manifest-prod.yaml"
    grep -q 'Commit the `manifest-prod` artifact' "$work/summary"
}
