import { describe, expect, test } from "vitest"
import {
  privateSpaceJoinReference,
  publicSpaceJoinReference,
  spaceJoinDeepLink,
  spaceJoinPageResponse,
} from "./spaceJoinPage"

describe("space join landing page", () => {
  test("renders a server-resolved name into visible and preview metadata only", async () => {
    let request: Request | undefined
    const response = await spaceJoinPageResponse(
      publicSpaceJoinReference("TownHall"),
      true,
      {
        apiBaseUrl: "https://api.inline.test/v1/",
        fetch: async (input, init) => {
          request = new Request(input, init)
          return Response.json({ name: 'Town & <Hall> "HQ"' })
        },
      },
    )
    expect(response.status).toBe(200)
    expect(response.headers.get("cache-control")).toBe("private, no-store")
    const html = await response.text()
    expect(html).toContain("<title>Join Town &amp; &lt;Hall&gt; &quot;HQ&quot; on Inline</title>")
    expect(html).toContain('property="og:title" content="Join Town &amp; &lt;Hall&gt; &quot;HQ&quot; on Inline"')
    expect(html).toContain("You’re invited to join Town &amp; &lt;Hall&gt; &quot;HQ&quot; on Inline.")
    expect(html).toContain('href="in://join/public/TownHall"')
    expect(html.match(/<a /g)).toHaveLength(1)
    expect(await request?.json()).toEqual({ kind: "public_handle", value: "TownHall" })
    expect(request?.url).toBe("https://api.inline.test/v1/space-join/resolve")
  })

  test("uses a POST body for private tokens and returns one neutral unavailable page", async () => {
    const token = `iv1_${"a".repeat(43)}`
    let body: unknown
    const response = await spaceJoinPageResponse(
      privateSpaceJoinReference(token),
      true,
      {
        apiBaseUrl: "https://api.inline.test/v1",
        fetch: async (_input, init) => {
          body = JSON.parse(String(init?.body))
          return new Response(null, { status: 404 })
        },
      },
    )
    expect(body).toEqual({ kind: "invite_token", value: token })
    expect(response.status).toBe(404)
    const html = await response.text()
    expect(html).toContain("<title>Invite unavailable · Inline</title>")
    expect(html).not.toContain("<a ")
  })

  test("accepts only the v0.1 reference formats", () => {
    expect(publicSpaceJoinReference("@town-hall")).toEqual({
      kind: "public_handle",
      value: "town-hall",
    })
    expect(publicSpaceJoinReference("a")).toBeNull()
    expect(privateSpaceJoinReference(`iv1_${"_".repeat(43)}`)).not.toBeNull()
    expect(privateSpaceJoinReference("iv1_short")).toBeNull()
    expect(spaceJoinDeepLink({ kind: "invite_token", value: `iv1_${"-".repeat(43)}` }))
      .toBe(`in://join/invite/iv1_${"-".repeat(43)}`)
  })
})
