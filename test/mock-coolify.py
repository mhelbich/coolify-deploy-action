#!/usr/bin/env python3
"""Minimal stand-in for the Coolify API endpoints the action uses.

Usage: mock-coolify.py PORT SCENARIO

Scenarios:
  success      deployment goes queued -> in_progress -> finished
  failed       ... -> failed
  cancelled    ... -> cancelled-by-user
  missing-env  PATCH .../envs returns 404 (variable not defined on the resource)
  stuck        deployment stays in_progress forever (for timeout tests)

Requests must carry "Authorization: Bearer test-token", otherwise 401.
Every received env PATCH body is appended as one JSON line to env-patches.jsonl
in the working directory, so tests can assert on it.
"""

import json
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import parse_qs, urlparse

APP_UUID = "app123"
DEPLOYMENT_UUID = "dep456"
TOKEN = "test-token"

port = int(sys.argv[1])
scenario = sys.argv[2]
polls = 0

TERMINAL = {"success": "finished", "failed": "failed", "cancelled": "cancelled-by-user"}


class Handler(BaseHTTPRequestHandler):
    def send(self, code, payload):
        body = json.dumps(payload).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def authorized(self):
        if self.headers.get("Authorization") != f"Bearer {TOKEN}":
            self.send(401, {"message": "Unauthenticated."})
            return False
        return True

    def do_PATCH(self):
        if not self.authorized():
            return
        if self.path != f"/api/v1/applications/{APP_UUID}/envs":
            return self.send(404, {"message": "Not found."})
        length = int(self.headers.get("Content-Length", 0))
        data = json.loads(self.rfile.read(length))
        with open("env-patches.jsonl", "a") as f:
            f.write(json.dumps(data) + "\n")
        if scenario == "missing-env":
            return self.send(404, {"message": "Environment variable not found."})
        self.send(201, {"uuid": "env789", "key": data["key"], "value": data["value"]})

    def do_GET(self):
        global polls
        if not self.authorized():
            return
        parsed = urlparse(self.path)
        if parsed.path == "/api/v1/deploy":
            if parse_qs(parsed.query).get("uuid") != [APP_UUID]:
                return self.send(404, {"message": "Resource not found."})
            return self.send(200, {
                "deployments": [{
                    "message": f"Application {APP_UUID} deployment queued.",
                    "resource_uuid": APP_UUID,
                    "deployment_uuid": DEPLOYMENT_UUID,
                }]
            })
        if parsed.path == f"/api/v1/deployments/{DEPLOYMENT_UUID}":
            polls += 1
            if polls == 1:
                status = "queued"
            elif polls == 2 or scenario == "stuck":
                status = "in_progress"
            else:
                status = TERMINAL.get(scenario, "finished")
            return self.send(200, {"deployment_uuid": DEPLOYMENT_UUID, "status": status})
        self.send(404, {"message": "Not found."})

    def log_message(self, fmt, *args):
        sys.stderr.write("mock-coolify: " + fmt % args + "\n")


HTTPServer(("127.0.0.1", port), Handler).serve_forever()
