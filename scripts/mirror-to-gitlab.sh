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

# Pushes main and the v* tags of this clone to the GitLab copy over SSH, in one
# atomic push. The push is a fast-forward and never forces, so a commit made
# directly on the GitLab main makes it fail instead of overwriting that commit.
# Every push sends the whole state, so a failed run is caught up by the next
# one. Other branches stay on GitHub.
#
# Run it in a clone that has every branch and tag, which `actions/checkout`
# gives with `fetch-depth: 0`. GITLAB_MIRROR_KEY holds the private half of a
# deploy key with write access, which GitLab allows to push to main.
#
# Usage: GITLAB_MIRROR_KEY=PRIVATE_KEY scripts/mirror-to-gitlab.sh GITLAB_REPOSITORY_URL

set -eu

url=${1:?Usage: scripts/mirror-to-gitlab.sh GITLAB_REPOSITORY_URL}

if [ -z "${GITLAB_MIRROR_KEY:-}" ]; then
    echo "GITLAB_MIRROR_KEY is empty." >&2
    exit 1
fi

# The key lives in a private directory for the length of the push.
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
umask 077
printf '%s\n' "$GITLAB_MIRROR_KEY" > "$work/key"

# The ED25519 host key of gitlab.com, as GitLab publishes it in its documentation
# (fingerprint SHA256:eUXGGm1YGsMAS7vkcx6JOJdOGHPem5gQp4taiCfCLB8). Checking against
# it stops the push from sending the key to a host that only claims to be GitLab.
printf '%s\n' 'gitlab.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAfuCHKVTjquxvt6CM6tdG4SLp1Btn/nOeHHE5UOzRdf' > "$work/known_hosts"

# git runs this string through a shell, so the quotes keep a path with spaces whole.
export GIT_SSH_COMMAND="ssh -i '$work/key' -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=yes -o HostKeyAlgorithms=ssh-ed25519 -o UserKnownHostsFile='$work/known_hosts'"

git push --atomic "$url" \
    refs/remotes/origin/main:refs/heads/main \
    'refs/tags/v*:refs/tags/v*'
