import { describe, expect, it } from "vitest"
import { HttpServerResponse } from "effect/unstable/http"
import { webResponseToHttpServerResponse } from "./webResponse"

describe("webResponseToHttpServerResponse", () => {
  it("preserves distinct cookies without changing missing content-type behavior", async () => {
    const input = new Response(new Uint8Array([1, 2, 3]), {
      headers: { "cache-control": "no-store" },
    })
    input.headers.append("set-cookie", "first=one; Path=/; HttpOnly")
    input.headers.append("set-cookie", "second=two; Path=/; Secure")

    const output = HttpServerResponse.toWeb(
      webResponseToHttpServerResponse(input),
    )

    expect(output.headers.getSetCookie()).toEqual([
      "first=one; Path=/; HttpOnly",
      "second=two; Path=/; Secure",
    ])
    expect(output.headers.get("content-type")).toBeNull()
    expect(new Uint8Array(await output.arrayBuffer())).toEqual(new Uint8Array([1, 2, 3]))
  })
})
