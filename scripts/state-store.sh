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

# Gives the workload a dr-sync state store, so its sessions, memories and
# skills survive a restart, and puts the store's id in .env as
# DR_SYNC_CATALOG_ID. `dr start` runs it; `dr run doctor` runs it with --check.
#
# One store per workload, and safe to re-run: the id already in .env, else the
# one .datarobot.yaml declares, is checked against DataRobot and kept. Only
# with neither is a store created, named "<workload name>-state". dr-sync can't
# look a store up by name, and a project without a manifest is a new workload,
# so those two places are what make a re-run reuse the store. An id that
# DataRobot no longer knows stops the run instead of being replaced: the image
# refuses to boot without its state (docker/entrypoint.d/20-state-sync.sh), and
# a new store would mean starting from nothing.
#
# The store is created with `dr-sync init`, from the dr-sync release the
# Dockerfile pins, downloaded for this machine and checked against
# docker/tool-checksums.txt. Nothing is installed. PERSIST_STATE=no in .env
# (the answer to dr start's question) turns all of this off.
#
# Usage: scripts/state-store.sh [--check] [env file, default .env]
#   --check  report only: never create a store or change .env
#
# DR_SYNC_BIN runs that dr-sync instead of downloading one (tests use it).

set -eu

check=
if [ "${1:-}" = --check ]; then
    check=1
    shift
fi
env_file=${1:-.env}
manifest=$(dirname "$env_file")/.datarobot.yaml
root=$(cd "$(dirname "$0")/.." && pwd)

# A rewrite of .env and a dr-sync download both hold something worth not
# leaving behind; whatever was made goes, however the script ends.
tmp=
dl=
trap 'rm -rf "$tmp" "$dl"' EXIT
trap 'exit 130' INT TERM HUP

# The last value .env gives NAME, without the quotes dotenv allows.
env_value() {
    v=$(sed -n "s/^$1=//p" "$env_file" | tail -n 1)
    case $v in
        \"*\") v=${v#\"} v=${v%\"} ;;
        \'*\') v=${v#\'} v=${v%\'} ;;
    esac
    printf '%s' "$v"
}

# The literal value .datarobot.yaml gives NAME, if it has one: the `value:`
# line of its `- name: NAME` entry. A credential reference is not a literal.
manifest_value() {
    [ -f "$manifest" ] || return 0
    awk -v name="$1" '
        function indent(s) { match(s, /^ */); return RLENGTH }
        $0 ~ ("^ *- name: *[\"'\'']?" name "[\"'\'']? *$") { entry = indent($0); inside = 1; next }
        inside && /^ *(#.*)?$/ { next }
        inside && indent($0) <= entry { inside = 0 }
        inside && /^ *value:/ {
            v = $0; sub(/^ *value: */, "", v); gsub(/^["'\'']|["'\'']$/, "", v)
            if (v !~ /^dr-credential:/) print v
            exit
        }
    ' "$manifest"
}

persist=$(env_value PERSIST_STATE)
case $(printf '%s' "$persist" | tr '[:upper:]' '[:lower:]') in
    no | false | 0 | off)
        # The image persists whenever it is given a store id, whatever
        # PERSIST_STATE says, so off holds only once the id is gone too.
        still=
        [ -z "$(env_value DR_SYNC_CATALOG_ID)" ] || still=" $env_file"
        if [ -f "$manifest" ] && grep -qE '^ *- name: *["'"'"']?DR_SYNC_CATALOG_ID["'"'"']? *$' "$manifest"; then
            still="$still .datarobot.yaml"
        fi
        if [ -n "$still" ]; then
            echo "PERSIST_STATE=$persist, but DR_SYNC_CATALOG_ID is still set in$still, so the workload" >&2
            echo "still keeps its state. To turn it off, delete that line from $env_file, then run" >&2
            echo "'dr run env' and 'dr workload up' (docs/ARCHITECTURE.md, \"Turning persistence on\")." >&2
            [ -z "$check" ] || exit 1
            exit 0
        fi
        echo "Persistence is off (PERSIST_STATE=$persist): the workload starts fresh on every restart."
        exit 0
        ;;
