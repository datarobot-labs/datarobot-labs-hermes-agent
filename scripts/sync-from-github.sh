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

# Makes the GitLab project match the GitHub repository: main and the v* tags, in
# one atomic push. Main moves by fast-forward and never by force, so a commit
# made directly on the GitLab main makes the push fail instead of being
# overwritten. The v* tags follow GitHub exactly: a tag that GitHub moved is moved
# on GitLab, and a tag that GitHub no longer has is deleted. Nothing else is
# touched: other branches and other tags stay as they are. Every push sends the
# whole state, so a failed run is caught up by the next one.
#
# The job runs it from the GitLab project, so the destination URL carries the job
# token. The script works in its own empty repository and never reads the
# checkout it runs in.
#
# Usage: scripts/sync-from-github.sh GITHUB_REPOSITORY_URL GITLAB_REPOSITORY_URL

set -eu

source_url=${1:?Usage: scripts/sync-from-github.sh GITHUB_REPOSITORY_URL GITLAB_REPOSITORY_URL}
dest_url=${2:?Usage: scripts/sync-from-github.sh GITHUB_REPOSITORY_URL GITLAB_REPOSITORY_URL}

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
git init --quiet "$work"
cd "$work"

# GitHub is the source of truth for the tags. The repository is new, so the v* tags
# it holds are exactly GitHub's. A fetch that fails stops the script before it
# pushes or deletes anything.
git fetch --quiet --force --no-tags "$source_url" '+refs/heads/main:refs/remotes/origin/main' '+refs/tags/v*:refs/tags/v*'
github_tags=$(git for-each-ref --format='%(refname:strip=2)' 'refs/tags/v*')
# The listing is captured before it goes through awk, because a pipeline reports
# awk's status and would hide a failed listing as "no tags on GitLab".
gitlab_listing=$(git ls-remote --tags --refs "$dest_url" 'refs/tags/v*')
gitlab_tags=$(printf '%s\n' "$gitlab_listing" | awk '{ sub("^refs/tags/", "", $2); print $2 }')

# A tag that GitHub moved is moved on GitLab too. Main is never forced.
set -- refs/remotes/origin/main:refs/heads/main
for tag in $github_tags; do
    set -- "$@" "+refs/tags/$tag:refs/tags/$tag"
done
for tag in $gitlab_tags; do
    if ! printf '%s\n' "$github_tags" | grep -qxF -- "$tag"; then
        set -- "$@" ":refs/tags/$tag"
    fi
done

git push --atomic "$dest_url" "$@"
