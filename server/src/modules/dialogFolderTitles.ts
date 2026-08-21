import type { ChatModel } from "openai/resources/chat/chat.mjs"
import { zodResponseFormat } from "openai/helpers/zod"
import { z } from "zod/v4"
import { and, eq, isNull } from "drizzle-orm"
import { db } from "@in/server/db"
import { dialogFolders, users } from "@in/server/db/schema"
import { openaiClient } from "@in/server/libs/openAI"
import {
  enqueueDialogFolderUpdate,
  pushDialogFolderUpdate,
} from "@in/server/modules/dialogFolders"
import { Encoders } from "@in/server/realtime/encoders/encoders"
import { Log } from "@in/server/utils/log"

const log = new Log("modules.dialogFolderTitles")
const MODEL: ChatModel = "gpt-5.6-luna" as ChatModel
const MAX_TITLE_CHARS = 80
const titleSchema = z.object({ title: z.string() })

export function maybeScheduleDialogFolderTitleGeneration(input: {
  folderId: number
  userId: number
  peerNames: string[]
}): void {
  if (input.peerNames.length === 0) return

  void generateAndApplyDialogFolderTitle(input).catch((error) => {
    log.warn("Dialog folder title generation failed", {
      folderId: input.folderId,
      userId: input.userId,
      error,
    })
  })
}

export async function generateAndApplyDialogFolderTitle(input: {
  folderId: number
  userId: number
  peerNames: string[]
}): Promise<{ didUpdate: boolean }> {
  if (!openaiClient || input.peerNames.length === 0) {
    return { didUpdate: false }
  }

  const completion = await openaiClient.chat.completions.parse({
    model: MODEL,
    verbosity: "low",
    reasoning_effort: "none",
    messages: [
      {
        role: "system",
        content:
          "Name a personal chat folder from the provided teammate display names. " +
          "Use a concise, natural label of 2-5 words. Do not add quotes, emoji, commentary, or private inferences.",
      },
      { role: "user", content: input.peerNames.join("\n") },
    ],
    response_format: zodResponseFormat(titleSchema, "dialogFolderTitle"),
  })

  const title = normalizeGeneratedTitle(completion.choices[0]?.message.parsed?.title)
  if (!title) return { didUpdate: false }

  const result = await db.transaction(async (tx) => {
    await tx.select({ id: users.id }).from(users).where(eq(users.id, input.userId)).for("update").limit(1)
    const [folder] = await tx
      .update(dialogFolders)
      .set({ title })
      .where(
        and(
          eq(dialogFolders.id, input.folderId),
          eq(dialogFolders.userId, input.userId),
          isNull(dialogFolders.title),
        ),
      )
      .returning()
    if (!folder) return undefined

    const encodedFolder = Encoders.dialogFolder(folder)
    const persisted = await enqueueDialogFolderUpdate({
      tx,
      userId: input.userId,
      folderChange: { oneofKind: "folder", folder: encodedFolder },
      dialogs: [],
    })
    return persisted.update
  })

  if (!result) return { didUpdate: false }
  pushDialogFolderUpdate(input.userId, result)
  return { didUpdate: true }
}

function normalizeGeneratedTitle(value: string | undefined): string | undefined {
  const title = value?.replace(/^[`"'“”‘’]+|[`"'“”‘’]+$/g, "").replace(/\s+/g, " ").trim()
  if (!title || Array.from(title).length > MAX_TITLE_CHARS) return undefined
  return title
}
