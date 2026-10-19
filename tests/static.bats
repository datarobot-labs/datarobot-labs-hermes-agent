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

# Checks that need no running container: linters, file formats, the pinned
# base image, what `dr workload up` would upload, and a secret scan.

DIGEST_PATTERN='hermes-agent:latest@sha256:[0-9a-f]{64}'

setup_file() {
    git config --global --add safe.directory /repo
}

# upload_set FILE: writes to FILE what `dr workload up` would upload, one path
# per line. That is every file in the working tree, tracked or not, minus what
# .drignore excludes. dr reads only that file, so a gitignored file such as
# .datarobot.yaml is uploaded unless it is listed there.
upload_set() {
    local scratch
    scratch=$(mktemp -d)
    git -C "$scratch" init -q
    cp .drignore "$scratch/.gitignore"
    find . -path ./.git -prune -o -type f -print | sed 's|^\./||' | sort > "$scratch/all"
    git -C "$scratch" check-ignore --no-index --stdin < "$scratch/all" | sort > "$scratch/ignored" || true
    comm -23 "$scratch/all" "$scratch/ignored" > "$1"
}

@test "entrypoint and its snippets pass shellcheck" {
    run shellcheck -s sh -S warning -x -a -P SCRIPTDIR /repo/docker/entrypoint.sh
    [ "$status" -eq 0 ]
}

@test "the Dockerfile copies the entrypoint snippets and every sourced file exists" {
    run grep -Eq '^COPY +docker/entrypoint\.d/ +/opt/hermes-workload/entrypoint\.d/$' /repo/Dockerfile
    [ "$status" -eq 0 ]
    names=$(sed -n 's|^\. "\$ENTRYPOINT_DIR/\(.*\)"$|\1|p' /repo/docker/entrypoint.sh)
    [ -n "$names" ]
    for name in $names; do
        [ -f "/repo/docker/entrypoint.d/$name" ]
    done
}

