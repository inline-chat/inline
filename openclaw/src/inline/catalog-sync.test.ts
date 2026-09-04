import { describe, expect, it, vi } from "vitest"
import { getLastInlineCatalogSyncStatus, syncInlineCatalogs } from "./catalog-sync"

const calls: string[] = []
let releaseFirstCommandSync: (() => void) | undefined

const { syncInlineNativeCommands, syncInlineAgentSkills } = vi.hoisted(() => ({
  syncInlineNativeCommands: vi.fn(async () => {
    calls.push("commands")
    if (!releaseFirstCommandSync) {
      await new Promise<void>((resolve) => {
        releaseFirstCommandSync = resolve
      })
    }
    return { attempted: 1, synced: 1, failed: 0 }
  }),
  syncInlineAgentSkills: vi.fn(async () => {
    calls.push("skills")
    return { attempted: 1, synced: 1, failed: 0 }
  }),
}))

vi.mock("./bot-commands-sync", () => ({ syncInlineNativeCommands }))
vi.mock("./bot-skills-sync", () => ({ syncInlineAgentSkills }))

describe("inline/catalog-sync", () => {
  it("serializes full passes without dropping a change that arrives mid-sync", async () => {
    const first = syncInlineCatalogs({ cfg: {}, reason: "skill_changed" })
    const second = syncInlineCatalogs({ cfg: {}, reason: "manual" })

    await vi.waitFor(() => expect(syncInlineNativeCommands).toHaveBeenCalledTimes(1))
    expect(syncInlineAgentSkills).not.toHaveBeenCalled()

    releaseFirstCommandSync?.()
    const [firstStatus, secondStatus] = await Promise.all([first, second])

    expect(calls).toEqual(["commands", "skills", "commands", "skills"])
    expect(firstStatus.reason).toBe("skill_changed")
    expect(secondStatus.reason).toBe("manual")
    expect(getLastInlineCatalogSyncStatus()).toEqual(secondStatus)
  })
})
