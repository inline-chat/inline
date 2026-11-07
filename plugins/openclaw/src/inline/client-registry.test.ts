import { afterEach, describe, expect, it, vi } from "vitest"

const created: Array<{ connect: ReturnType<typeof vi.fn>; close: ReturnType<typeof vi.fn> }> = []

let failNextConnect = false

vi.mock("@inline-chat/realtime-sdk", () => ({
  InlineSdkClient: class {
    connect = vi.fn(async () => {
      if (failNextConnect) {
        failNextConnect = false
        throw new Error("offline")
      }
    })
    close = vi.fn(async () => {})
    constructor() {
      created.push(this)
    }
  },
}))

const {
  acquireInlineAccountClient,
  resetSharedInlineClientsForTest,
  shareInlineAccountClient,
  withInlineAccountClient,
} = await import("./client-registry.js")

const account = { accountId: "default", baseUrl: "https://api.inline.chat", token: "t1" }

afterEach(() => {
  resetSharedInlineClientsForTest()
  created.length = 0
})

describe("inline client registry", () => {
  it("reuses the monitor's client and never closes it", async () => {
    const monitorClient = { close: vi.fn() } as any
    shareInlineAccountClient({ ...account, client: monitorClient })

    const seen = await withInlineAccountClient(account, async (client) => client)

    expect(seen).toBe(monitorClient)
    expect(created).toHaveLength(0)
    expect(monitorClient.close).not.toHaveBeenCalled()
  })

  it("opens and closes a short-lived client when no monitor is running", async () => {
    await withInlineAccountClient(account, async () => "ok")

    expect(created).toHaveLength(1)
    expect(created[0]?.connect).toHaveBeenCalledTimes(1)
    expect(created[0]?.close).toHaveBeenCalledTimes(1)
  })

  it("doesn't reuse a client shared under another token or server", async () => {
    shareInlineAccountClient({ ...account, client: {} as any })

    await withInlineAccountClient({ ...account, token: "t2" }, async () => {})
    await withInlineAccountClient({ ...account, baseUrl: "https://staging.inline.chat" }, async () => {})

    expect(created).toHaveLength(2)
  })

  it("stops sharing once the monitor unshares, even for a lease taken before", async () => {
    const unshare = shareInlineAccountClient({ ...account, client: {} as any })
    const lease = await acquireInlineAccountClient(account)
    unshare()
    await lease.release()

    await withInlineAccountClient(account, async () => {})

    expect(created).toHaveLength(1)
  })

  it("keeps a newer monitor's client when an older one unshares", async () => {
    const unshareOld = shareInlineAccountClient({ ...account, client: { id: "old" } as any })
    const newer = { id: "new" } as any
    shareInlineAccountClient({ ...account, client: newer })
    unshareOld()

    const seen = await withInlineAccountClient(account, async (client) => client)

    expect(seen).toBe(newer)
  })

  it("closes a client whose connect failed", async () => {
    failNextConnect = true

    await expect(withInlineAccountClient(account, async () => {})).rejects.toThrow("offline")
    expect(created[0]?.close).toHaveBeenCalledTimes(1)
  })
})
