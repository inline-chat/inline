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

telemetry_path = ${JSON.stringify(path.join(packageRoot, "plugin", "inline", "telemetry.py"))}
spec = importlib.util.spec_from_file_location("inline_telemetry_test", telemetry_path)
telemetry = importlib.util.module_from_spec(spec)
spec.loader.exec_module(telemetry)

received = []
class Response:
    def __enter__(self):
        return self
    def __exit__(self, *_args):
        return False
    def read(self, _size):
        return b"{}"

class Opener:
    def open(self, request, timeout):
        assert timeout == 2.0
        received.append(request.data.decode("utf-8"))
        return Response()

telemetry.urllib.request.build_opener = lambda *_args: Opener()
secret = "private-hermes-token"
dsn = "http://fixture@127.0.0.1:4318/123"
event_env = {"INLINE_HERMES_SENTRY_DSN": dsn, "INLINE_TOKEN": secret}
try:
    raise RuntimeError(f"failed at /Users/mo/private/adapter.py with Bearer {secret}")
except Exception as error:
    event = telemetry.build_sentry_event(
        "adapter.inbound", error, env=event_env, secrets=(secret,)
    )
target = telemetry._sentry_target(dsn)
assert target is not None
telemetry._send_envelope(target, dsn, event)
default_disabled = telemetry._resolve_dsn({}) == ""
disabled = telemetry._resolve_dsn({
    "INLINE_HERMES_SENTRY_DSN": dsn,
    "INLINE_PLUGIN_TELEMETRY": "off",
}) == ""
print(json.dumps({
    "received": received,
    "default_disabled": default_disabled,
    "disabled": disabled,
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
