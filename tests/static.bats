#!/usr/bin/env bats
# Checks that need no running container: linters, file formats, the pinned
# base image, what `dr workload up` would upload, and a secret scan.

DIGEST_PATTERN='hermes-agent:latest@sha256:[0-9a-f]{64}'

setup_file() {
    git config --global --add safe.directory /repo
}

@test "entrypoint passes shellcheck" {
    run shellcheck -s sh -S warning /repo/docker/entrypoint.sh
    [ "$status" -eq 0 ]
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
    for f in LICENSE AUTHORS CONTRIBUTING.md CODE_OF_CONDUCT.md SECURITY.md .github/PULL_REQUEST_TEMPLATE.md .github/dependabot.yml .pre-commit-config.yaml; do
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
    unpinned=$(grep -hE '^\s+(- )?uses: [^./][^ ]+@' /repo/.github/workflows/*.yml | grep -vE '@[0-9a-f]{40}( |$)' || true)
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