@test "test scripts and stubs pass shellcheck" {
    run shellcheck -s bash -S warning /repo/tests/run.sh
    [ "$status" -eq 0 ]
    run shellcheck -s sh -S warning /repo/tests/fixtures/opt/stubs/*
    [ "$status" -eq 0 ]
    run shellcheck -s sh -S warning /repo/tests/smoke.sh
    [ "$status" -eq 0 ]
}

@test "the repo's own scripts pass shellcheck" {
    run shellcheck -s sh -S warning /repo/scripts/*.sh
    [ "$status" -eq 0 ]
}

@test "Dockerfiles pass hadolint" {
    cd /repo
    run hadolint Dockerfile tests/Dockerfile
    [ "$status" -eq 0 ]
}

@test "YAML and JSON files parse" {
    cd /repo
    for f in config/config.yaml compose.yaml Taskfile.yaml .pre-commit-config.yaml .github/dependabot.yml .github/workflows/*.yml .github/zizmor.yml .gitlab-ci.yml \
            .datarobot/cli/versions.yaml .datarobot/cli/prompts.yaml; do
        python3 -c 'import sys, yaml; yaml.safe_load(open(sys.argv[1]))' "$f"
    done
    python3 -m json.tool config/slack-manifest.json > /dev/null
}

@test "the open source files from the policy are present and filled in" {
    cd /repo
    for f in LICENSE NOTICE .env.example AUTHORS CONTRIBUTING.md CODE_OF_CONDUCT.md SECURITY.md .github/PULL_REQUEST_TEMPLATE.md .github/dependabot.yml .pre-commit-config.yaml; do
        [ -s "$f" ]
    done
    grep -q 'Apache License' LICENSE
    grep -q 'Copyright 20[0-9][0-9] DataRobot' LICENSE
    run grep -nE '\[yyyy\]|Your Name|Your GitHub User URL' LICENSE CONTRIBUTING.md
    [ "$status" -ne 0 ]
    grep -qE '^[^#].*<.+@.+>' AUTHORS
    grep -q 'This repository is public' .github/PULL_REQUEST_TEMPLATE.md
    run grep -nE '^\* \?$' .github/CODEOWNERS
    [ "$status" -ne 0 ]
}

@test "every Python requirement is pinned to an exact version" {
    run grep -nE '^[A-Za-z0-9_.-]+([<>~!].*)?$' /repo/config/requirements.txt
    [ "$status" -ne 0 ]
}

@test "third-party actions are pinned to a commit SHA" {
    run grep -rnE '^\s+(- )?uses: [^./][^ ]+@[^ ]+' /repo/.github/workflows
    [ "$status" -eq 0 ]
    unpinned=$(grep -hE '^\s+(- )?uses: [^./][^ ]+@' /repo/.github/workflows/*.y*ml | grep -vE '@[0-9a-f]{40}( |$)' || true)
    [ -z "$unpinned" ]
}

@test "the image workflow builds every change that reaches the image" {
    run python3 - /repo/.github/workflows/image.yml <<'PY'
import sys, yaml
workflow = yaml.safe_load(open(sys.argv[1]))
on = workflow.get("on", workflow.get(True))  # YAML 1.1 reads a bare `on` as true
for event in ("pull_request", "push"):
    missing = {"Dockerfile", ".dockerignore", "docker/**", "config/**", "Taskfile.yaml"} - set(on[event]["paths"])
    assert not missing, f"{event} does not trigger on {sorted(missing)}"
assert "schedule" in on, "no scheduled build"
PY
    [ "$status" -eq 0 ]
}

@test "the base image is pinned by digest" {
    run grep -Ec "^FROM nousresearch/${DIGEST_PATTERN}( |\$)" /repo/Dockerfile
    [ "$output" = 1 ]
}

@test "the dr CLI installer and version are pinned" {
    grep -qE '^ARG DR_CLI_VERSION=v[0-9]+\.[0-9]+\.[0-9]+$' /repo/Dockerfile
    grep -qE '^ARG DR_CLI_INSTALLER_REF=[0-9a-f]{40}$' /repo/Dockerfile
    run grep -nE 'DR_CLI_VERSION=latest|datarobot-oss/cli/(main|master)/' /repo/Dockerfile
    [ "$status" -ne 0 ]
}

@test "every pinned build tool has a checksum for both architectures" {
    for tool in GO GH GLAB YQ TASK KUBECTL HELM PULUMI DR_SYNC; do
        version=$(sed -nE "s/^ARG ${tool}_VERSION=(.+)$/\\1/p" /repo/Dockerfile)
        [ -n "$version" ]
        name=$(echo "$tool" | tr 'A-Z_' 'a-z-')
        for arch in amd64 arm64; do
            grep -qE "^[0-9a-f]{64}  ${name}-${version}-${arch}$" /repo/docker/tool-checksums.txt
        done
    done
}

@test "the web UI is fetched by commit" {
    grep -qE '^ARG HERMES_WEBUI_REF=[0-9a-f]{40}$' /repo/Dockerfile
}

@test "the OTel plugin is installed by commit" {
    grep -qE '^ARG HERMES_OTEL_REF=[0-9a-f]{40}$' /repo/Dockerfile
}

@test "dr-sync never restores a file the image seed owns" {
    # Every COPY into the seed, plus the seed paths that are not a COPY: the plugin
    # install, the rendered OTel config and the optional browser-use install.
    expected=$(grep -cE '^COPY .*HERMES_SEED' /repo/Dockerfile)
    copied=$(grep '^COPY ' /repo/Dockerfile | grep -oE '\$\{HERMES_SEED\}/[^ ]+$' | sed 's|^\${HERMES_SEED}||')
    set -- $copied
    [ "$#" -gt 0 ]
    [ "$#" -eq "$expected" ] || { echo "parsed $# of $expected COPY lines into the seed"; return 1; }
    for path in "$@" /plugins/ /hermes_otel.yaml /bin/ /.local/share/uv/tools/; do
        grep -qxF "$path" /repo/config/.drsyncignore || { echo "not in .drsyncignore: $path"; return 1; }
    done
}

@test "every workflow declares its permissions" {
    run grep -L '^permissions:' /repo/.github/workflows/*.y*ml
    [ -z "$output" ]
}

@test "a pull_request_target workflow never checks out code or runs a shell step" {
    # Either one can execute the pull request's code with the target workflow's token and secrets.
    workflows=$(grep -l 'pull_request_target' /repo/.github/workflows/*.y*ml)
    [ -n "$workflows" ]
    for workflow in $workflows; do
        run grep -nE '^\s+(- )?(uses: actions/checkout|run:)' "$workflow"
        [ "$status" -ne 0 ] || { echo "$workflow: $output"; return 1; }
    done
}

@test "no AGPL-licensed Python package is installed" {
    run grep -niE '^(pymupdf|pymupdf4llm|fitz)==' /repo/config/requirements.txt
    [ "$status" -ne 0 ]
}

@test "no vendored skill duplicates one the base image bundles" {
    # Hermes syncs its bundled skills into HERMES_HOME at boot; a seeded copy
    # goes stale, and a manifest entry without a skill reads as user-deleted.
    [ ! -e /repo/config/skills/.bundled_manifest ]
    [ ! -d /repo/config/skills/productivity/pdf ]
}

@test ".env.example lists the variables and holds no values for secrets" {
    cd /repo
    git check-ignore -q .env
    run git check-ignore -q .env.example
    [ "$status" -ne 0 ]
    for var in LLM_API_KEY SLACK_BOT_TOKEN SLACK_APP_TOKEN DR_SYNC_CATALOG_ID; do
        grep -qE "^#? ?${var}=$" .env.example
    done
    run grep -nE '^#? ?[A-Z_]*(KEY|TOKEN)=.+$' .env.example
    [ "$status" -ne 0 ]
}

@test "the README states the project status and the Nous Research disclaimer" {
    grep -q 'Experimental and community maintained' /repo/README.md
    grep -q 'not affiliated with or endorsed by Nous Research' /repo/README.md
}

@test "the default persona carries no team branding" {
    run grep -niE 'solutions labs|whimsical' /repo/config/SOUL.md
    [ "$status" -ne 0 ]
}

# config/skills/datarobot/ is vendored from datarobot-agent-skills, where the same headers
# ("... All rights reserved." next to SPDX Apache-2.0) are already public and were reviewed.
@test "no file claims all rights reserved or needs an internal license" {
    cd /repo
    run git grep -nI 'All rights reserved' -- . ':!LICENSE' ':!tests/static.bats' ':!config/skills/datarobot'
    [ "$status" -ne 0 ]
}

@test "compose publishes the gateway port on loopback only" {
    grep -qE '"127\.0\.0\.1:8642:8642"' /repo/compose.yaml
    run grep -nE '^\s+- "8642:8642"' /repo/compose.yaml
    [ "$status" -ne 0 ]
}

@test "the Taskfile shell-quotes the checkout path wherever it uses it" {
    # Double quotes still run a $(...) that a checkout path like
    # /tmp/repo$(cmd) brings into the command line; only shellQuote doesn't.
    run grep -nE '\.ROOT_DIR' /repo/Taskfile.yaml
    [ "$status" -eq 0 ]
    run grep -nE '\.ROOT_DIR' /repo/Taskfile.yaml
    [ -z "$(grep -v 'shellQuote (print \.ROOT_DIR' <<< "$output")" ]
}

@test "the Taskfile and README use the same digest as the Dockerfile" {
    expected=$(grep -oE "$DIGEST_PATTERN" /repo/Dockerfile | sort -u)
    [ -n "$expected" ]
    for f in /repo/Taskfile.yaml /repo/README.md; do
        found=$(grep -oE "$DIGEST_PATTERN" "$f" | sort -u)
        [ "$found" = "$expected" ]
    done
    # No hermes-agent image reference may float.
    run grep -nE 'nousresearch/hermes-agent(:latest)?( |$)' /repo/Taskfile.yaml /repo/README.md
    [ "$status" -ne 0 ]
}

@test "Hermes' runtime state from a skill install is neither committed nor uploaded" {
    cd /repo
    paths='config/skills/.usage.json
config/skills/.usage.json.lock
config/skills/.hub/audit.log
config/skills/.hub/index-cache/x
config/skills/.hub/quarantine/x
config/skills/.hub/scan-cache/x'
    # git: every one ignored.
    run git check-ignore --no-index --stdin <<< "$paths"
    [ "$(echo "$output" | grep -c .)" = 6 ]
    # dr workload up reads .drignore alone.
    scratch=$(mktemp -d)
    git -C "$scratch" init -q
    cp .drignore "$scratch/.gitignore"
    run git -C "$scratch" check-ignore --no-index --stdin <<< "$paths"
    [ "$(echo "$output" | grep -c .)" = 6 ]
    # What an install should leave to commit is not ignored by either.
    ! git check-ignore -q --no-index config/skills/.hub/lock.json
    ! git -C "$scratch" check-ignore -q --no-index config/skills/.hub/lock.json
}

@test "the upload set stays under the 1000 file limit and holds no secret files" {
    cd /repo
    scratch=$(mktemp -d)
    upload_set "$scratch/upload"
    count=$(wc -l < "$scratch/upload")
    echo "upload set: $count files (limit 1000)"
    [ "$count" -lt 1000 ]
    # Everything under config/skills/ goes up, since the server-side build
    # copies all of it, including skills' own scripts/ and tests/ folders.
    missing=$(git ls-files config/skills | sort | comm -23 - "$scratch/upload")
    [ -z "$missing" ] || { echo "not uploaded: $missing"; false; }
    # The repo's own docs, tests and helper scripts don't.
    run grep -nE '^(docs|tests|scripts)/' "$scratch/upload"
    [ "$status" -ne 0 ]
    run grep -nE '(^|/)(\.env(\..*)?|.*\.(pem|key|p12|pfx)|id_rsa|id_ed25519|auth\.json)$' "$scratch/upload"
    [ -z "$(grep -vE '\.env\.(example|template|sample)$' <<< "$output")" ]
}

@test "no secrets in what git would commit or dr workload up would upload" {
    # Not the working tree as is: `dr start` puts real tokens in the .env of
    # every clone, which neither git nor dr takes. Everything either of them
    # does take is scanned, gitignored files that dr uploads included.
    #
    # Two snapshots, since they can differ: the index, as the bytes the next
    # commit records (a secret staged, then removed from the file, is still
    # in it), and the working-tree files dr uploads or git would add, tracked
    # ones included (an unstaged edit reaches the next `git commit -a`).
    cd /repo
    scratch=$(mktemp -d)
    mkdir -p "$scratch/scan/index" "$scratch/scan/tree"
    git checkout-index --all --prefix="$scratch/scan/index/"
    upload_set "$scratch/upload"
    { git ls-files; git ls-files --others --exclude-standard; cat "$scratch/upload"; } |
        sort -u | tr '\n' '\0' |
        tar --null --files-from=- --ignore-failed-read -cf - 2>/dev/null |
        tar -xf - -C "$scratch/scan/tree"
    run gitleaks dir "$scratch/scan" --no-banner --redact
    [ "$status" -eq 0 ]
}

@test "no secrets in the git history" {
    cd /repo
    run gitleaks git . --no-banner --no-color --redact
    [ "$status" -eq 0 ]
    # gitleaks exits 0 after zero commits when git cannot read the repository.
    echo "$output" | grep -Eq '(^|[^0-9])[1-9][0-9]* commits scanned'
}

@test "the upload exclusions live in .drignore, the name dr v0.14.1 reads without a warning" {
    cd /repo
    [ -f .drignore ]
    [ ! -e .wapiignore ]
}

@test "the deploy and env tasks refuse a dr older than the minimum" {
    run awk '
        /^  [a-z_:*-]+:$/ { task = $1 }
        /scripts\/check-dr-version.sh/ { seen[task] = 1 }
        END { exit !(seen["deploy:"] && seen["env:"]) }
    ' /repo/Taskfile.yaml
    [ "$status" -eq 0 ]
}

@test "deploy and doctor check for PLACEHOLDER credentials with the shared script only" {
    run awk '
        /^  [a-z_:*-]+:$/ { task = $1 }
        /scripts\/check-credentials.sh/ { seen[task] = 1 }
        END { exit !(seen["deploy:"] && seen["doctor:"]) }
    ' /repo/Taskfile.yaml
    [ "$status" -eq 0 ]
    run grep -n 'grep -q PLACEHOLDER' /repo/Taskfile.yaml
    [ "$status" -ne 0 ]
}

@test "git ignores the deploy manifest and the upload record, and tracks dr start's setup" {
    scratch=$(mktemp -d)
    git -C "$scratch" init -q
    cp /repo/.gitignore "$scratch/.gitignore"

    run git -C "$scratch" check-ignore --no-index .datarobot.yaml .datarobot/workload/manifest.json
    [ "$status" -eq 0 ]
    [ "${#lines[@]}" -eq 2 ]

    run git -C "$scratch" check-ignore --no-index .datarobot/cli/prompts.yaml .datarobot/cli/versions.yaml
    [ "$status" -eq 1 ]
}

@test "the deploy job runs only from main, so a dispatch from a branch cannot deploy" {
    run grep -F "github.ref == 'refs/heads/main'" /repo/.github/workflows/deploy.yml
    [ "$status" -eq 0 ]
}

@test "the deploy job runs in the datarobot environment, which holds the credentials" {
    run grep -E "^    environment: datarobot\$" /repo/.github/workflows/deploy.yml
    [ "$status" -eq 0 ]
}

@test "the deploy workflow checks the workload's own API key before it deploys" {
    check=$(grep -n 'scripts/workload-config.sh --check' /repo/.github/workflows/deploy.yml | head -n 1 | cut -d: -f1)
    deploy=$(grep -n 'uses: datarobot-oss/workload-deploy-github@' /repo/.github/workflows/deploy.yml | head -n 1 | cut -d: -f1)
    [ -n "$check" ]
    [ -n "$deploy" ]
    [ "$check" -lt "$deploy" ]
}

@test "the GitLab deploy jobs start no job unless DEPLOY_TO_DATAROBOT is true on the default branch" {
    run python3 - /repo/.gitlab-ci.yml <<'PY'
import sys, yaml
pipeline = yaml.safe_load(open(sys.argv[1]))
inputs = pipeline["include"][0]["inputs"]
rules = list(inputs["rules"]) + list(inputs["stop_rules"])
# The sync job has its own gate, which tests/sync-from-github.bats checks.
jobs = {name: job for name, job in pipeline.items() if name not in ("stages", "include", "sync-from-github")}
assert jobs, "no job of its own to gate"
for name, job in jobs.items():
    assert job.get("rules"), f"{name} has no rules, so it runs on every pipeline"
    rules += job["rules"]
for rule in rules:
    condition = rule.get("if", "")
    for needed in ('$DEPLOY_TO_DATAROBOT == "true"', "$CI_COMMIT_BRANCH == $CI_DEFAULT_BRANCH"):
        assert needed in condition, f"rule {rule} lacks {needed}"
PY
    [ "$status" -eq 0 ]
}

@test "the GitLab pipeline pins the deploy component to a full commit SHA" {
    run grep -E '^  - component: .*/datarobot-oss/workload-deploy/deploy@[0-9a-f]{40}$' /repo/.gitlab-ci.yml
    [ "$status" -eq 0 ]
}

