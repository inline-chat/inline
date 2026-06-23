import type { InputPeer } from "@inline-chat/protocol/core"
import { eq } from "drizzle-orm"
import { db } from "@in/server/db"
import { chats } from "@in/server/db/schema"
import { findRecoverableChatgptRuns } from "./runRows"
import { interruptRunPlaceholder } from "@in/server/modules/chatgpt/harness/run"
import { Log } from "@in/server/utils/log"

const log = new Log("chatgpt.recovery")

export async function recoverChatgptRunsOnStartup(): Promise<void> {
  const rows = await findRecoverableChatgptRuns({ now: new Date(), limit: 100 })
  if (rows.length === 0) {
    return
  }

  log.info("Recovering interrupted ChatGPT runs", { count: rows.length })

  for (const run of rows) {
    const inputPeer = await inputPeerForRun({
      chatId: run.chatId,
      actorUserId: run.actorUserId,
      botUserId: run.botUserId,
    })
    if (!inputPeer) {
      log.warn("Skipping ChatGPT run recovery because chat is missing", { runId: run.id, chatId: run.chatId })
      continue
    }

    await interruptRunPlaceholder(run.id, inputPeer).catch((error) => {
      log.error("Failed to recover ChatGPT run", { error, runId: run.id })
    })
  }
}

async function inputPeerForRun(input: {
  readonly chatId: number
  readonly actorUserId: number
  readonly botUserId: number
}): Promise<InputPeer | undefined> {
  const [chat] = await db.select().from(chats).where(eq(chats.id, input.chatId)).limit(1)
  if (!chat) {
    return undefined
  }

  if (chat.type === "private") {
    return {
      type: {
        oneofKind: "user",
        user: { userId: BigInt(input.botUserId) },
      },
    }
  }

  return {
    type: {
      oneofKind: "chat",
      chat: { chatId: BigInt(input.chatId) },
    },
  }
}
