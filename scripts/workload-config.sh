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

# Runs `dr workload config` with the given arguments, but keeps the deploying
# user's DATAROBOT_API_TOKEN out of the workload.
#
# `dr dotenv setup` writes the token of whoever is logged in to ./.env, and
# `dr workload config` turns every name in ./.env into a workload variable, so
# left alone the agent would run with that person's long-lived token. The
# workload gets a key of its own instead: the manifest declares
# DATAROBOT_API_TOKEN with `source: api-key`, which the platform fills in.
#
# dr can't be told to skip one name, and `--sync-env` removes an entry .env
# doesn't name, so the command runs against a scratch copy of the project:
# Dockerfile, .env without the token, and .datarobot.yaml without the
# api-key entry. The manifest it writes is copied back with exactly one
# DATAROBOT_API_TOKEN entry, the api-key one, whatever dr left there. ./.env
# itself is never modified.
#
# Usage: scripts/workload-config.sh <dr workload config arguments>
#        scripts/workload-config.sh --check [manifest]
#
# --check exits 0 only if the manifest's sole DATAROBOT_API_TOKEN entry is the
# workload's own key. `dr run deploy` and `dr run doctor` use it.

set -eu

token=DATAROBOT_API_TOKEN
manifest=.datarobot.yaml

# Lines that name the token as an entry, in block (`- name: X`, `name: X`) or
# flow (`- {name: X, ...}`) style.
names_token() {
    grep -cE "(^|[{,[:space:]])name:[[:space:]]*[\"']?${token}[\"']?[[:space:]]*([,}#]|\$)" "$1" || true
}

