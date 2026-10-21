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

# Installs the datarobot-sync dr plugin from a release archive, once the
# archive matches the sha256 .datarobot/cli/versions.yaml pins. `dr plugin
# install --url` takes no checksum, and the plugin runs with your dr login.
# `dr start` and `dr run install` call it through `dr dependencies install`.
#
# Usage: scripts/install-sync-plugin.sh <archive url> <sha256>

set -eu

url=$1
sum=$2

dir=$(mktemp -d)
trap 'rm -rf "$dir"' EXIT
trap 'exit 130' INT TERM HUP

archive="$dir/${url##*/}"
curl -fsSL -o "$archive" "$url"
got=$( (sha256sum "$archive" 2>/dev/null || shasum -a 256 "$archive") | cut -d' ' -f1)
if [ "$got" != "$sum" ]; then
    echo "The dr sync plugin from $url doesn't match its sha256 in" >&2
    echo ".datarobot/cli/versions.yaml, so it wasn't installed." >&2
    exit 1
fi
dr plugin install sync --file "$archive"