esac

endpoint=$(env_value DATAROBOT_ENDPOINT)
token=$(env_value DATAROBOT_API_TOKEN)
endpoint=${endpoint:-${DATAROBOT_ENDPOINT:-}}
token=${token:-${DATAROBOT_API_TOKEN:-}}
while [ "$endpoint" != "${endpoint%/}" ]; do endpoint=${endpoint%/}; done
if [ -z "$endpoint" ] || [ -z "$token" ]; then
    echo "$env_file has no DATAROBOT_ENDPOINT or DATAROBOT_API_TOKEN. Run 'dr start' again." >&2
    exit 1
fi

# The HTTP status DataRobot answers for a store id. The token goes in on
# stdin, not argv, so it never shows up in a process listing.
probe() {
    printf 'Authorization: Bearer %s\n' "$token" |
        curl -sS -o /dev/null -w '%{http_code}' --max-time 20 -H @- \
            "$endpoint/catalogItems/$1/" 2>/dev/null || true
}

# Exits unless DataRobot knows store $1.
verify() {
    code=$(probe "$1")
    case $code in
        200) return 0 ;;
        404 | 410)
            echo "DataRobot has no state store $1 (HTTP $code), the one DR_SYNC_CATALOG_ID $2 names." >&2
            echo "The workload would refuse to boot with it. See docs/TROUBLESHOOTING.md," >&2
            echo "\"State store not found\", to point at the right store or start a new one." >&2
            exit 1
            ;;
        *)
            echo "Could not check state store $1 (HTTP ${code:-none}); nothing was changed." >&2
            exit 1
            ;;
    esac
}

id=$(env_value DR_SYNC_CATALOG_ID)
if [ -n "$id" ]; then
    verify "$id" "in $env_file"
    echo "State store $id (DR_SYNC_CATALOG_ID in $env_file) is in place."
    if [ -n "$check" ] && [ -f "$manifest" ] && [ "$(manifest_value DR_SYNC_CATALOG_ID)" != "$id" ]; then
        echo ".datarobot.yaml doesn't carry it yet, so the workload doesn't persist. Run 'dr run env'." >&2
        exit 1
    fi
    exit 0
fi

# Every write to .env goes through a file only its owner can read, next to
# .env so the swap is a rename: it holds every secret .env does.
set_env_id() {
    tmp=$(mktemp "$(dirname "$env_file")/.env.XXXXXX")
    # Fills an empty DR_SYNC_CATALOG_ID= line if there is one, else appends.
    awk -v id="$1" '
        /^DR_SYNC_CATALOG_ID=/ && !done { print "DR_SYNC_CATALOG_ID=\"" id "\""; done = 1; next }
        { print }
        END {
            if (!done) {
                print ""
                print "# The workload'\''s dr-sync state store, set by dr start. One per workload:"
                print "# never point two running copies at it (docs/ARCHITECTURE.md)."
                print "DR_SYNC_CATALOG_ID=\"" id "\""
            }
        }
    ' "$env_file" > "$tmp"
    # Keep .env's permissions. GNU stat first: BSD stat rejects -c, while
    # GNU's -f is filesystem status, not an error.
    mode=$(stat -c %a "$env_file" 2>/dev/null || stat -f %Lp "$env_file")
    chmod "$mode" "$tmp"
    mv -f "$tmp" "$env_file"
}

id=$(manifest_value DR_SYNC_CATALOG_ID)
if [ -n "$id" ]; then
    verify "$id" "in .datarobot.yaml"
    if [ -n "$check" ]; then
        echo "State store $id is in .datarobot.yaml but not in $env_file. Run 'dr start'." >&2
        exit 1
    fi
    # Into .env too, or the next `dr run env` would drop it from the manifest.
    set_env_id "$id"
    echo "State store $id (from .datarobot.yaml) is in place; added it to $env_file."
    exit 0
