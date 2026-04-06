import { describe, expect, it } from "bun:test"
import { media } from "@in/server/controllers/media"
import Elysia from "elysia"

describe("media controller", () => {
  it("serves /file route and rejects invalid signatures", async () => {
    const isolated = new Elysia().use(media)
    const response = await isolated.handle(new Request("http://localhost/file?id=INPzxcvbnMASDFGHJKLQW12&exp=1&sig=bad"))

    expect(response.status).toBe(403)
  })

  it("does not expose legacy /photos route", async () => {
    const isolated = new Elysia().use(media)
    const response = await isolated.handle(
      new Request("http://localhost/photos?id=INPzxcvbnMASDFGHJKLQW12&exp=1&sig=bad"),
    )

    expect(response.status).toBe(404)
  })
})
