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

  handoff.py protons         one "<id> <status>" line per generation (proton)
                             of $WORKLOAD_ID, read with the workload's own key
  handoff.py standin <port>  answer on <port> until killed: 200 for /health,
                             503 for anything else

The platform makes a new generation the active one as soon as its port
answers. The stand-in lets a new pod become active while it waits for the old
one to hand the state store off, without starting the gateway early.
"""

import http.server
import json
import os
import sys
import urllib.request

# A workload has one generation, two during a rollout, and the stopped ones
# the list keeps. Far more pages than that is a next-link that never ends.
MAX_PAGES = 20


def protons():
    endpoint = os.environ["DATAROBOT_ENDPOINT"].rstrip("/")
    url = f"{endpoint}/workloads/{os.environ['WORKLOAD_ID']}/protons/"
    # The token goes in a header, never on a command line.
    headers = {"Authorization": f"Bearer {os.environ['DATAROBOT_API_TOKEN']}"}
    for _ in range(MAX_PAGES):
        with urllib.request.urlopen(urllib.request.Request(url, headers=headers), timeout=15) as r:
            page = json.load(r)
        data = page.get("data") if isinstance(page, dict) else None
        # A body without a list is an error, not "no generations": that would
        # read as "nobody else writes" and end a wait early.
        if not isinstance(data, list):
            raise ValueError("the protons route answered without a list")
        for proton in data:
            if isinstance(proton, dict) and proton.get("id"):
                print(proton["id"], proton.get("status") or "unknown")
        url = page.get("next")
        if not url:
            return
    raise ValueError(f"the protons list ran past {MAX_PAGES} pages")


class StandIn(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        healthy = self.path.split("?")[0] == "/health"
        self.send_response(200 if healthy else 503)
        self.send_header("Content-Type", "text/plain")
        self.end_headers()
        self.wfile.write(b"waiting for the state store handoff\n")

    def log_message(self, *args):
        pass


def standin(port):
    http.server.HTTPServer(("", int(port)), StandIn).serve_forever()


if __name__ == "__main__":
    try:
        if sys.argv[1:] == ["protons"]:
            protons()
        elif len(sys.argv) == 3 and sys.argv[1] == "standin":
            standin(sys.argv[2])
        else:
            sys.exit("usage: handoff.py protons | handoff.py standin <port>")
    except (OSError, ValueError, KeyError) as e:
        print(f"[entrypoint] handoff.py: {type(e).__name__}: {e}", file=sys.stderr)
        sys.exit(1)
