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

# Behaviour of scripts/install-sync-plugin.sh against stub curl and dr: the
# plugin is installed from the downloaded archive only when its sha256 matches.

setup() {
    WORK=$(mktemp -d)
    mkdir "$WORK/bin"
    export STUB_LOG="$WORK/calls"
    : > "$STUB_LOG"
    # curl: writes "archive" to the -o file.
    cat > "$WORK/bin/curl" <<'STUB'
#!/bin/sh
echo "curl $*" >> "$STUB_LOG"
prev=
for a in "$@"; do [ "$prev" = -o ] && printf 'archive' > "$a"; prev=$a; done
exit 0
STUB
    # dr: records its arguments and whether the file it was given exists.
    cat > "$WORK/bin/dr" <<'STUB'
#!/bin/sh
echo "dr $*" >> "$STUB_LOG"
[ -f "$5" ] && echo "file present" >> "$STUB_LOG"
exit 0
STUB
    chmod +x "$WORK/bin/curl" "$WORK/bin/dr"
    URL=https://example.com/releases/download/v1.2.3/sync-0.1.0.tar.xz
    GOOD=$(printf 'archive' | sha256sum | cut -d' ' -f1)
}

teardown() {
    rm -rf "$WORK"
}

install() {
    PATH="$WORK/bin:$PATH" run sh /repo/scripts/install-sync-plugin.sh "$URL" "$1"
}

@test "an archive that matches its sha256 is installed with dr plugin install --file" {
    install "$GOOD"
    [ "$status" -eq 0 ]
    grep -q "^curl -fsSL -o .*/sync-0.1.0.tar.xz $URL$" "$STUB_LOG"
    grep -qE '^dr plugin install sync --file .*/sync-0.1.0.tar.xz$' "$STUB_LOG"
    grep -qx 'file present' "$STUB_LOG"
}

@test "an archive that doesn't match its sha256 is never installed" {
    install 0000000000000000000000000000000000000000000000000000000000000000
    [ "$status" -eq 1 ]
    [[ "$output" == *"doesn't match its sha256"* ]]
    ! grep -q '^dr ' "$STUB_LOG" || false
}

@test "the downloaded archive is removed however the install ends" {
    install "$GOOD"
    install 0000000000000000000000000000000000000000000000000000000000000000
    dir=$(sed -nE 's|^curl -fsSL -o (.*)/sync-0.1.0.tar.xz .*|\1|p' "$STUB_LOG" | head -n 1)
    [ -n "$dir" ]
    [ ! -e "$dir" ]
}
