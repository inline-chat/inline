import { describe, expect, test } from "bun:test"
import { isLegacyFileUploadRequest, limitHttpRequestBody } from "./requestBodyLimit"

describe("HTTP request body limits", () => {
  test("only the legacy POST upload route receives the larger listener allowance", () => {
    expect(isLegacyFileUploadRequest(new Request("http://inline.test/v1/uploadFile", { method: "POST" }))).toBe(true)
    for (const [path, method] of [["/v1/uploadFile", "GET"], ["/v1/sendMessage", "POST"], ["/v1/uploadFile/extra", "POST"]]) {
      expect(isLegacyFileUploadRequest(new Request(`http://inline.test${path}`, { method }))).toBe(false)
    }
  })

  test("rejects declared oversized non-upload bodies before consumption", () => {
    let consumed = false
    const guarded = limitHttpRequestBody(new Request("http://inline.test/v1/sendMessage", {
      method: "POST", headers: { "content-length": "4" },
      body: new ReadableStream<Uint8Array>({ pull() { consumed = true } }, { highWaterMark: 0 }),
    }), 3)
    expect(guarded).toBeInstanceOf(Response)
    expect((guarded as Response).status).toBe(413)
    expect(consumed).toBe(false)
  })

  test("bounds chunked compatibility JSON bodies and cancels the request on overflow", async () => {
    const guarded = limitHttpRequestBody(new Request("http://inline.test/v1/sendMessage", {
      method: "POST", headers: { "content-type": "application/json" },
      body: new ReadableStream<Uint8Array>({
        start(controller) { controller.enqueue(new Uint8Array(4)); controller.close() },
      }),
    }), 3)
    if (guarded instanceof Response) throw new Error("Unexpected preflight failure")
    const read = guarded.request.text()
    await expect(read).rejects.toThrow("Request body too large")
    expect((await guarded.limitReached).status).toBe(413)
    expect(guarded.request.signal.aborted).toBe(true)
  })

  test("preserves bodies and carrier cancellation within the limit", async () => {
    const controller = new AbortController()
    const guarded = limitHttpRequestBody(new Request("http://inline.test/v1/sendMessage", {
      method: "POST", body: "abc", signal: controller.signal,
    }), 3)
    if (guarded instanceof Response) throw new Error("Unexpected preflight failure")
    expect(await guarded.request.text()).toBe("abc")
    const reason = new DOMException("disconnected", "AbortError")
    controller.abort(reason)
    expect(guarded.request.signal.reason).toBe(reason)
  })
})