@test "the workflow lint runs zizmor and actionlint from images pinned by digest, through the task" {
    run grep -E '^      ZIZMOR: ghcr\.io/zizmorcore/zizmor@sha256:[0-9a-f]{64}$' /repo/Taskfile.yaml
    [ "$status" -eq 0 ]
    run grep -E '^      ACTIONLINT: rhysd/actionlint@sha256:[0-9a-f]{64}$' /repo/Taskfile.yaml
    [ "$status" -eq 0 ]
    run grep -F 'run: task lint:workflows' /repo/.github/workflows/workflow-lint.yml
    [ "$status" -eq 0 ]
    # The token enables zizmor's online audits, which found a wrong version comment the offline run missed.
    run grep -F 'GH_TOKEN: ${{ github.token }}' /repo/.github/workflows/workflow-lint.yml
    [ "$status" -eq 0 ]
}

@test "the link check runs lychee from an image pinned by digest, through the task, and skips the synced skills" {
    run grep -E '^      LYCHEE: lycheeverse/lychee@sha256:[0-9a-f]{64}$' /repo/Taskfile.yaml
    [ "$status" -eq 0 ]
    run grep -F -e '--exclude-path config/skills' /repo/Taskfile.yaml
    [ "$status" -eq 0 ]
    run grep -F 'run: task lint:links' /repo/.github/workflows/link-check.yml
    [ "$status" -eq 0 ]
    # The token lifts the GitHub API rate limit for github.com links.
    run grep -F 'GITHUB_TOKEN: ${{ github.token }}' /repo/.github/workflows/link-check.yml
    [ "$status" -eq 0 ]
}

