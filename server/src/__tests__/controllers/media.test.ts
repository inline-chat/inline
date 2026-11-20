import { describe, expect, it } from "bun:test"
import { setupTestLifecycle } from "@in/server/__tests__/setup"
import { useLiveHttpApp } from "../liveHttpApp"

const app = useLiveHttpApp()

setupTestLifecycle()

describe("media routes", () => {
  it("serves /file route and rejects invalid signatures", async () => {
    const response = await app.handle(new Request("http://localhost/file?id=INPzxcvbnMASDFGHJKLQW12&exp=1&sig=bad"))

    expect(response.status).toBe(403)
  })

  it("does not expose legacy /photos route", async () => {
    const response = await app.handle(
      new Request("http://localhost/photos?id=INPzxcvbnMASDFGHJKLQW12&exp=1&sig=bad"),
    )

    expect(response.status).toBe(404)
  })
})
