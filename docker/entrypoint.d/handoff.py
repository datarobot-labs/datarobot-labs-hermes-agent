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

"""Helpers for the state store's rollout handoff (15-handoff.sh).

  handoff.py protons  one "<id> <status>" line per generation (proton) of
                      $WORKLOAD_ID, read with the workload's own key
"""

import json
import os
import sys
import urllib.parse
import urllib.request

# A workload has one generation, two during a rollout, and the stopped ones
# the list keeps. Far more pages than that is a next-link that never ends.
MAX_PAGES = 20


class SameOrigin(urllib.request.HTTPRedirectHandler):
    """Follows a redirect only on the endpoint's own scheme and host.

    urllib copies the Authorization header onto a redirected request, so a
    redirect elsewhere, or from HTTPS down to HTTP, would carry the key along.
    """

    def __init__(self, origin):
        super().__init__()
        self.origin = origin

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        if urllib.parse.urlsplit(newurl)[:2] != self.origin:
            raise ValueError("a redirect points to another host; not sending the key there")
        return super().redirect_request(req, fp, code, msg, headers, newurl)


def protons():
    endpoint = os.environ["DATAROBOT_ENDPOINT"].rstrip("/")
    origin = urllib.parse.urlsplit(endpoint)[:2]
    url = f"{endpoint}/workloads/{os.environ['WORKLOAD_ID']}/protons/"
    # The token goes in a header, never on a command line.
    headers = {"Authorization": f"Bearer {os.environ['DATAROBOT_API_TOKEN']}"}
    opener = urllib.request.build_opener(SameOrigin(origin))
    # Printed only once every page is read: a list cut short by a failed page
    # could leave out a generation that still writes.
    lines = []
    for _ in range(MAX_PAGES):
        with opener.open(urllib.request.Request(url, headers=headers), timeout=15) as r:
            page = json.load(r)
        data = page.get("data") if isinstance(page, dict) else None
        # A body without a list is an error, not "no generations": that would
        # read as "nobody else writes" and end a wait early.
        if not isinstance(data, list):
            raise ValueError("the protons route answered without a list")
        for proton in data:
            if isinstance(proton, dict) and proton.get("id"):
                lines.append(f"{proton['id']} {proton.get('status') or 'unknown'}")
        next_url = page.get("next")
        if not next_url:
            print("\n".join(lines))
            return
        # Relative to the page that gave it, as a browser would. The key goes
        # with every page: never to a host the endpoint isn't.
        url = urllib.parse.urljoin(url, next_url)
        if urllib.parse.urlsplit(url)[:2] != origin:
            raise ValueError("the next page is on another host; not sending the key there")
    raise ValueError(f"the protons list ran past {MAX_PAGES} pages")


if __name__ == "__main__":
    try:
        if sys.argv[1:] == ["protons"]:
            protons()
        else:
            sys.exit("usage: handoff.py protons")
    except (OSError, ValueError, KeyError) as e:
        print(f"[entrypoint] handoff.py: {type(e).__name__}: {e}", file=sys.stderr)
        sys.exit(1)
