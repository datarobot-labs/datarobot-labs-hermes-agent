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

# Behaviour of docker/entrypoint.d/handoff.py against a fake protons API: the
# list is read with the workload's key across pages, a body that isn't a list
# is an error rather than "no generations".

setup() {
    WORK=$(mktemp -d)
    PORT=18650
    # The fake API: page one links to page two. FAKE_MODE=bad answers without
    # a list, FAKE_MODE=loop links to itself forever.
    cat > "$WORK/api.py" <<'PY'
import http.server, json, os, sys
port, work = int(sys.argv[1]), sys.argv[2]
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        open(os.path.join(work, "auth"), "w").write(self.headers.get("Authorization", ""))
        mode = open(os.path.join(work, "mode")).read().strip()
        base = f"http://127.0.0.1:{port}"
        if mode == "redirect":
            self.send_response(302)
            self.send_header("Location", "http://127.0.0.2:%d/elsewhere" % port)
            self.end_headers()
            return
        if mode == "bad":
            body = {"oops": True}
        elif mode == "foreign":
            body = {"data": [], "next": "http://127.0.0.2:%d/elsewhere" % port}
        elif mode == "loop":
            body = {"data": [], "next": base + self.path}
        elif mode in ("relative", "query") and self.path == "/api/v2/workloads/w1/protons/":
            body = {"data": [{"id": "new1", "status": "running"}],
                    "next": "page2" if mode == "relative" else "?offset=1"}
        elif mode in ("relative", "query"):
            body = {"data": [{"id": "old1", "status": "draining"}], "next": None}
            open(os.path.join(work, "page2"), "w").write(self.path)
        elif mode == "broken" and self.path != "/api/v2/workloads/w1/protons/":
            self.send_response(500)
            self.end_headers()
            return
        elif self.path == "/api/v2/workloads/w1/protons/":
            body = {"data": [{"id": "new1", "status": "running", "role": "active"},
                             {"id": "old1", "status": "draining", "role": None}],
                    "next": base + "/page2"}
        else:
            body = {"data": [{"id": "gone1", "status": "stopped"}], "next": None}
        data = json.dumps(body).encode()
        self.send_response(200)
        self.end_headers()
        self.wfile.write(data)
    def log_message(self, *a):
        pass
http.server.HTTPServer(("127.0.0.1", port), H).serve_forever()
PY
    echo normal > "$WORK/mode"
    python3 "$WORK/api.py" "$PORT" "$WORK" &
    API_PID=$!
    for _ in $(seq 50); do
        python3 -c "import socket; socket.create_connection(('127.0.0.1', $PORT), 1)" 2>/dev/null && break
        sleep 0.1
    done
}

teardown() {
    kill "$API_PID" 2>/dev/null || true
    rm -rf "$WORK"
}

protons() {
    DATAROBOT_ENDPOINT="http://127.0.0.1:$PORT/api/v2/" DATAROBOT_API_TOKEN=workload-key WORKLOAD_ID=w1 \
        run python3 /repo/docker/entrypoint.d/handoff.py protons
}

@test "every generation is listed with its status, across pages, read with the workload's key" {
    protons
    [ "$status" -eq 0 ]
    [ "$output" = "new1 running
old1 draining
gone1 stopped" ]
    [ "$(cat "$WORK/auth")" = "Bearer workload-key" ]
}

@test "an answer without a list is an error, not an empty list" {
    echo bad > "$WORK/mode"
    protons
    [ "$status" -eq 1 ]
    [[ "$output" == *"answered without a list"* ]]
    [[ "$output" != *workload-key* ]]
}

@test "a next-link to another host is refused, and the key isn't sent there" {
    echo foreign > "$WORK/mode"
    protons
    [ "$status" -eq 1 ]
    [[ "$output" == *"on another host"* ]]
    [[ "$output" != *workload-key* ]]
}

@test "a redirect to another host is refused before the key is sent there" {
    echo redirect > "$WORK/mode"
    protons
    [ "$status" -eq 1 ]
    [[ "$output" == *"a redirect points to another host"* ]]
    [[ "$output" != *workload-key* ]]
}

@test "a relative next-link is followed from the page that gave it" {
    echo relative > "$WORK/mode"
    protons
    [ "$status" -eq 0 ]
    [ "$output" = "new1 running
old1 draining" ]
    [ "$(cat "$WORK/page2")" = /api/v2/workloads/w1/protons/page2 ]

    echo query > "$WORK/mode"
    protons
    [ "$status" -eq 0 ]
    [ "$(cat "$WORK/page2")" = "/api/v2/workloads/w1/protons/?offset=1" ]
}

@test "a later page that fails prints no generation at all, not the first page's" {
    echo broken > "$WORK/mode"
    protons
    [ "$status" -eq 1 ]
    [[ "$output" != *new1* ]]
}

@test "a next-link that never ends stops after a bounded number of pages" {
    echo loop > "$WORK/mode"
    protons
    [ "$status" -eq 1 ]
    [[ "$output" == *"ran past 20 pages"* ]]
}