fi

# Declared, but not as a literal: most likely dr stored the id as a credential.
# Its value can't be read back here, and creating a store now would make a
# second one for the same workload.
if [ -f "$manifest" ] && grep -qE '^ *- name: *["'"'"']?DR_SYNC_CATALOG_ID["'"'"']? *$' "$manifest"; then
    echo ".datarobot.yaml declares DR_SYNC_CATALOG_ID, but not as a plain value this can read." >&2
    echo "Put the store's id in $env_file as DR_SYNC_CATALOG_ID and run this again." >&2
    exit 1
fi

if [ -n "$check" ]; then
    echo "No state store yet: the workload starts fresh on every restart. Run 'dr start'." >&2
    exit 1
fi

# dr-sync for this machine: DR_SYNC_BIN, else the release the Dockerfile pins.
fetch_dr_sync() {
    if [ -n "${DR_SYNC_BIN:-}" ]; then
        bin=$DR_SYNC_BIN
        return
    fi
    version=$(sed -nE 's/^ARG DR_SYNC_VERSION=(.+)$/\1/p' "$root/Dockerfile")
    case $(uname -s) in
        Darwin) os=darwin ;;
        Linux) os=linux ;;
        *) echo "No dr-sync release for $(uname -s)." >&2; exit 1 ;;
    esac
    case $(uname -m) in
        x86_64 | amd64) arch=amd64 ;;
        arm64 | aarch64) arch=arm64 ;;
        *) echo "No dr-sync release for $(uname -m)." >&2; exit 1 ;;
    esac
    # The linux keys are the ones the Dockerfile's own download uses.
    key="dr-sync-$version-$arch"
    [ "$os" = linux ] || key="dr-sync-$version-$os-$arch"
    sum=$(sed -nE "s/^([0-9a-f]{64})  $key\$/\\1/p" "$root/docker/tool-checksums.txt")
    if [ -z "$version" ] || [ -z "$sum" ]; then
        echo "docker/tool-checksums.txt has no checksum for $key." >&2
        exit 1
    fi
    dl=$(mktemp -d)
    url="https://github.com/datarobot-labs/datarobot-sync/releases/download/v$version/dr-sync_${version}_${os}_$arch.tar.gz"
    echo "Downloading dr-sync $version to create the state store."
    curl -fsSL -o "$dl/dr-sync.tar.gz" "$url"
    got=$( (sha256sum "$dl/dr-sync.tar.gz" 2>/dev/null || shasum -a 256 "$dl/dr-sync.tar.gz") | cut -d' ' -f1)
    if [ "$got" != "$sum" ]; then
        echo "dr-sync download doesn't match its checksum in docker/tool-checksums.txt; not running it." >&2
        exit 1
    fi
    tar -xzf "$dl/dr-sync.tar.gz" -C "$dl" dr-sync
    bin=$dl/dr-sync
}

name=$(sed -nE 's/^name: *["'\'']?([^"'\'' #]+).*$/\1/p' "$manifest" 2>/dev/null | head -n 1)
name=${name:-${WORKLOAD_NAME:-hermes-agent}}

fetch_dr_sync
# The token reaches dr-sync through its environment, never its arguments.
id=$(DATAROBOT_ENDPOINT=$endpoint DATAROBOT_API_TOKEN=$token \
    "$bin" init --name "$name-state" --tag hermes_state)
if ! printf '%s' "$id" | grep -qE '^[0-9a-f]{24}$'; then
    echo "dr-sync init didn't print a store id; nothing was written to $env_file." >&2
    exit 1
fi
set_env_id "$id"
echo "Created state store $id (\"$name-state\") and set DR_SYNC_CATALOG_ID in $env_file."
