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
}

@test "Dockerfiles pass hadolint" {
    cd /repo
    run hadolint Dockerfile tests/Dockerfile
    [ "$status" -eq 0 ]
}

@test "YAML and JSON files parse" {
    cd /repo
    for f in config/config.yaml compose.yaml Taskfile.yaml .pre-commit-config.yaml .github/dependabot.yml .github/workflows/*.yml; do
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
    for tool in GO GH GLAB YQ TASK KUBECTL HELM PULUMI; do
        version=$(sed -nE "s/^ARG ${tool}_VERSION=(.+)$/\\1/p" /repo/Dockerfile)
        [ -n "$version" ]
        name=$(echo "$tool" | tr 'A-Z' 'a-z')
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

@test "a pull_request_target workflow never checks out code" {
    workflows=$(grep -l 'pull_request_target' /repo/.github/workflows/*.y*ml)
    [ -n "$workflows" ]
    for workflow in $workflows; do
        run grep -nE '^\s+(- )?uses: actions/checkout' "$workflow"
        [ "$status" -ne 0 ]
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

@test "the upload set stays under the 1000 file limit and holds no secret files" {
    cd /repo
    ignore_file=.drignore
    [ -f "$ignore_file" ] || ignore_file=.wapiignore
    scratch=$(mktemp -d)
    git -C "$scratch" init -q
    cp "$ignore_file" "$scratch/.gitignore"
    git ls-files | git -C "$scratch" check-ignore --no-index --stdin > "$scratch/ignored" || true
    git ls-files | sort > "$scratch/tracked"
    sort "$scratch/ignored" > "$scratch/ignored.sorted"
    comm -23 "$scratch/tracked" "$scratch/ignored.sorted" > "$scratch/upload"
    count=$(wc -l < "$scratch/upload")
    echo "upload set: $count files (limit 1000)"
    [ "$count" -lt 1000 ]
    run grep -nE '(^|/)(\.env(\..*)?|.*\.(pem|key|p12|pfx)|id_rsa|id_ed25519|auth\.json)$' "$scratch/upload"
    [ -z "$(grep -vE '\.env\.(example|template|sample)$' <<< "$output")" ]
}

@test "no secrets in the working tree" {
    cd /repo
    run gitleaks dir . --no-banner --redact
    [ "$status" -eq 0 ]
}

@test "no secrets in the git history" {
    cd /repo
    run gitleaks git . --no-banner --no-color --redact
    [ "$status" -eq 0 ]
    # gitleaks exits 0 after zero commits when git cannot read the repository.
    echo "$output" | grep -Eq '(^|[^0-9])[1-9][0-9]* commits scanned'
}
