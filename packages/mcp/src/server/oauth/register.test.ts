import { describe, expect, it } from "vitest"
import { createApp } from "../app"

describe("oauth register", () => {
  it("rejects non-POST methods", async () => {
    const app = createApp()
    const res = await app.fetch(new Request("http://localhost/oauth/register"))
    expect(res.status).toBe(404)
  })

  it("accepts http://localhost redirect uris (dev)", async () => {
    const app = createApp()
    const res = await app.fetch(
      new Request("http://localhost/oauth/register", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ redirect_uris: ["http://localhost:3000/cb"] }),
      }),
    )
    expect(res.status).toBe(201)
    const body = await res.json()
    expect(body.redirect_uris).toEqual(["http://localhost:3000/cb"])
  })

  it("rejects invalid json", async () => {
    const app = createApp()
    const res = await app.fetch(
      new Request("http://localhost/oauth/register", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: "{",
      }),
    )
    expect(res.status).toBe(400)
  })

  it("rejects non-object json", async () => {
    const app = createApp()
    const res = await app.fetch(
      new Request("http://localhost/oauth/register", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify("nope"),
      }),
    )
    expect(res.status).toBe(400)
  })

  it("rejects missing redirect_uris", async () => {
    const app = createApp()
    const res = await app.fetch(
      new Request("http://localhost/oauth/register", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({}),
      }),
    )
    expect(res.status).toBe(400)
    expect((await res.json()).error).toBe("bad_request")
  })

  it("rejects empty redirect_uris", async () => {
    const app = createApp()
    const res = await app.fetch(
      new Request("http://localhost/oauth/register", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ redirect_uris: [] }),
      }),
    )
    expect(res.status).toBe(400)
  })

  it("rejects non-string redirect_uris", async () => {
    const app = createApp()
    const res = await app.fetch(
      new Request("http://localhost/oauth/register", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ redirect_uris: [123] }),
      }),
    )
    expect(res.status).toBe(400)
  })

  it("rejects empty redirect uri strings", async () => {
    const app = createApp()
    const res = await app.fetch(
      new Request("http://localhost/oauth/register", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ redirect_uris: ["   "] }),
      }),
    )
    expect(res.status).toBe(400)
  })

  it("rejects invalid and disallowed redirect uris", async () => {
    const app = createApp()

    const invalid = await app.fetch(
      new Request("http://localhost/oauth/register", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ redirect_uris: ["not a url"] }),
      }),
    )
    expect(invalid.status).toBe(400)

    const disallowedScheme = await app.fetch(
      new Request("http://localhost/oauth/register", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ redirect_uris: ["ftp://example.com/cb"] }),
      }),
    )
    expect(disallowedScheme.status).toBe(400)

    const disallowedHttp = await app.fetch(
      new Request("http://localhost/oauth/register", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ redirect_uris: ["http://example.com/cb"] }),
      }),
    )
    expect(disallowedHttp.status).toBe(400)
  })

  it("trims client_name", async () => {
    const app = createApp()
    const res = await app.fetch(
      new Request("http://localhost/oauth/register", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ redirect_uris: ["https://example.com/cb"], client_name: "  Name  " }),
      }),
    )
    const body = await res.json()
    expect(body.client_name).toBe("Name")
  })
})