@test "the link check reads hidden directories, so the Markdown under .github is checked" {
    run grep -F -e '--hidden' /repo/Taskfile.yaml
    [ "$status" -eq 0 ]
}

@test "every .lycheeignore entry matches one whole URL, not a prefix" {
    entries=$(grep -vE '^\s*(#|$)' /repo/.lycheeignore)
    [ -n "$entries" ]
    unanchored=$(printf '%s\n' "$entries" | grep -vE '^\^.*\$$' || true)
    [ -z "$unanchored" ]
}

@test "every Dependabot ecosystem waits at least a week for a release to age" {
    run python3 - /repo/.github/dependabot.yml <<'PY'
import sys, yaml
for update in yaml.safe_load(open(sys.argv[1]))["updates"]:
    days = update.get("cooldown", {}).get("default-days", 0)
    assert days >= 7, f"{update['package-ecosystem']} {update['directory']} waits {days} days"
PY
    [ "$status" -eq 0 ]
}

@test "the zizmor ignores name only the shared Review Router workflow" {
    run python3 - /repo/.github/zizmor.yml <<'PY'
import sys, yaml
rules = yaml.safe_load(open(sys.argv[1]))["rules"]
assert rules, "no ignores, so this file is not needed"
for rule, settings in rules.items():
    assert settings["ignore"] == ["review-router.yml"], f"{rule} ignores {settings['ignore']}"
PY
    [ "$status" -eq 0 ]
}

