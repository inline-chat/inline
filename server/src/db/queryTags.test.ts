import { describe, expect, test } from "bun:test"
import { accessQueryComment } from "./databaseDiagnostics"
import { tagQuery, withQueryTags } from "./queryTags"

describe("query tags", () => {
  test("leave queries untouched outside a tagged scope", () => {
    expect(tagQuery("select 1")).toBe("select 1")
  })

  test("append one SQLCommenter comment with sorted keys", () => {
    const tagged = withQueryTags({ rpc: "http", oauth_client: "other:msgvault" }, () => tagQuery("select 1  "))
    expect(tagged).toBe("select 1 /*oauth_client='other:msgvault',rpc='http'*/")
  })

  test("extend an existing trailing SQLCommenter comment instead of adding a second", () => {
    const query = `select 1 ${accessQueryComment("authorization")}`
    const tagged = withQueryTags({ oauth_client: "chatgpt" }, () => tagQuery(query))
    expect(tagged).toBe("select 1 /*application='inline-server',operation='chat_access',source='authorization',oauth_client='chatgpt'*/")
  })

  test("do not merge into an ordinary comment", () => {
    const tagged = withQueryTags({ rpc: "http" }, () => tagQuery("select 1 /* note */"))
    expect(tagged).toBe("select 1 /* note */ /*rpc='http'*/")
  })

  test("drop keys and values that are not bounded labels", () => {
    const tagged = withQueryTags({ rpc: "http", "bad key": "x", evil: "x'*/; drop table users; --", empty: "" }, () => tagQuery("select 1"))
    expect(tagged).toBe("select 1 /*rpc='http'*/")
    expect(withQueryTags({ evil: "a b" }, () => tagQuery("select 1"))).toBe("select 1")
  })

  test("nest scopes and follow async continuations", async () => {
    const tagged = await withQueryTags({ rpc: "http" }, async () => {
      await Promise.resolve()
      return withQueryTags({ oauth_client: "claude" }, async () => {
        await new Promise((resolve) => setTimeout(resolve, 1))
        return tagQuery("select 1")
      })
    })
    expect(tagged).toBe("select 1 /*rpc='http',oauth_client='claude'*/")
  })
})
