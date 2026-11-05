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

# Reads .env for the checks. Handles indentation, `export`, quotes, CRLF and
# an inline ` #` comment, as dr does; not multi-line values, `NAME: value` or
# spaces around `=`, which dr accepts but this .env never uses.
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

awk -v want="$name" -v mode="$mode" '
    {
        sub(/\r$/, ""); sub(/^[ \t]+/, ""); sub(/^export[ \t]+/, "")
        if (!match($0, /^[A-Za-z0-9_.]+=/)) next
        k = substr($0, 1, RLENGTH - 1); v = substr($0, RLENGTH + 1)
        sub(/^[ \t]+/, "", v); q = substr(v, 1, 1)
        if ((q == "\"" || q == "\047") && (end = index(substr(v, 2), q))) v = substr(v, 2, end - 1)
        else { sub(/[ \t]+#.*/, "", v); sub(/[ \t]+$/, "", v) }
        names[k]; if (k == want) value = v
    }
    END {
        if (mode == "value") printf "%s", value
        else for (k in names) print k
    }
' "$file" | if [ "$mode" = names ]; then LC_ALL=C sort; else cat; fi
