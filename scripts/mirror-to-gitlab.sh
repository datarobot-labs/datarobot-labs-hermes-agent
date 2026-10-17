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

# Pushes main and the v* tags of this clone to the GitLab copy, in one atomic
# push. The push is a fast-forward and never forces, so a commit made directly
# on the GitLab main makes it fail instead of overwriting that commit. Every
# push sends the whole state, so a failed run is caught up by the next one.
# Other branches stay on GitHub.
#
# Run it in a clone that has every branch and tag, which `actions/checkout`
# gives with `fetch-depth: 0`. The token needs `write_repository` on the
# GitLab project.
#
# Usage: GITLAB_MIRROR_TOKEN=TOKEN scripts/mirror-to-gitlab.sh GITLAB_REPOSITORY_URL

set -eu

url=${1:?Usage: scripts/mirror-to-gitlab.sh GITLAB_REPOSITORY_URL}

if [ -z "${GITLAB_MIRROR_TOKEN:-}" ]; then
    echo "GITLAB_MIRROR_TOKEN is empty." >&2
    exit 1
fi

# The token goes in a header, not in the URL, so git never prints it.
auth=$(printf 'oauth2:%s' "$GITLAB_MIRROR_TOKEN" | base64 | tr -d '\n')
echo "::add-mask::$auth"

git -c "http.extraheader=Authorization: Basic $auth" push --atomic "$url" \
    refs/remotes/origin/main:refs/heads/main \
    'refs/tags/v*:refs/tags/v*'
