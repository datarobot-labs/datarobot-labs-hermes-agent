#!/usr/bin/env python3
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

"""Merge the state store's skills/.hub/lock.json into the image's.

20-state-sync.sh lays the image's skills over the downloaded ones, the hub's
lock file included, so a skill the agent installed from the hub at runtime
would lose its record and the hub could no longer update or remove it. This
keeps every stored record whose skill is still in skills/ and lets the image's
own records win. A record whose skill is gone, pruned with an image that no
longer ships it, is dropped.

Usage: hub-lock.py <stored lock> <the image's lock, rewritten in place> <skills dir>
"""

import json
import os
import stat
import sys
import tempfile


def load(path):
    with open(path, encoding="utf-8") as f:
        lock = json.load(f)
    if not isinstance(lock, dict) or not isinstance(lock.get("installed", {}), dict):
        raise ValueError(f"{path} isn't a hub lock")
    return lock


def merge(stored_path, image_path, skills_dir):
    stored, image = load(stored_path), load(image_path)
    skills = os.path.realpath(skills_dir)
    installed = {}
    for name, record in stored.get("installed", {}).items():
        rel = record.get("install_path") if isinstance(record, dict) else None
        if not isinstance(rel, str) or not rel:
            continue
        # The store is outside data: only a path inside skills/ counts.
        path = os.path.realpath(os.path.join(skills, rel))
        if path.startswith(skills + os.sep) and os.path.isdir(path):
            installed[name] = record
    installed.update(image.get("installed", {}))
    image["installed"] = installed

    mode = stat.S_IMODE(os.stat(image_path).st_mode)
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(image_path) or ".")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(image, f, indent=2)
            f.write("\n")
        os.chmod(tmp, mode)
        os.replace(tmp, image_path)
    except BaseException:
        os.unlink(tmp)
        raise


if __name__ == "__main__":
    if len(sys.argv) != 4:
        sys.exit(__doc__.strip().splitlines()[-1])
    try:
        merge(*sys.argv[1:])
    except (OSError, ValueError) as e:
        print(f"[entrypoint] hub-lock.py: {e}", file=sys.stderr)
        sys.exit(1)
