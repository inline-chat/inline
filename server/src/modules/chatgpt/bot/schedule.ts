import { createHash } from "node:crypto"
import type { InputPeer, MessageEntities } from "@inline-chat/protocol/core"
import { CHATGPT_AGENT_KEY } from "@inline-chat/agent-chatgpt"
import { CHATGPT_BOT_ENABLED } from "@in/server/env"
import type { DbChat, DbMessage } from "@in/server/db/schema"
import { Log } from "@in/server/utils/log"
import { getOfficialInternalBot } from "@in/server/modules/internalAgents/officialBots"
import { detectChatgptTrigger } from "./triggers"
import { cancelActiveRunKey, registerActiveRun, setActiveRunTimer } from "@in/server/modules/chatgpt/harness/runStore"
import {
  createChatgptRun,
  markRunDebouncing,
  requestCancelRunsForKey,
  updateRunStatus,
} from "@in/server/modules/chatgpt/harness/state/runRows"
import { runChatgptTurn } from "@in/server/modules/chatgpt/harness/run"

const log = new Log("chatgpt.schedule")
const DEBOUNCE_MS = 650

export async function maybeScheduleChatgptBot(input: {
  readonly chat: DbChat
  readonly message: DbMessage
  readonly text?: string
  readonly entities?: MessageEntities
  readonly inputPeer: InputPeer
  readonly actorUserId: number
}): Promise<void> {
  if (!isChatgptBotEnabled()) {
    return
  }

  const bot = await getOfficialInternalBot(CHATGPT_AGENT_KEY)
  if (!bot) {
    log.error("ChatGPT official bot is not provisioned")
    return
  }

  const trigger = await detectChatgptTrigger({
    ...input,
    botUserId: bot.botUserId,
  })
  if (!trigger) {
    return
  }

  if (trigger.kind === "stop") {
    log.info("ChatGPT stop trigger detected", {
      chatId: input.chat.id,
      actorUserId: input.actorUserId,
      messageGlobalId: input.message.globalId,
      threadRootMsgId: trigger.threadRootMsgId,
      runKeyHash: hashRunKey(trigger.runKey),
    })
    await stopRunKey({ runKey: trigger.runKey, actorUserId: input.actorUserId })
    return
  }

  log.debug("ChatGPT message trigger detected", {
    chatId: input.chat.id,
    actorUserId: input.actorUserId,
    messageGlobalId: input.message.globalId,
    threadRootMsgId: trigger.threadRootMsgId,
    reason: trigger.reason,
    alias: trigger.alias,
    runKeyHash: hashRunKey(trigger.runKey),
  })

  await stopRunKey({ runKey: trigger.runKey, actorUserId: input.actorUserId })

  const run = await createChatgptRun({
    runKey: trigger.runKey,
    actorUserId: input.actorUserId,
    botUserId: bot.botUserId,
    chatId: input.chat.id,
    threadRootMsgId: trigger.threadRootMsgId,
    triggerMsgGlobalId: input.message.globalId,
  })

  if (!run) {
    log.warn("ChatGPT run was not created", {
      chatId: input.chat.id,
      actorUserId: input.actorUserId,
      messageGlobalId: input.message.globalId,
      runKeyHash: hashRunKey(trigger.runKey),
    })
    return
  }

  await markRunDebouncing(run.id)
  const controller = new AbortController()
  registerActiveRun({
    runId: run.id,
    runKey: trigger.runKey,
    controller,
  })

  const timer = setTimeout(() => {
    void runChatgptTurn({
      runId: run.id,
      runKey: trigger.runKey,
      inputPeer: trigger.inputPeer,
      actorUserId: input.actorUserId,
      botUserId: bot.botUserId,
      signal: controller.signal,
    }).catch((error) => {
      log.error("ChatGPT run failed", { error, runId: run.id, chatId: input.chat.id })
    })
  }, DEBOUNCE_MS)
  setActiveRunTimer(run.id, timer)
  log.debug("ChatGPT run scheduled", {
    runId: run.id,
    chatId: input.chat.id,
    actorUserId: input.actorUserId,
    debounceMs: DEBOUNCE_MS,
    runKeyHash: hashRunKey(trigger.runKey),
  })
}

export async function stopRunKey(input: {
  readonly runKey: string
  readonly actorUserId: number
}): Promise<void> {
  const activeRunId = cancelActiveRunKey(input.runKey)
  const ids = await requestCancelRunsForKey({
    runKey: input.runKey,
    actorUserId: input.actorUserId,
  })

  if (activeRunId || ids.length > 0) {
    log.info("Canceling ChatGPT runs for key", {
      actorUserId: input.actorUserId,
      runKeyHash: hashRunKey(input.runKey),
      activeRunId,
      persistedRunCount: ids.length,
    })
  }

  for (const runId of new Set([...ids, activeRunId].filter((id): id is string => !!id))) {
    await updateRunStatus({
      runId,
      status: "canceled",
      errorCode: "canceled",
      errorMessage: "Canceled by user",
    })
  }
}

function isChatgptBotEnabled(): boolean {
  const value = CHATGPT_BOT_ENABLED?.trim().toLowerCase()
  return value !== "false" && value !== "0"
}

function hashRunKey(runKey: string): string {
  return createHash("sha256").update(runKey).digest("base64url").slice(0, 16)
}
