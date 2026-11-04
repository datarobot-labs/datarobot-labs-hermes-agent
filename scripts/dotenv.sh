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

# Reads a .env the way dr does, with godotenv v1.5.1: indented lines,
# `export NAME=`, `NAME = value` and `NAME: value` all set NAME, a value in
# quotes can run over several lines, and an unquoted one ends at its last
# ` #`. Escapes and $VAR in values are left as written: the values read
# here, such as a store id, have neither.
#
# Usage: scripts/dotenv.sh names <env file>         every name, once, sorted
#        scripts/dotenv.sh value <NAME> <env file>  the last value of NAME
# Exits 2 when it can't read the file.

set -eu

case ${1:-} in
    names) mode=names name='' file=${2:-} ;;
    value) mode=value name=${2:-} file=${3:-} ;;
    *) echo "Usage: $0 names <env file> | value <NAME> <env file>" >&2; exit 2 ;;
esac
[ -r "$file" ] || { echo "Can't read $file." >&2; exit 2; }

# A line at a time, a quoted value carried over until its closing quote: one
# not preceded by a backslash, as godotenv looks for it. A line godotenv
# would reject (a name with another character in it) sets nothing.
awk -v mode="$mode" -v want="$name" '
    function close_at(s, q, from,    i) {
        for (i = from; i <= length(s); i++)
            if (substr(s, i, 1) == q && substr(s, i - 1, 1) != "\\") return i
        return 0
    }
    # A quoted value loses every quote at either end, as godotenv trims them.
    function set(k, v) {
        if (q != "") {
            while (v != "" && substr(v, 1, 1) == q) v = substr(v, 2)
            while (v != "" && substr(v, length(v)) == q) v = substr(v, 1, length(v) - 1)
        }
        names[k]; if (k == want) value = v
    }
    {
        sub(/\r$/, "")
        if (inq) {
            at = close_at($0, q, 1)
            if (!at) { val = val "\n" $0; next }
            inq = 0; set(key, val "\n" substr($0, 1, at - 1)); next
        }
        s = $0; sub(/^[ \t\f\v]+/, "", s)
        if (s == "" || substr(s, 1, 1) == "#") next
        if (s ~ /^export[ \t]/) sub(/^export[ \t]+/, "", s)
        if (!match(s, /^[A-Za-z0-9_.]+[ \t]*[=:]/)) next
        key = substr(s, 1, RLENGTH - 1); sub(/[ \t]+$/, "", key)
        v = substr(s, RLENGTH + 1); sub(/^[ \t\f\v]+/, "", v)
        q = substr(v, 1, 1)
        if (q == "\"" || q == "'\''") {
            at = close_at(v, q, 2)
            if (at) set(key, substr(v, 1, at - 1))
            else { inq = 1; val = v }
            next
        }
        q = ""
        for (i = length(v); i > 1; i--)
            if (substr(v, i, 1) == "#" && substr(v, i - 1, 1) ~ /[ \t\f\v]/) { v = substr(v, 1, i - 1); break }
        sub(/[ \t\f\v]+$/, "", v)
        set(key, v)
    }
    END {
        if (mode == "value") printf "%s", value
        else for (k in names) print k
    }
' "$file" | if [ "$mode" = names ]; then LC_ALL=C sort; else cat; fi
