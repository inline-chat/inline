import { afterEach, describe, expect, it } from "vitest"
import { mutateInlineLiveConfig, resetInlineLiveConfigForTest, resolveInlineLiveConfig } from "./live-config"

describe("inline/live-config", () => {
  afterEach(() => resetInlineLiveConfigForTest())

  it("serves the committed chat setting until the host snapshot changes", async () => {
    const hostSnapshot = { channels: { inline: {} } } as any
    const writes: unknown[] = []
    const next = await mutateInlineLiveConfig({
      current: () => hostSnapshot,
      mutateConfigFile: async ({ afterWrite, mutate }) => {
        writes.push(afterWrite)
        const draft = structuredClone(hostSnapshot)
        mutate(draft)
        return { nextConfig: draft }
      },
    }, (draft: any) => {
      draft.channels.inline.groups = { "7": { replyThreadMode: "on" } }
    })

    expect(writes).toEqual([expect.objectContaining({ mode: "none" })])
    expect(resolveInlineLiveConfig(hostSnapshot)).toBe(next)
    expect((resolveInlineLiveConfig(hostSnapshot) as any).channels.inline.groups["7"].replyThreadMode).toBe("on")

    // A reload or restart replaces the host snapshot, which already has the write.
    const reloaded = { channels: { inline: { groups: { "7": { replyThreadMode: "on" } } } } }
    expect(resolveInlineLiveConfig(reloaded)).toBe(reloaded)
  })
})
