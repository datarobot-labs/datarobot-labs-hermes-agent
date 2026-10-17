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

# Makes the GitLab copy match this clone's origin: main and the v* tags, over
# SSH, in one atomic push. Main moves by fast-forward and never by force, so a
# commit made directly on the GitLab main makes the push fail instead of being
# overwritten. The v* tags follow origin exactly: a tag that origin moved is moved
# on GitLab, and a tag that origin no longer has is deleted. Nothing else is
# touched: other branches and other tags stay as they are. Every push sends the
# whole state, so a failed run is caught up by the next one.
#
# Run it in a clone of origin, with the full history of main that `actions/checkout`
# gives with `fetch-depth: 0`. GITLAB_MIRROR_KEY holds the private half of a deploy
# key with write access, which GitLab allows to push to main.
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

# Origin is the source of truth for the tags, not the checkout. One forced, pruning
# fetch makes the local v* tags match origin right now, so the names and the tag
# objects that the push sends come from the same snapshot: a tag that origin
# deleted and recreated after the checkout is sent at its new commit. A fetch that
# fails stops the script before it prunes or deletes anything.
git fetch --quiet --force --prune origin '+refs/tags/v*:refs/tags/v*'
github_tags=$(git for-each-ref --format='%(refname:strip=2)' 'refs/tags/v*')
# The listing is captured before it goes through awk, because a pipeline reports
# awk's status and would hide a failed listing as "no tags on GitLab".
gitlab_listing=$(git ls-remote --tags --refs "$url" 'refs/tags/v*')
gitlab_tags=$(printf '%s\n' "$gitlab_listing" | awk '{ sub("^refs/tags/", "", $2); print $2 }')

# A tag that origin moved is moved on GitLab too. Main is never forced.
set -- refs/remotes/origin/main:refs/heads/main
for tag in $github_tags; do
    set -- "$@" "+refs/tags/$tag:refs/tags/$tag"
done
for tag in $gitlab_tags; do
    if ! printf '%s\n' "$github_tags" | grep -qxF -- "$tag"; then
        set -- "$@" ":refs/tags/$tag"
    fi
done

git push --atomic "$url" "$@"
