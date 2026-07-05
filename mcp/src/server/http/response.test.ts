import { describe, expect, it } from "vitest"
import { badRequest, html, notFound, text, unauthorized, withJson } from "./response"

describe("http responses", () => {
  it("text sets content-type", async () => {
    const res = text(200, "ok")
    expect(res.status).toBe(200)
    expect(res.headers.get("content-type")).toContain("text/plain")
    expect(await res.text()).toBe("ok")
  })

  it("html sets content-type", async () => {
    const res = html(200, "<h1>ok</h1>")
    expect(res.status).toBe(200)
    expect(res.headers.get("content-type")).toContain("text/html")
    expect(await res.text()).toBe("<h1>ok</h1>")
  })

  it("withJson serializes", async () => {
    const res = withJson({ ok: true })
    expect(res.status).toBe(200)
    expect(res.headers.get("content-type")).toContain("application/json")
    expect(await res.json()).toEqual({ ok: true })
  })

  it("badRequest returns oauth-style body", async () => {
    const res = badRequest("nope")
    expect(res.status).toBe(400)
    expect(await res.json()).toEqual({ error: "bad_request", error_description: "nope" })
  })

  it("unauthorized returns oauth-style body", async () => {
    const res = unauthorized("nope")
    expect(res.status).toBe(401)
    expect(await res.json()).toEqual({ error: "unauthorized", error_description: "nope" })
  })

  it("notFound is plain text", async () => {
    const res = notFound()
    expect(res.status).toBe(404)
    expect(await res.text()).toBe("Not found")
  })
})

