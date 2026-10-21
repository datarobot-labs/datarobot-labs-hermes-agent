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
# One store per workload, and safe to re-run: the id already in .env is checked
# with `dr sync inspect` and kept. Only without one is a store created, named
# "<workload name>-state". An id DataRobot doesn't have stops the run instead of
# being replaced: the image refuses to boot without its state
# (docker/entrypoint.d/20-state-sync.sh), and a new store would mean starting
# from nothing. For the same reason, so does a .datarobot.yaml that already
# names a store while .env doesn't: that is a deployed workload whose .env lost
# the id, not a new one. dr-sync can't look a store up by name.
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

# The last value .env gives NAME, without the quotes dotenv allows.
env_value() {
    v=$(sed -n "s/^$1=//p" "$env_file" | tail -n 1)
    case $v in
        \"*\") v=${v#\"} v=${v%\"} ;;
        \'*\') v=${v#\'} v=${v%\'} ;;
    esac
    printf '%s' "$v"
}

# Whether .datarobot.yaml names the store's variable at all. Only the name:
# dr keeps the id as a credential, which can't be read back here.
manifest_names_store() {
    [ -f "$manifest" ] && grep -qw DR_SYNC_CATALOG_ID "$manifest"
}

# Whether $1 is a store id: the 24 lowercase hex characters dr-sync prints.
is_store_id() {
    case $1 in *[!0-9a-f]* | '') return 1 ;; esac
    [ ${#1} -eq 24 ]
}

# Exits unless DataRobot knows store $1, asked through `dr sync inspect` with
# dr's own login. Its shape is checked first, without printing it: a value
# that isn't an id may be a secret pasted into the wrong line, which must
# reach neither the terminal nor a request.
verify() {
    if ! is_store_id "$1"; then
        echo "DR_SYNC_CATALOG_ID $2 isn't a store id: dr-sync prints 24 lowercase hex" >&2
        echo "characters. Nothing was changed." >&2
        exit 1
    fi
    if ! DR_SYNC_CATALOG_ID=$1 dr sync inspect > /dev/null; then
        echo "DataRobot can't give state store $1, the one DR_SYNC_CATALOG_ID $2 names" >&2
        echo "(dr sync says why, above). A missing store keeps the workload from booting." >&2
        echo "See docs/TROUBLESHOOTING.md, \"State store not found\". Nothing was changed." >&2
        exit 1
    fi
}

id=$(env_value DR_SYNC_CATALOG_ID)
if [ -n "$id" ]; then
    verify "$id" "in $env_file"
    echo "State store $id (DR_SYNC_CATALOG_ID in $env_file) is in place."
    if [ -n "$check" ] && [ -f "$manifest" ] && ! manifest_names_store; then
        echo ".datarobot.yaml doesn't carry it yet, so the workload doesn't persist. Run 'dr run env'." >&2
        exit 1
    fi
    exit 0
fi

if manifest_names_store; then
    echo ".datarobot.yaml already gives the workload a state store, but $env_file has no" >&2
    echo "DR_SYNC_CATALOG_ID, and a new store would start from nothing. Put that store's" >&2
    echo "id in $env_file (docs/TROUBLESHOOTING.md, \"State store not found\") and run this again." >&2
    exit 1
fi

if [ -n "$check" ]; then
    echo "No state store yet: the workload starts fresh on every restart. Run 'dr start'." >&2
    exit 1
fi

# The name dr start's manifest step gives the workload.
name=${WORKLOAD_NAME:-hermes-agent}

# dr prints its own "Running plugin" line on stdout first: the id is the last.
id=$(dr sync init --name "$name-state" --tag hermes_state)
id=$(printf '%s\n' "$id" | tail -n 1)
if ! is_store_id "$id"; then
    echo "dr sync init didn't print a store id; nothing was written to $env_file." >&2
    exit 1
fi
# Appended, so .env keeps its permissions: it holds the deployer's token.
# A leftover empty DR_SYNC_CATALOG_ID line can stay; the last one wins, for
# dr, docker compose and env_value alike.
printf '\n# The workload'"'"'s dr-sync state store, made by dr start. One per workload:\n# never point two running copies at it (docs/ARCHITECTURE.md).\nDR_SYNC_CATALOG_ID="%s"\n' "$id" >> "$env_file"
echo "Created state store $id (\"$name-state\") and set DR_SYNC_CATALOG_ID in $env_file."
