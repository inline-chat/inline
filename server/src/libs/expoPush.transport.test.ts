import { expect, it } from "bun:test"
import { gunzipSync } from "node:zlib"
import { Expo, type ExpoPushMessage, type ExpoPushTicket } from "expo-server-sdk"

it("preserves Expo JSON transport, compression and error responses on Bun", async () => {
  const seen: { authorization: string | null; encoding: string | null; body: unknown }[] = []
  const server = Bun.serve({
    hostname: "127.0.0.1",
    port: 0,
    async fetch(request) {
      const encoding = request.headers.get("content-encoding")
      const bytes = Buffer.from(await request.arrayBuffer())
      seen.push({
        authorization: request.headers.get("authorization"),
        encoding,
        body: JSON.parse((encoding === "gzip" ? gunzipSync(bytes) : bytes).toString()),
      })
      return request.url.endsWith("/reject")
        ? Response.json({ errors: [{ code: "PUSH_TOO_MANY_NOTIFICATIONS", message: "Synthetic rejection" }] }, { status: 400 })
        : Response.json({ data: [{ status: "ok", id: "synthetic-ticket" }] })
    },
  })
  const expo = new Expo({ accessToken: "synthetic" })
  // The public API fixes Expo's production URL. Exercise its real transport against localhost instead.
  const transport = expo as unknown as {
    requestAsync(url: string, options: {
      httpMethod: "post"
      body: ExpoPushMessage[]
      shouldCompress: (body: string) => boolean
    }): Promise<ExpoPushTicket[]>
  }
  const message = { to: "ExponentPushToken[synthetic]", body: "synthetic notification" }
  const send = (path: string, body: string) => transport.requestAsync(new URL(path, server.url).href, {
    httpMethod: "post",
    body: [{ ...message, body }],
    shouldCompress: (json) => json.length > 1024,
  })
  try {
    expect(await send("/send", message.body)).toEqual([{ status: "ok", id: "synthetic-ticket" }])
    expect(await send("/send", "x".repeat(2048))).toEqual([{ status: "ok", id: "synthetic-ticket" }])
    await expect(send("/reject", message.body)).rejects.toMatchObject({
      code: "PUSH_TOO_MANY_NOTIFICATIONS", message: "Synthetic rejection", statusCode: 400,
    })
    expect(seen).toEqual([
      { authorization: "Bearer synthetic", encoding: null, body: [message] },
      { authorization: "Bearer synthetic", encoding: "gzip", body: [{ ...message, body: "x".repeat(2048) }] },
      { authorization: "Bearer synthetic", encoding: null, body: [message] },
    ])
  } finally {
    await server.stop(true)
  }
})