# Finds the primary container's environmentVars: the container under
# `artifact:` marked `primary: true`, or the only one there. Prints
# "<line of the environmentVars key> <its column> <1 if it holds the api-key
# entry, else 0>". Exits 2 when there is no single primary container, and 3
# when it has no environmentVars key. A line-based reading of the block style
# dr writes, kept to the keys that matter here.
primary_env() {
    awk -v name="$token" '
        function ind(s) { match(s, /^ */); return RLENGTH }
        function finish() {
            if (!initem) return
            items++
            if (isprim) { prims++; p_env = env; p_col = envcol; p_pair = pair }
            if (items == 1) { f_env = env; f_col = envcol; f_pair = pair }
            initem = 0; inenv = 0
        }
        /^[[:space:]]*(#.*)?$/ { next }
        { i = ind($0) }
        i == 0 { finish(); incont = 0; section = $0; sub(/:.*/, "", section) }
        incont && (i < icol || (i == icol && $0 !~ /^ *- /) || (itemcol >= 0 && i < itemcol)) {
            finish(); incont = 0
        }
        incont {
            first = 0
            if ($0 ~ /^ *- / && (itemcol < 0 || i == itemcol)) {
                finish()
                initem = 1; itemcol = i; isprim = 0; env = 0; envcol = 0; pair = 0; held = 0
                match($0, /^ *- +/); keycol = RLENGTH; first = 1
            }
            if (inenv && !first) {
                if (i > keycol || (i == keycol && $0 ~ /^ *- /)) {
                    if (held && $0 ~ /^ *source: *api-key *(#.*)?$/) pair = 1
                    held = ($0 ~ ("^ *- name: *[\"'\'']?" name "[\"'\'']? *(#.*)?$"))
                    next
                }
                inenv = 0; held = 0
            }
            if (first || i == keycol) {
                kv = substr($0, keycol + 1)
                if (kv ~ /^primary: *true *(#.*)?$/) isprim = 1
                if (kv ~ /^environmentVars: *(#.*)?$/) { env = NR; envcol = keycol; inenv = 1 }
            }
            next
        }
        section == "artifact" && /^ *(- +)?containers: *(#.*)?$/ {
            incont = 1; match($0, /^ *(- +)?/); icol = RLENGTH; itemcol = -1
        }
        END {
            finish()
            if (prims == 1) { e = p_env; c = p_col; p = p_pair }
            else if (prims == 0 && items == 1) { e = f_env; c = f_col; p = f_pair }
            else exit 2
            if (!e) exit 3
            print e, c, p
        }
    ' "$1"
}

# True when the manifest's only entry for the token is `source: api-key`, in
# the primary container.
is_workload_key() {
    [ "$(names_token "$1")" = 1 ] || return 1
    loc=$(primary_env "$1") || return 1
    [ "${loc##* }" = 1 ]
}

# Drops every entry for the token: a `- name:` block with the lines indented
# under it, or a flow-style one-liner. Anything else naming it is caught by
# is_workload_key afterwards, which fails the run rather than guess.
remove_token_entries() {
    awk -v name="$token" '
        function indent(s) { match(s, /^[[:space:]]*/); return RLENGTH }
        skipping && $0 !~ /^[[:space:]]*$/ && indent($0) > entry { next }
        { skipping = 0 }
        $0 ~ "^[[:space:]]*- name:[[:space:]]*[\"'\'']?" name "[\"'\'']?[[:space:]]*(#.*)?$" {
            skipping = 1; entry = indent($0); next
        }
        $0 ~ "^[[:space:]]*-[[:space:]]*[{].*name:[[:space:]]*[\"'\'']?" name "[\"'\'']?[[:space:]]*[,}]" { next }
        { print }
    ' "$1"
}

# Puts the api-key entry first in the primary container's environmentVars,
# and nowhere else.
add_api_key_entry() {
    loc=$(primary_env "$1") || return
    awk -v name="$token" -v at="${loc%% *}" -v col="$(echo "$loc" | cut -d' ' -f2)" '
        { print }
        NR == at {
            pad = sprintf("%" col "s", "")
            print pad "  - name: " name
            print pad "    source: api-key"
        }
    ' "$1"
}

if [ "${1:-}" = --check ]; then
    file=${2:-$manifest}
    is_workload_key "$file" && exit 0
    echo "$file doesn't declare $token as the workload's own key (source: api-key)." >&2
    exit 1
fi

[ -f .env ] || { echo "No .env here. Run 'dr start' first." >&2; exit 1; }

dry_run=
for arg in "$@"; do
    [ "$arg" != --dry-run ] || dry_run=1
done

# The scratch copy holds .env's other secrets: removed however this ends.
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
trap 'exit 130' INT TERM HUP

cp Dockerfile "$work/"
grep -v "^${token}=" .env > "$work/.env" || true

# Only the api-key entry is hidden from dr. Any other form, such as a
# dr-credential an older manifest holds, stays visible, so --sync-env, which no
# longer finds the name in .env, lists it for removal.
if [ -f "$manifest" ]; then
    if is_workload_key "$manifest"; then
        remove_token_entries "$manifest" > "$work/$manifest"
    else
        cp "$manifest" "$work/$manifest"
    fi
fi

dr workload config --dir "$work" "$@"

[ -z "$dry_run" ] || exit 0
[ -f "$work/$manifest" ] || exit 0

# Whatever dr kept, the result names the token once, as the workload's key.
remove_token_entries "$work/$manifest" > "$work/without-token"
add_api_key_entry "$work/without-token" > "$work/$manifest.new" || case $? in
    2) echo "Can't tell which container in $manifest is the primary one, so $token" >&2
       echo "wasn't added anywhere. Mark it with 'primary: true'." >&2
       exit 1 ;;
    *) echo "The primary container in $manifest has no environmentVars block to add" >&2
       echo "$token to." >&2
       exit 1 ;;
esac
if ! is_workload_key "$work/$manifest.new"; then
    echo "Couldn't reduce $token in $manifest to the workload's own key, so the" >&2
    echo "file was left as it was. Fix that entry by hand; see docs/TROUBLESHOOTING.md." >&2
    exit 1
fi

# Unchanged apart from where the entry sits: leave the file byte for byte.
if [ -f "$manifest" ] && is_workload_key "$manifest" &&
    remove_token_entries "$manifest" | cmp -s - "$work/without-token"; then
    exit 0
fi

was_user_token=
if [ -f "$manifest" ] && ! is_workload_key "$manifest"; then
    was_user_token=1
fi
cp "$work/$manifest.new" "$manifest"
echo "Updated ./$manifest. (Paths under $work above are the scratch copy dr ran in.)"
if [ -n "$was_user_token" ]; then
    echo "$token is now the workload's own key, in place of a token from .env."
fi
