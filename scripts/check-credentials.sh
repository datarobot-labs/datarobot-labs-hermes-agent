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

# Fails when the manifest still references a PLACEHOLDER credential, which
# `dr workload config` leaves when a credential of the same name already
# exists (docs/TROUBLESHOOTING.md, "PLACEHOLDER credentials"). A deploy would
# be refused. `dr run deploy` and `dr run doctor` call it.
#
# Only an unresolved reference, `dr-credential:PLACEHOLDER/...`, counts. The
# word elsewhere, in a name, a plain value or a comment, is not a credential.
#
# Usage: scripts/check-credentials.sh [manifest, default .datarobot.yaml]

set -eu

manifest=${1:-.datarobot.yaml}
[ -r "$manifest" ] || { echo "cannot read $manifest" >&2; exit 2; }

if grep -v '^[[:space:]]*#' "$manifest" | grep -qE 'dr-credential:PLACEHOLDER([/"'"'"'[:space:]]|$)'; then
    exit 1
fi
