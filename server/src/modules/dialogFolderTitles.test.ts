import { afterEach, describe, expect, mock, test } from "bun:test"
import { eq } from "drizzle-orm"
import { db } from "@in/server/db"
import { dialogFolders } from "@in/server/db/schema"
import { setupTestLifecycle, testUtils } from "@in/server/__tests__/setup"

const parseCompletion = mock()

mock.module("@in/server/libs/openAI", () => ({
  openaiClient: {
    chat: { completions: { parse: parseCompletion } },
  },
}))

const completion = (title: string) => ({
  choices: [{ finish_reason: "stop", message: { parsed: { title } } }],
})

describe("dialog folder title generation", () => {
  setupTestLifecycle()

  afterEach(() => {
    parseCompletion.mockReset()
  })

  test("sets a generated title only while the folder title is null", async () => {
    parseCompletion.mockResolvedValue(completion("Favorite Teammates"))
    const user = await testUtils.createUser("dialog-folder-title@example.com")
    const [folder] = await db
      .insert(dialogFolders)
      .values({ userId: user.id, title: null, order: "a" })
      .returning()
    if (!folder) throw new Error("Failed to create folder")

    const { generateAndApplyDialogFolderTitle } = await import("@in/server/modules/dialogFolderTitles")
    const generated = await generateAndApplyDialogFolderTitle({
      folderId: folder.id,
      userId: user.id,
      peerNames: ["Alice", "Bob", "Carol"],
    })
    expect(generated.didUpdate).toBe(true)
    expect(
      (await db.select().from(dialogFolders).where(eq(dialogFolders.id, folder.id)).limit(1))[0]?.title,
    ).toBe("Favorite Teammates")

    await db.update(dialogFolders).set({ title: "My People" }).where(eq(dialogFolders.id, folder.id))
    parseCompletion.mockResolvedValue(completion("Late Model Result"))
    const stale = await generateAndApplyDialogFolderTitle({
      folderId: folder.id,
      userId: user.id,
      peerNames: ["Alice", "Bob", "Carol"],
    })
    expect(stale.didUpdate).toBe(false)
    expect(
      (await db.select().from(dialogFolders).where(eq(dialogFolders.id, folder.id)).limit(1))[0]?.title,
    ).toBe("My People")
  })
})
