import { describe, expect, test } from "bun:test"
import { fetchLinearPreview, parseLinearUrl } from "./index.js"

const token = { provider: "linear", accessToken: "secret-token" }

describe("linear authenticated preview provider", () => {
  test("accepts only clean issue URLs", () => {
    expect(parseLinearUrl("https://linear.app/inline/issue/ENG-42/fix-compose")?.meta).toEqual({
      workspace: "inline",
      identifier: "ENG-42",
    })
    expect(parseLinearUrl("https://linear.app/inline/issue/ENG-42")).not.toBeNull()
    expect(parseLinearUrl("https://linear.app/inline/issue/ENG-42/activity")).not.toBeNull()
    expect(parseLinearUrl("https://linear.app/inline/issue/ENG-42?subIssue=ENG-3")).toBeNull()
    expect(parseLinearUrl("https://linear.app/inline/issue/ENG-42#comment-1")).toBeNull()
    expect(parseLinearUrl("https://linear.app/inline/project/ENG/all")).toBeNull()
    expect(parseLinearUrl("https://linear.app/inline/issue/ENG-42/files/spec.pdf")).toBeNull()
  })

  test("fetches a compact issue title", async () => {
    const parsed = parseLinearUrl("https://linear.app/inline/issue/ENG-42/fix-compose")
    expect(parsed).not.toBeNull()
    if (!parsed) return

    let request: RequestInit | undefined
    const result = await fetchLinearPreview(parsed, token, {
      fetchImpl: async (url, init) => {
        expect(String(url)).toBe("https://api.linear.app/graphql")
        request = init
        return Response.json({
          data: {
            issue: {
              identifier: "ENG-42",
              title: "Fix compose substitutions",
              url: parsed.normalizedUrl,
            },
          },
        })
      },
    })

    expect(request?.method).toBe("POST")
    expect(request?.headers).toMatchObject({
      Authorization: "Bearer secret-token",
      "Content-Type": "application/json",
    })
    expect(result).toMatchObject({
      provider: "linear",
      providerResourceType: "linear.issue",
      title: "ENG-42 · Fix compose substitutions",
    })
  })

  test("does not return another issue", async () => {
    const parsed = parseLinearUrl("https://linear.app/inline/issue/ENG-42")
    expect(parsed).not.toBeNull()
    if (!parsed) return

    const result = await fetchLinearPreview(parsed, token, {
      fetchImpl: async () => Response.json({
        data: { issue: { identifier: "ENG-43", title: "Different issue" } },
      }),
    })
    expect(result).toBeNull()
  })
})
