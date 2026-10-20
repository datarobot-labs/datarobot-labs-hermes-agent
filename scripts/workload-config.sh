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
# DR_SYNC_CATALOG_ID, the state store's id (scripts/state-store.sh), is kept
# from dr the same way. dr's secret detector reads the 24-character hex id as
# a random token and would store it as a credential, so the copy back declares
# it as a plain value, taken from .env, or not at all when .env has none.
#
# Usage: scripts/workload-config.sh <dr workload config arguments>
#        scripts/workload-config.sh --check [manifest]
#
# --check exits 0 only if the manifest's sole DATAROBOT_API_TOKEN entry is the
# workload's own key. `dr run deploy` and `dr run doctor` use it.

set -eu

token=DATAROBOT_API_TOKEN
store=DR_SYNC_CATALOG_ID
manifest=.datarobot.yaml

# Reads the token's entries in every environmentVars list, and only there:
# lines at the list's item column (`- name: X`, or the flow `- {name: X}`) and
# lines at an item's own key column (`name: X` after another key), plus, for
# the count, entries of a list written on the key's own line. Text deeper
# than that, say inside a `|` block value, is not an entry, and neither is a
# comment. MODE "count" prints how many lines name the token. MODE "drop"
# prints the file without the `- name:` and flow entries: an entry's blank,
# comment and more-indented lines go with it, up to the next other line at or
# above its column. Anything else naming the token is left for
# is_workload_key to refuse afterwards, rather than guessed at.
token_entries() {
    awk -v name="${3:-$token}" -v mode="$1" '
        function indent(s) { match(s, /^ */); return RLENGTH }
        function blank(s) { return s ~ /^[[:space:]]*(#.*)?$/ }
        BEGIN { itemcol = -1; keyin = -1 }
        {
            line = $0; skip = 0
            if (!blank(line)) {
                i = indent(line)
                if (inenv && (i < envcol || (i == envcol && line !~ /^ *- /))) inenv = 0
                if (dropping && i <= dropcol) dropping = 0
                if (inenv && line ~ /^ *- / && (itemcol < 0 || i == itemcol)) {
                    itemcol = i; match(line, /^ *- +/); keyin = RLENGTH
                    if (line ~ ("^ *- +name: *[\"'\'']?" name "[\"'\'']? *(#.*)?$")) {
                        count++; skip = 1; dropping = 1; dropcol = i
                    } else if (line ~ ("^ *- *[{].*name: *[\"'\'']?" name "[\"'\'']? *[,}]")) {
                        count++; skip = 1
                    }
                } else if (inenv && i == keyin && line ~ ("^ *name: *[\"'\'']?" name "[\"'\'']? *(#.*)?$")) {
                    count++
                }
                if (line ~ /^ *(- +)?environmentVars: *(#.*)?$/) {
                    inenv = 1; match(line, /^ *(- +)?/); envcol = RLENGTH; itemcol = -1; keyin = -1
                } else if (line ~ /^ *(- +)?environmentVars: *[^ #]/) {
                    # A list on the same line, [{name: X, ...}]. Its entries are
                    # counted, never dropped, so a token in one fails the check.
                    # One left open for later lines cannot be read line by line:
                    # it counts as two, which fails the check whatever it holds.
                    v = line; sub(/^ *(- +)?environmentVars: */, "", v)
                    if (v ~ /^\[/ && v !~ /\]/) count += 2
                    else count += gsub("name: *[\"'\'']?" name "[\"'\'']? *[,}]", "", v)
                }
            }
            if (dropping && !skip && (blank(line) || indent(line) > dropcol)) skip = 1
            if (mode == "drop" && !skip) print line
        }
        END { if (mode == "count") print count + 0 }
    ' "$2"
}

names_token() {
    token_entries count "$1"
}

# Finds the environmentVars of Hermes' container under `artifact:`: the one
# built from this repo's Dockerfile (`dockerfile: source: provided`; only one
# container can be), else the single one marked `primary: true` (each
# container group has its own primary), else the only container. Prints
# "<line of the environmentVars key> <its column> <the column of its items>
# <1 if it holds the api-key entry, else 0>". The items' column is two past the
# key's when the list is empty, and the key's own for an indentationless list.
# The api-key entry counts only when `source: api-key` is its
# one key besides name: no value, no other source. Exits 2 when none of those
# rules picks one container, and 3 when it has no environmentVars key. A
# line-based reading of the block style dr writes, kept to the keys that
# matter here.
primary_env() {
    awk -v name="$token" '
        function ind(s) { match(s, /^ */); return RLENGTH }
        # Settles the token entry being read: the workload key only if it says
        # `source: api-key` and nothing else.
        function closetok() {
            if (intok) pair = (tsrc && !tother)
            intok = 0
        }
        function finish() {
            closetok()
            if (!initem) return
            items++
            # The column its items use; with none yet, two under the key.
            it = (eitem >= 0) ? eitem : envcol + 2
            if (built) { builts++; b_env = env; b_col = envcol; b_it = it; b_pair = pair }
            if (isprim) { prims++; p_env = env; p_col = envcol; p_it = it; p_pair = pair }
            if (items == 1) { f_env = env; f_col = envcol; f_it = it; f_pair = pair }
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
                initem = 1; itemcol = i; isprim = 0; built = 0; env = 0; envcol = 0; pair = 0; intok = 0
                match($0, /^ *- +/); keycol = RLENGTH; first = 1
            }
            if (inenv && !first) {
                if (i > keycol || (i == keycol && $0 ~ /^ *- /)) {
                    if (intok && i > tokcol) {
                        if ($0 ~ /^ *source: *api-key *(#.*)?$/) tsrc = 1
                        else if ($0 ~ /^ *[A-Za-z_][A-Za-z0-9_]*:/) tother = 1
                        next
                    }
                    closetok()
                    # Only at the column of the list items: a deeper "- name:"
                    # is text inside some value, not an entry.
                    if (eitem < 0 && $0 ~ /^ *- /) eitem = i
                    if (i == eitem && $0 ~ ("^ *- name: *[\"'\'']?" name "[\"'\'']? *(#.*)?$")) {
                        intok = 1; tokcol = i; tsrc = 0; tother = 0
                    }
                    next
                }
                closetok(); inenv = 0
            }
            if ($0 ~ /^ *source: *provided *(#.*)?$/) built = 1
            if (first || i == keycol) {
                kv = substr($0, keycol + 1)
                if (kv ~ /^primary: *true *(#.*)?$/) isprim = 1
                if (kv ~ /^environmentVars: *(#.*)?$/) { env = NR; envcol = keycol; inenv = 1; eitem = -1 }
            }
            next
        }
        section == "artifact" && /^ *(- +)?containers: *(#.*)?$/ {
            incont = 1; match($0, /^ *(- +)?/); icol = RLENGTH; itemcol = -1
        }
        END {
            finish()
            if (builts == 1) { e = b_env; c = b_col; t = b_it; p = b_pair }
            else if (prims == 1) { e = p_env; c = p_col; t = p_it; p = p_pair }
            else if (prims == 0 && items == 1) { e = f_env; c = f_col; t = f_it; p = f_pair }
            else exit 2
            if (!e) exit 3
            print e, c, t, p
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

remove_token_entries() {
    token_entries drop "$1"
}

# The file without any entry for the state store's id: dr never sees one.
remove_store_entries() {
    token_entries drop "$1" "$store"
}

# The state store's id as .env gives it, without the quotes dotenv allows.
store_id=$(sed -n "s/^$store=//p" .env 2>/dev/null | tail -n 1)
case $store_id in
    \"*\") store_id=${store_id#\"} store_id=${store_id%\"} ;;
    \'*\') store_id=${store_id#\'} store_id=${store_id%\'} ;;
esac

# The plain value the file gives the store's id, if any.
store_value() {
    awk -v name="$store" '
        function indent(s) { match(s, /^ */); return RLENGTH }
        $0 ~ ("^ *- name: *[\"'\'']?" name "[\"'\'']? *(#.*)?$") { entry = indent($0); inside = 1; next }
        inside && /^ *(#.*)?$/ { next }
        inside && indent($0) <= entry { inside = 0 }
        inside && /^ *value:/ { v = $0; sub(/^ *value: */, "", v); sub(/[ \t]+#.*$/, "", v); gsub(/^["'\'']|["'\'']$/, "", v); print v; exit }
    ' "$1"
}

# Declares the store's id right after the token, as a plain value.
add_store_entry() {
    if [ -z "$store_id" ]; then
        cat "$1"
        return
    fi
    loc=$(primary_env "$1") || return
    awk -v name="$store" -v id="$store_id" -v at="${loc%% *}" -v col="$(echo "$loc" | cut -d' ' -f3)" '
        { print }
        NR == at + 2 {
            pad = sprintf("%" col "s", "")
            print pad "- name: " name
            print pad "  value: \"" id "\""
        }
    ' "$1"
}

# Puts the api-key entry first in the primary container's environmentVars,
# and nowhere else.
add_api_key_entry() {
    loc=$(primary_env "$1") || return
    awk -v name="$token" -v at="${loc%% *}" -v col="$(echo "$loc" | cut -d' ' -f3)" '
        { print }
        NR == at {
            pad = sprintf("%" col "s", "")
            print pad "- name: " name
            print pad "  source: api-key"
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

# --dir is this script's to set: a second one would point dr at the real
# project, and its .env with the user's token, instead of the scratch copy.
dry_run=
for arg in "$@"; do
    case $arg in
        --dir | --dir=*)
            echo "--dir isn't accepted: this script chooses the directory dr reads, to keep" >&2
            echo "$token out of the workload. Run it from the project root instead." >&2
            exit 2
            ;;
        # Also --dry-run=<bool>: dr parses booleans Go's way, so only its
        # false spellings mean a real run. Anything else is a preview, and
        # a preview must not write the real manifest.
        --dry-run) dry_run=1 ;;
        --dry-run=0 | --dry-run=f | --dry-run=F | --dry-run=false | --dry-run=FALSE | --dry-run=False) dry_run= ;;
        --dry-run=*) dry_run=1 ;;
    esac
done

# The scratch copy holds .env's other secrets, and the manifest is written
# through a temp file next to it: both are removed however this ends.
work=$(mktemp -d)
staged=
trap 'rm -rf "$work"; [ -z "$staged" ] || rm -f "$staged"' EXIT
trap 'exit 130' INT TERM HUP

cp Dockerfile "$work/"
# grep exits 1 when nothing is left (fine) and 2 when it can't read .env: an
# unreadable .env must not pass for an empty one, which --sync-env would
# take as every setting removed.
# Empty removes the entry. Anything else must look like the id dr-sync init
# prints: a typo would reach the workload, which then can't download its state
# and refuses to boot.
if [ -n "$store_id" ] && ! printf '%s' "$store_id" | grep -qE '^[0-9a-f]{24}$'; then
    # Not the value itself: it came from .env, and may be a pasted secret.
    echo "$store in .env isn't a store id: dr-sync prints 24 lowercase hex characters." >&2
    echo "Nothing was changed." >&2
    exit 1
fi

status=0
grep -v -e "^${token}=" -e "^${store}=" .env > "$work/.env" || status=$?
if [ "$status" -gt 1 ]; then
    echo "Couldn't read .env, so nothing was changed." >&2
    exit 1
fi

# Of the token, only the api-key entry is hidden from dr. Any other form, such
# as a dr-credential an older manifest holds, stays visible, so --sync-env,
# which no longer finds the name in .env, lists it for removal. The store's id
# is hidden in any form: it is declared again from .env afterwards.
if [ -f "$manifest" ]; then
    if is_workload_key "$manifest"; then
        remove_token_entries "$manifest" > "$work/manifest.in"
    else
        cp "$manifest" "$work/manifest.in"
    fi
    remove_store_entries "$work/manifest.in" > "$work/$manifest"
fi

dr workload config --dir "$work" "$@"

[ -z "$dry_run" ] || exit 0
[ -f "$work/$manifest" ] || exit 0

# Whatever dr kept, the result names the token once, as the workload's key,
# and the store's id once, as .env's value, or not at all.
remove_token_entries "$work/$manifest" > "$work/without-token.in"
remove_store_entries "$work/without-token.in" > "$work/without-token"
add_api_key_entry "$work/without-token" > "$work/with-key" || case $? in
    2) echo "Can't tell which container in $manifest is Hermes', so $token wasn't" >&2
       echo "added anywhere. It is the one built from ./Dockerfile; with no build" >&2
       echo "config, mark it as the only 'primary: true'." >&2
       exit 1 ;;
    *) echo "The primary container in $manifest has no environmentVars block to add" >&2
       echo "$token to." >&2
       exit 1 ;;
esac
add_store_entry "$work/with-key" > "$work/$manifest.new"
if ! is_workload_key "$work/$manifest.new"; then
    echo "Couldn't reduce $token in $manifest to the workload's own key, so the" >&2
    echo "file was left as it was. Fix that entry by hand; see docs/TROUBLESHOOTING.md." >&2
    exit 1
fi

if [ "$(token_entries count "$work/$manifest.new" "$store")" != "$([ -n "$store_id" ] && echo 1 || echo 0)" ] ||
    [ "$(store_value "$work/$manifest.new")" != "$store_id" ]; then
    echo "Couldn't declare $store in $manifest as .env's value, so the file was left" >&2
    echo "as it was." >&2
    exit 1
fi

# Unchanged apart from where the entries sit: leave the file byte for byte.
if [ -f "$manifest" ] && is_workload_key "$manifest" &&
    [ "$(store_value "$manifest")" = "$store_id" ] &&
    [ "$(token_entries count "$manifest" "$store")" = "$([ -n "$store_id" ] && echo 1 || echo 0)" ] &&
    remove_token_entries "$manifest" > "$work/old.in" &&
    remove_store_entries "$work/old.in" | cmp -s - "$work/without-token"; then
    exit 0
fi

was_user_token=
if [ -f "$manifest" ] && ! is_workload_key "$manifest"; then
    was_user_token=1
fi
# Swapped in by rename, so an interruption or a full disk leaves either the
# old manifest or the new one, never a truncated file. It keeps the old
# file's permissions, or gets the umask's for a new one.
staged=$(mktemp "./$manifest.XXXXXX")
cat "$work/$manifest.new" > "$staged"
if [ -f "$manifest" ]; then
    mode=$(stat -c %a "$manifest" 2>/dev/null || stat -f %Lp "$manifest")
else
    mode=$(printf '%o' $((0666 & ~0$(umask))))
fi
chmod "$mode" "$staged"
mv -f "$staged" "$manifest"
staged=
echo "Updated ./$manifest. (Paths under $work above are the scratch copy dr ran in.)"
if [ -n "$was_user_token" ]; then
    echo "$token is now the workload's own key, in place of a token from .env."
fi
