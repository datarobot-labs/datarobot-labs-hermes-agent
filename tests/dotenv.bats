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

# Behaviour of scripts/dotenv.sh: it reads .env as dr does. The expected
# names and values below are what godotenv v1.5.1, dr's parser, reads from
# the same file.

setup() {
    WORK=$(mktemp -d)
    ENV="$WORK/.env"
    printf '%s\n' 'A=1' '  B = two  # comment' 'export C: "three"' 'exportD=4' 'export=5' \
        "E='single # not a comment'" 'F="multi' 'G=inside the quotes' 'line"' 'H=a #b #c' \
        'I.J=dots' '1K=digit' 'L=' 'M=  "spaced"  ' 'N="esc \" N2=still inside"' '	TAB=t' \
        '# COMMENTED=1' '   # INDENTED_COMMENT=1' 'P=#notacomment' 'Q=x#y' "R='multi" "S=inside'" \
        'T:colon' 'DR_SYNC_CATALOG_ID: 0123456789abcdef01234567' \
        'DR_SYNC_CATALOG_ID = "abcdefabcdefabcdefabcdef"  # the last one wins' > "$ENV"
    printf 'U=crlf\r\nV=after\r\n' >> "$ENV"
}

teardown() {
    rm -rf "$WORK"
}

@test "every name dr reads, in every form, and none inside a quoted value or a comment" {
    run sh /repo/scripts/dotenv.sh names "$ENV"
    [ "$status" -eq 0 ]
    [ "$output" = "1K
A
B
C
DR_SYNC_CATALOG_ID
E
F
H
I.J
L
M
N
P
Q
R
T
TAB
U
V
export
exportD" ]
}

@test "each value as dr reads it: quotes, comments, spaces and line ends dropped, the last one winning" {
    for pair in A=1 B=two C=three D= export=5 'E=single # not a comment' 'F=multi
G=inside the quotes
line' 'H=a #b' I.J=dots 1K=digit L= M=spaced TAB=t P=#notacomment Q=x#y 'R=multi
S=inside' T=colon U=crlf V=after exportD=4 DR_SYNC_CATALOG_ID=abcdefabcdefabcdefabcdef; do
        run sh /repo/scripts/dotenv.sh value "${pair%%=*}" "$ENV"
        [ "$status" -eq 0 ]
        [ "$output" = "${pair#*=}" ] || { echo "${pair%%=*}: got [$output]"; false; }
    done
}

@test "an unreadable file is an error, not an empty .env" {
    run sh /repo/scripts/dotenv.sh names "$WORK/missing"
    [ "$status" -eq 2 ]
    run sh /repo/scripts/dotenv.sh value A "$WORK/missing"
    [ "$status" -eq 2 ]
}
