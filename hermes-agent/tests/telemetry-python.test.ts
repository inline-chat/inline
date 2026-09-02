import { spawnSync } from "node:child_process"
import path from "node:path"
import { fileURLToPath } from "node:url"
import { describe, expect, it } from "vitest"

const packageRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..")
const python = spawnSync("which", ["python3"], { encoding: "utf8" }).stdout.trim() || "python3"

describe("Hermes Python adapter error telemetry", () => {
  it("sends raw exception paths without credentials or user context", () => {
    const script = String.raw`
import json
import importlib.util
import os
import socket
import sys
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer

telemetry_path = ${JSON.stringify(path.join(packageRoot, "plugin", "inline", "telemetry.py"))}
spec = importlib.util.spec_from_file_location("inline_telemetry_test", telemetry_path)
telemetry = importlib.util.module_from_spec(spec)
spec.loader.exec_module(telemetry)
capture_plugin_error = telemetry.capture_plugin_error

received = []
class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        size = int(self.headers.get("content-length") or "0")
        received.append(self.rfile.read(size).decode("utf-8"))
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b"{}")
    def log_message(self, *_args):
        pass

server = HTTPServer(("127.0.0.1", 0), Handler)
thread = threading.Thread(target=server.handle_request, daemon=True)
thread.start()
secret = "private-hermes-token"
os.environ["NODE_ENV"] = "test"
os.environ["INLINE_HERMES_SENTRY_DSN"] = f"http://fixture@127.0.0.1:{server.server_port}/123"
os.environ["INLINE_TOKEN"] = secret
try:
    raise RuntimeError(f"failed at /Users/mo/private/adapter.py with Bearer {secret}")
except Exception as error:
    sender = capture_plugin_error("adapter.inbound", error, secrets=(secret,))
    if sender:
        sender.join(3)
thread.join(3)
server.server_close()
os.environ.pop("INLINE_HERMES_SENTRY_DSN", None)
default_disabled = capture_plugin_error("adapter.inbound", RuntimeError("not sent"))
os.environ["INLINE_HERMES_SENTRY_DSN"] = "http://fixture@127.0.0.1:1/123"
os.environ["INLINE_PLUGIN_TELEMETRY"] = "off"
disabled = capture_plugin_error("adapter.inbound", RuntimeError("not sent"))
print(json.dumps({
    "received": received,
    "default_disabled": default_disabled is None,
    "disabled": disabled is None,
}))
`
    const result = spawnSync(python, ["-c", script], {
      cwd: packageRoot,
      encoding: "utf8",
      env: { ...process.env, NODE_ENV: "test" },
    })
    expect(result.status, result.stderr).toBe(0)
    const output = JSON.parse(result.stdout) as {
      received: string[]
      default_disabled: boolean
      disabled: boolean
    }
    const { received } = output
    expect(output.default_disabled).toBe(true)
    expect(output.disabled).toBe(true)
    expect(received).toHaveLength(1)
    const lines = received[0]!.split("\n").map((line) => JSON.parse(line) as Record<string, unknown>)
    expect(lines).toHaveLength(3)
    expect(lines[1]).toMatchObject({ type: "event" })
    expect(lines[2]).toMatchObject({
      platform: "python",
      logger: "inline.hermes.plugin",
      tags: { operation: "adapter.inbound", component: "adapter" },
    })
    expect(received[0]).toContain("/Users/mo/private/adapter.py")
    expect(received[0]).not.toContain("private-hermes-token")
    expect(received[0]).not.toContain("breadcrumbs")
    expect(received[0]).not.toContain("request\"")
    expect(received[0]).not.toContain("user\"")
  })
})
