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

# Routing of docker/nginx.conf, run for real in front of two stand-in upstreams
# that answer with their own name and the path they received. The platform's
# readiness probe hits /health on the nginx port, so /health has to reach the
# gateway: the web UI would answer 200 for it and hide a dead gateway.

setup_file() {
    mkdir -p /tmp/nginx
    cat > /tmp/upstream.py <<'PY'
import http.server
import sys

NAME, PORT = sys.argv[1], int(sys.argv[2])


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        body = f"{NAME} {self.path}".encode()
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


http.server.HTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
PY
    # Fd 3 is bats' own; a background job that keeps it open blocks the run.
    python3 /tmp/upstream.py gateway 8643 > /dev/null 2>&1 3>&- &
    python3 /tmp/upstream.py webui 8787 > /dev/null 2>&1 3>&- &
    /usr/sbin/nginx -e /dev/stderr -c /repo/docker/nginx.conf > /dev/null 2>&1 3>&- &
    # Both upstreams must answer before nginx can: a 502 is still a response.
    for port in 8643 8787 8642; do
        for _ in $(seq 50); do
            curl -sf -o /dev/null "http://127.0.0.1:$port/" && continue 2
            sleep 0.2
        done
        return 1
    done
}

teardown_file() {
    pkill -f /tmp/upstream.py || true
    pkill -x nginx || true
}

# route PATH: what the nginx port answers for PATH.
route() {
    curl -s -m 5 "http://127.0.0.1:8642$1"
}

@test "/health reaches the gateway, not the web UI" {
    [ "$(route /health)" = "gateway /health" ]
}

@test "/health/detailed reaches the gateway" {
    [ "$(route /health/detailed)" = "gateway /health/detailed" ]
}

@test "the OpenAI-compatible API under /v1 reaches the gateway" {
    [ "$(route /v1/models)" = "gateway /v1/models" ]
}

@test "the jobs API reaches the gateway" {
    [ "$(route /api/jobs)" = "gateway /api/jobs" ]
}

@test "any other path reaches the web UI" {
    [ "$(route /)" = "webui /" ]
    [ "$(route /static/app.js)" = "webui /static/app.js" ]
}
