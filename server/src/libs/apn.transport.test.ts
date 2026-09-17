import { expect, it } from "bun:test"
import { generateKeyPairSync, verify } from "node:crypto"
import { createServer, type IncomingHttpHeaders, type ServerHttp2Session } from "node:http2"
import APN from "apn"

it("preserves APNs JWT, HTTP/2 payload and failure contracts on Bun", async () => {
  const { privateKey, publicKey } = generateKeyPairSync("ec", { namedCurve: "prime256v1" })
  const seen: { headers: IncomingHttpHeaders; body: string }[] = []
  const sessions = new Set<ServerHttp2Session>()
  const server = createServer()
  server.on("session", (session) => { sessions.add(session); session.on("close", () => sessions.delete(session)) })
  server.on("stream", (stream, headers) => {
    let body = ""
    stream.setEncoding("utf8")
    stream.on("data", (chunk: string) => { body += chunk })
    stream.on("end", () => {
      seen.push({ headers, body })
      if (headers[":path"]?.endsWith("b".repeat(64))) {
        stream.respond({ ":status": 410, "content-type": "application/json" })
        stream.end(JSON.stringify({ reason: "Unregistered", timestamp: 1 }))
      } else { stream.respond({ ":status": 200 }); stream.end() }
    })
  })
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve))
  const address = server.address()
  if (!address || typeof address === "string") throw new Error("No test address")
  const provider = new APN.Provider({
    address: "127.0.0.1", port: address.port,
    token: { key: privateKey.export({ type: "pkcs8", format: "pem" }), keyId: "TESTKEY", teamId: "TESTTEAM" },
    production: false,
  })
  try {
    // The library supplies this seam for its local HTTP/2 mock. No Apple connection is made.
    const client = (provider as unknown as { client: { _mockOverrideUrl: string } }).client
    client._mockOverrideUrl = `http://127.0.0.1:${address.port}`
    const notification = new APN.Notification()
    notification.topic = "chat.inline.test"
    notification.pushType = "alert"
    notification.alert = "synthetic test"
    notification.payload = { recipientUserId: "1" }
    const result = await provider.send(notification, ["a".repeat(64), "b".repeat(64)])
    expect(result.failed.map((failure) => ({ status: failure.status, error: failure.error?.message, reason: failure.response?.reason }))).toEqual([{ status: 410, error: undefined, reason: "Unregistered" }])
    expect(result.sent).toHaveLength(1)
    expect(result.failed).toHaveLength(1)
    expect(result.failed[0]).toMatchObject({ status: 410, response: { reason: "Unregistered" } })
    expect(seen).toHaveLength(2)
    const request = seen[0]!
    expect(request.headers["apns-topic"]).toBe("chat.inline.test")
    expect(request.headers["apns-push-type"]).toBe("alert")
    expect(JSON.parse(request.body)).toMatchObject({ recipientUserId: "1", aps: { alert: "synthetic test" } })
    const jwt = String(request.headers.authorization).replace(/^bearer /, "")
    const [header, payload, signature] = jwt.split(".")
    expect(JSON.parse(Buffer.from(header!, "base64url").toString())).toMatchObject({ alg: "ES256", kid: "TESTKEY" })
    expect(JSON.parse(Buffer.from(payload!, "base64url").toString())).toMatchObject({ iss: "TESTTEAM" })
    expect(verify("sha256", Buffer.from(`${header}.${payload}`), { key: publicKey, dsaEncoding: "ieee-p1363" },
      Buffer.from(signature!, "base64url"))).toBe(true)
  } finally {
    provider.shutdown()
    for (const session of sessions) session.destroy()
    await new Promise<void>((resolve) => server.close(() => resolve()))
  }
})
