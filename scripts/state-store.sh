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

# Gives the workload a dr-sync state store, so its sessions and memory
# survive a restart, and puts the store's id in .env as
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
# The store is created with `dr sync init`: the dr-sync plugin, which dr start
# installs from .datarobot/cli/versions.yaml, run with dr's own login.
#
# Usage: scripts/state-store.sh [--check] [env file, default .env]
#   --check  report only: never create a store or change .env

set -eu

check=
if [ "${1:-}" = --check ]; then
    check=1
    shift
fi
env_file=${1:-.env}
manifest=$(dirname "$env_file")/.datarobot.yaml

# A rewrite of .env holds every secret .env does; it goes, however the
# script ends.
tmp=
trap 'rm -f "$tmp"' EXIT
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
        $0 ~ ("^ *- name: *[\"'\'']?" name "[\"'\'']? *(#.*)?$") { entry = indent($0); inside = 1; next }
        inside && /^ *(#.*)?$/ { next }
        inside && indent($0) <= entry { inside = 0 }
        inside && /^ *value:/ {
            v = $0; sub(/^ *value: */, "", v); sub(/[ \t]+#.*$/, "", v); gsub(/^["'\'']|["'\'']$/, "", v)
            if (v !~ /^dr-credential:/) print v
            exit
        }
    ' "$manifest"
}

# Whether .datarobot.yaml mentions NAME anywhere outside a comment. It's broader
# than manifest_value on purpose: a flow mapping (`- {name: NAME, ...}`) or an
# entry with `value:` before `name:` is still the workload's declaration, which
# this mustn't mistake for none and so make a second store.
manifest_mentions() {
    [ -f "$manifest" ] &&
        grep -v '^ *#' "$manifest" | grep -qE "(^|[^A-Za-z0-9_])$1([^A-Za-z0-9_]|\$)"
}

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

# Exits unless DataRobot knows store $1. Its shape is checked first, without
# printing it: a value that isn't an id may be a secret pasted into the wrong
# line, which must reach neither the terminal nor a request URL.
verify() {
    if ! printf '%s' "$1" | grep -qE '^[0-9a-f]{24}$'; then
        echo "DR_SYNC_CATALOG_ID $2 isn't a store id: dr-sync prints 24 lowercase hex" >&2
        echo "characters. Nothing was changed." >&2
        exit 1
    fi
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
    if [ -f "$manifest" ] && [ "$(manifest_value DR_SYNC_CATALOG_ID)" != "$id" ]; then
        if [ -n "$check" ]; then
            echo ".datarobot.yaml doesn't carry it yet, so the workload doesn't persist. Run 'dr run env'." >&2
            exit 1
        fi
        # Not declared at all, dr start's own manifest step names it. Declared
        # as another store, nothing else would say so, and the next deploy
        # would use that one: deleted, the workload can't boot.
        if manifest_mentions DR_SYNC_CATALOG_ID; then
            echo ".datarobot.yaml names a different state store than $env_file, and the next" >&2
            echo "deploy uses the manifest's. Run 'dr run env' before you deploy." >&2
        fi
    fi
    exit 0
fi

# Every write to .env goes through a file only its owner can read, next to
# .env so the swap is a rename: it holds every secret .env does.
set_env_id() {
    tmp=$(mktemp "$(dirname "$env_file")/.env.XXXXXX")
    # One DR_SYNC_CATALOG_ID line, where the first one was, or appended. Later
    # ones go: env_value reads the last, so a leftover empty one would hide
    # the id and make the next run create yet another store.
    awk -v id="$1" '
        /^DR_SYNC_CATALOG_ID=/ { if (!done) print "DR_SYNC_CATALOG_ID=\"" id "\""; done = 1; next }
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

# Declared, but not as a literal this reads: most likely dr stored the id as a
# credential, or the entry is in another YAML layout. Its value can't be read
# back here, and creating a store now would make a second one for the same
# workload.
if manifest_mentions DR_SYNC_CATALOG_ID; then
    echo ".datarobot.yaml declares DR_SYNC_CATALOG_ID, but not as a plain value this can read" >&2
    echo "(a '- name:' entry with a 'value:' line)." >&2
    echo "Put the store's id in $env_file as DR_SYNC_CATALOG_ID and run this again." >&2
    exit 1
fi

if [ -n "$check" ]; then
    echo "No state store yet: the workload starts fresh on every restart. Run 'dr start'." >&2
    exit 1
fi

name=$(sed -nE 's/^name: *["'\'']?([^"'\'' #]+).*$/\1/p' "$manifest" 2>/dev/null | head -n 1)
name=${name:-${WORKLOAD_NAME:-hermes-agent}}

id=$(dr sync init --name "$name-state" --tag hermes_state)
if ! printf '%s' "$id" | grep -qE '^[0-9a-f]{24}$'; then
    echo "dr sync init didn't print a store id; nothing was written to $env_file." >&2
    exit 1
fi
set_env_id "$id"
echo "Created state store $id (\"$name-state\") and set DR_SYNC_CATALOG_ID in $env_file."