@test "the GitLab pipeline pins the image of every job by digest" {
    run python3 - /repo/.gitlab-ci.yml <<'PY'
import re, sys, yaml
pipeline = yaml.safe_load(open(sys.argv[1]))
images = {"deploy and stop jobs": pipeline["include"][0]["inputs"]["image"]}
images.update({name: job["image"] for name, job in pipeline.items() if isinstance(job, dict) and "image" in job})
assert len(images) > 1, "no job of its own to check"
for name, image in images.items():
    assert re.search(r"@sha256:[0-9a-f]{64}$", image), f"{name} runs {image}, which a tag can move"
PY
    [ "$status" -eq 0 ]
}

@test "the GitLab pipeline checks the manifest in a stage before the deploy stage" {
    run python3 - /repo/.gitlab-ci.yml <<'PY'
import sys, yaml
pipeline = yaml.safe_load(open(sys.argv[1]))
stages = pipeline["stages"]
assert stages.index(pipeline["check-manifest"]["stage"]) < stages.index("deploy"), stages
PY
    [ "$status" -eq 0 ]
}

@test "the dr pinned in the image is at least the minimum that dr start enforces" {
    min=$(awk '/^dr:/ { found = 1; next } found && /^[^[:space:]#]/ { exit } found && /minimum-version:/ { print $2; exit }' /repo/.datarobot/cli/versions.yaml)
    pin=$(sed -nE 's/^ARG DR_CLI_VERSION=v([0-9.]+)$/\1/p' /repo/Dockerfile)
    [ -n "$min" ]
    [ -n "$pin" ]
    [ "$(printf '%s\n%s\n' "$min" "$pin" | sort -V | head -n 1)" = "$min" ]
}
