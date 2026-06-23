import { createHash, randomUUID } from "node:crypto"
import type { AgentFinishStreamPart, AgentMediaOutput, AgentStreamPart } from "@inline-chat/agent-core"
import type { ChatgptProviderTool } from "@inline-chat/agent-chatgpt"
import { OPENAI_CODEX_DEFAULT_MODEL } from "@inline-chat/agent-chatgpt"
import type { InputPeer, RichMessage } from "@inline-chat/protocol/core"
import { eq } from "drizzle-orm"
import { CHATGPT_PROVIDER_TOOLS_ENABLED } from "@in/server/env"
import { db } from "@in/server/db"
import { messages } from "@in/server/db/schema"
import { resolveFreshUserCodexConnection } from "@in/server/modules/chatgpt/auth/codexRefresh"
import { buildChatgptPrompt, type ChatgptPrompt } from "@in/server/modules/chatgpt/harness/prompt/builder"
import { userVisibleError } from "@in/server/modules/chatgpt/harness/markdown/inlineMarkdown"
import {
  parseChatgptMarkdownOutput,
} from "@in/server/modules/chatgpt/harness/markdown/outputMarkdown"
import { prepareStreamingRichDraft } from "@in/server/modules/chatgpt/harness/markdown/streamingRichText"
import { pushRichMessageDraftUpdate } from "@in/server/modules/message/richDraftUpdates"
import { editInternalBotMessage, sendInternalBotMessage, sendInternalTyping } from "./messages"
import {
  claimRun,
  heartbeatRun,
  markRunStreaming,
  setRunOutputMessage,
  updateRunStatus,
  getChatgptRun,
} from "@in/server/modules/chatgpt/harness/state/runRows"
import { loadReplayItemsForMessages, saveChatgptProviderState } from "./state/providerState"
import { runCodexResponses } from "./provider/codexTransport"
import { finishActiveRun } from "./runStore"
import { Log } from "@in/server/utils/log"
import { sendChatgptMediaOutput } from "./media/output"

const log = new Log("chatgpt.run")
const leaseOwner = `server_${randomUUID()}`
const LEASE_MS = 45_000
const EDIT_THROTTLE_MS = 550
const HEARTBEAT_MS = 15_000

export async function runChatgptTurn(input: {
  readonly runId: string
  readonly runKey: string
  readonly inputPeer: InputPeer
  readonly actorUserId: number
  readonly botUserId: number
  readonly signal: AbortSignal
}): Promise<void> {
  let visibleText = ""
  let outputMsgGlobalId: bigint | undefined
  let heartbeat: ReturnType<typeof setInterval> | undefined
  let providerContext: Record<string, unknown> = {}

  try {
    const run = await claimRun({
      runId: input.runId,
      leaseOwner,
      leaseMs: LEASE_MS,
    })
    if (!run) {
      log.debug("ChatGPT run claim skipped", { runId: input.runId })
      return
    }
    log.debug("ChatGPT run claimed", {
      runId: input.runId,
      chatId: run.chatId,
      actorUserId: input.actorUserId,
      botUserId: input.botUserId,
      triggerMsgGlobalId: run.triggerMsgGlobalId,
      threadRootMsgId: run.threadRootMsgId,
    })

    heartbeat = setInterval(() => {
      void heartbeatRun({ runId: input.runId, leaseOwner, leaseMs: LEASE_MS }).catch(() => undefined)
    }, HEARTBEAT_MS)

    const connection = await resolveFreshUserCodexConnection(input.actorUserId)
    if (!connection) {
      log.warn("ChatGPT run has no connected Codex account", {
        runId: input.runId,
        actorUserId: input.actorUserId,
      })
      const message = await sendInternalBotMessage({
        inputPeer: input.inputPeer,
        actorUserId: input.actorUserId,
        botUserId: input.botUserId,
        text: userVisibleError("not_connected"),
      })
      await setRunOutputMessage({ runId: input.runId, outputMsgGlobalId: message.globalId })
      await updateRunStatus({ runId: input.runId, status: "failed", errorCode: "not_connected" })
      return
    }

    await sendInternalTyping({
      inputPeer: input.inputPeer,
      actorUserId: input.actorUserId,
      botUserId: input.botUserId,
      typing: true,
    })

    const trigger = run.triggerMsgGlobalId ? await findTriggerMessage(run.triggerMsgGlobalId) : undefined
    const prompt = await buildChatgptPrompt({
      inputPeer: input.inputPeer,
      actorUserId: input.actorUserId,
      botUserId: input.botUserId,
      triggerMessageId: trigger?.messageId ?? 0,
    })
    const replayItems = await loadReplayItemsForMessages({
      outputMsgGlobalIds: prompt.priorOutputMsgGlobalIds,
      connectionId: connection.row.id,
      model: OPENAI_CODEX_DEFAULT_MODEL,
      issuer: "chatgpt_codex",
    })
    const providerTools = providerToolsForRun()
    providerContext = {
      model: OPENAI_CODEX_DEFAULT_MODEL,
      connectionId: connection.row.id,
      providerToolTypes: providerTools.map((tool) => tool.type),
      providerToolCount: providerTools.length,
      replayItemCount: replayItems.length,
      ...summarizePromptForLog(prompt),
    }
    log.info("Starting ChatGPT provider turn", {
      runId: input.runId,
      chatId: run.chatId,
      threadRootMsgId: run.threadRootMsgId,
      actorUserId: input.actorUserId,
      botUserId: input.botUserId,
      hasOutputMessage: !!outputMsgGlobalId,
      ...providerContext,
    })

    const provider = runCodexResponses({
      runId: input.runId,
      connectionId: connection.row.id,
      accessToken: connection.credential.accessToken,
      model: OPENAI_CODEX_DEFAULT_MODEL,
      instructions: prompt.instructions,
      input: prompt.input,
      replayItems,
      providerTools,
      promptCacheKey: buildPromptCacheKey({
        promptVersion: prompt.promptVersion,
        model: OPENAI_CODEX_DEFAULT_MODEL,
        connectionId: connection.row.id,
        runKey: input.runKey,
      }),
      signal: input.signal,
    })

    let finish: AgentFinishStreamPart | undefined
    const mediaOutputs: AgentMediaOutput[] = []
    let lastEditAt = 0
    let lastFlushedStreamingText = ""
    for await (const part of provider.stream) {
      if (input.signal.aborted) {
        throw new DOMException("Run aborted", "AbortError")
      }

      if (part.type === "media") {
        mediaOutputs.push(part.media)
        continue
      }

      const next = handleStreamPart(part)
      if (next.textDelta) {
        visibleText += next.textDelta
        const now = Date.now()
        if (now - lastEditAt >= EDIT_THROTTLE_MS) {
          lastEditAt = now
          const flushed = await flushVisibleText({
            inputPeer: input.inputPeer,
            actorUserId: input.actorUserId,
            botUserId: input.botUserId,
            outputMsgGlobalId,
            text: visibleText,
            runId: input.runId,
            lastText: lastFlushedStreamingText,
          })
          outputMsgGlobalId = flushed.outputMsgGlobalId
          if (flushed.wrote) {
            lastFlushedStreamingText = flushed.text
          }
        }
      }
      if (part.type === "finish") {
        finish = part
      }
    }

    const markdownOutput = parseChatgptMarkdownOutput(visibleText)
    const finalMediaOutputCount = mediaOutputs.length
    let finalText = markdownOutput.text || (finalMediaOutputCount === 0 ? "Done." : "")
    if (finalText) {
      outputMsgGlobalId = await writeVisibleText({
        inputPeer: input.inputPeer,
        actorUserId: input.actorUserId,
        botUserId: input.botUserId,
        outputMsgGlobalId,
        text: finalText,
        runId: input.runId,
      })
    }

    for (const media of mediaOutputs) {
      const result = await sendChatgptMediaOutput({
        media,
        inputPeer: input.inputPeer,
        actorUserId: input.actorUserId,
        botUserId: input.botUserId,
      })
      if (!outputMsgGlobalId && result.outputMsgGlobalId) {
        outputMsgGlobalId = result.outputMsgGlobalId
        await setRunOutputMessage({ runId: input.runId, outputMsgGlobalId })
      }
    }

    if (!outputMsgGlobalId && !finalText) {
      outputMsgGlobalId = await writeVisibleText({
        inputPeer: input.inputPeer,
        actorUserId: input.actorUserId,
        botUserId: input.botUserId,
        outputMsgGlobalId,
        text: "Done.",
        runId: input.runId,
      })
    }

    if (finish?.provider?.encryptedItems && finish.provider.encryptedItems.length > 0 && outputMsgGlobalId) {
      await saveChatgptProviderState({
        runId: input.runId,
        outputMsgGlobalId,
        connectionId: connection.row.id,
        model: provider.model,
        issuer: finish.provider.issuer ?? "chatgpt_codex",
        responseId: finish.provider.responseId,
        items: finish.provider.encryptedItems,
      })
    }

    await updateRunStatus({
      runId: input.runId,
      status: "succeeded",
      visibleTextLength: finalText.length,
    })
    log.info("ChatGPT turn succeeded", {
      runId: input.runId,
      outputMsgGlobalId: outputMsgGlobalId?.toString(),
      model: provider.model,
      responseId: finish?.provider?.responseId,
      encryptedItemCount: finish?.provider?.encryptedItems?.length ?? 0,
      mediaOutputCount: finalMediaOutputCount,
      visibleTextLength: finalText.length,
    })
  } catch (error) {
    const canceled = input.signal.aborted
    if (outputMsgGlobalId) {
      await editInternalBotMessage({
        inputPeer: input.inputPeer,
        actorUserId: input.actorUserId,
        botUserId: input.botUserId,
        outputMsgGlobalId,
        text: canceled ? userVisibleError("canceled") : userVisibleError("provider_error"),
      }).catch(() => undefined)
    } else if (!canceled) {
      const message = await sendInternalBotMessage({
        inputPeer: input.inputPeer,
        actorUserId: input.actorUserId,
        botUserId: input.botUserId,
        text: userVisibleError("provider_error"),
      })
      outputMsgGlobalId = message.globalId
      await setRunOutputMessage({ runId: input.runId, outputMsgGlobalId }).catch(() => undefined)
    }

    await updateRunStatus({
      runId: input.runId,
      status: canceled ? "canceled" : "failed",
      errorCode: canceled ? "canceled" : "provider_error",
      errorMessage: error instanceof Error ? error.message : String(error),
      visibleTextLength: visibleText.length,
    }).catch(() => undefined)

    if (!canceled) {
      log.error("ChatGPT turn failed", {
        error,
        runId: input.runId,
        outputMsgGlobalId: outputMsgGlobalId?.toString(),
        visibleTextLength: visibleText.length,
        ...providerContext,
      })
    } else {
      log.info("ChatGPT turn canceled", {
        runId: input.runId,
        outputMsgGlobalId: outputMsgGlobalId?.toString(),
        visibleTextLength: visibleText.length,
      })
    }
  } finally {
    if (heartbeat) {
      clearInterval(heartbeat)
    }
    await sendInternalTyping({
      inputPeer: input.inputPeer,
      actorUserId: input.actorUserId,
      botUserId: input.botUserId,
      typing: false,
    }).catch(() => undefined)
    finishActiveRun(input.runId)
  }
}

export async function interruptRunPlaceholder(runId: string, inputPeer: InputPeer): Promise<void> {
  const run = await getChatgptRun(runId)
  if (!run) {
    return
  }

  if (run.outputMsgGlobalId) {
    await editInternalBotMessage({
      inputPeer,
      actorUserId: run.actorUserId,
      botUserId: run.botUserId,
      outputMsgGlobalId: run.outputMsgGlobalId,
      text: "ChatGPT was interrupted during a server restart. Send another message to continue.",
    }).catch(() => undefined)
  }

  await updateRunStatus({
    runId,
    status: "interrupted",
    errorCode: "server_restart",
    errorMessage: "Interrupted during server restart",
  })
}

async function flushVisibleText(input: {
  readonly inputPeer: InputPeer
  readonly actorUserId: number
  readonly botUserId: number
  readonly outputMsgGlobalId?: bigint
  readonly text: string
  readonly lastText: string
  readonly runId: string
}): Promise<{
  readonly outputMsgGlobalId?: bigint
  readonly text: string
  readonly wrote: boolean
}> {
  const draft = prepareStreamingRichDraft(input.text, input.lastText)
  if (!draft || !draft.changed) {
    return {
      outputMsgGlobalId: input.outputMsgGlobalId,
      text: input.lastText,
      wrote: false,
    }
  }

  const outputMsgGlobalId = await writeStreamingVisibleText({
    ...input,
    text: draft.text,
    richText: draft.richText,
  })
  return {
    outputMsgGlobalId,
    text: draft.text,
    wrote: true,
  }
}

async function writeStreamingVisibleText(input: {
  readonly inputPeer: InputPeer
  readonly actorUserId: number
  readonly botUserId: number
  readonly outputMsgGlobalId?: bigint
  readonly text: string
  readonly richText: RichMessage
  readonly runId: string
}): Promise<bigint> {
  return writeStreamingVisibleTextWithDeps(input, defaultStreamingVisibleTextDeps)
}

type StreamingVisibleTextDeps = {
  readonly sendMessage: StreamingSendMessage
  readonly editMessage: typeof editInternalBotMessage
  readonly pushDraft: typeof pushChatgptRichDraft
  readonly setOutputMessage: typeof setRunOutputMessage
  readonly markStreaming: typeof markRunStreaming
}

type StreamingSendMessage = (
  input: Parameters<typeof sendInternalBotMessage>[0],
) => Promise<{ readonly globalId: bigint; readonly messageId: number }>

const defaultStreamingVisibleTextDeps: StreamingVisibleTextDeps = {
  sendMessage: sendInternalBotMessage,
  editMessage: editInternalBotMessage,
  pushDraft: pushChatgptRichDraft,
  setOutputMessage: setRunOutputMessage,
  markStreaming: markRunStreaming,
}

async function writeStreamingVisibleTextWithDeps(
  input: {
    readonly inputPeer: InputPeer
    readonly actorUserId: number
    readonly botUserId: number
    readonly outputMsgGlobalId?: bigint
    readonly text: string
    readonly richText: RichMessage
    readonly runId: string
  },
  deps: StreamingVisibleTextDeps,
): Promise<bigint> {
  const text = input.text
  const richText = input.richText
  const fallback = richText.fallbackText

  if (!input.outputMsgGlobalId) {
    const message = await deps.sendMessage({
      inputPeer: input.inputPeer,
      actorUserId: input.actorUserId,
      botUserId: input.botUserId,
      text: fallback,
      richText,
      allowThinking: true,
      resolveRichMedia: false,
    })
    await deps.pushDraft({
      inputPeer: input.inputPeer,
      actorUserId: input.actorUserId,
      botUserId: input.botUserId,
      runId: input.runId,
      messageId: BigInt(message.messageId),
      richText,
    })
    await deps.setOutputMessage({ runId: input.runId, outputMsgGlobalId: message.globalId })
    await deps.markStreaming({ runId: input.runId, visibleTextLength: text.length })
    return message.globalId
  }

  await deps.pushDraft({
    inputPeer: input.inputPeer,
    actorUserId: input.actorUserId,
    botUserId: input.botUserId,
    runId: input.runId,
    richText,
  })
  await deps.markStreaming({ runId: input.runId, visibleTextLength: text.length })
  return input.outputMsgGlobalId
}

export const chatgptRunTestHooks = {
  writeStreamingVisibleText: writeStreamingVisibleTextWithDeps,
}

async function writeVisibleText(input: {
  readonly inputPeer: InputPeer
  readonly actorUserId: number
  readonly botUserId: number
  readonly outputMsgGlobalId?: bigint
  readonly text: string
  readonly runId: string
}): Promise<bigint> {
  if (!input.outputMsgGlobalId) {
    const message = await sendInternalBotMessage({
      inputPeer: input.inputPeer,
      actorUserId: input.actorUserId,
      botUserId: input.botUserId,
      text: input.text,
    })
    await clearChatgptRichDraft({
      inputPeer: input.inputPeer,
      actorUserId: input.actorUserId,
      botUserId: input.botUserId,
      runId: input.runId,
      messageId: BigInt(message.messageId),
    })
    await setRunOutputMessage({ runId: input.runId, outputMsgGlobalId: message.globalId })
    await markRunStreaming({ runId: input.runId, visibleTextLength: input.text.length })
    logFinalRichDelivery({
      runId: input.runId,
      outputMsgGlobalId: message.globalId,
      messageId: message.messageId,
      delivery: "send",
      visibleTextLength: input.text.length,
    })
    return message.globalId
  }

  await editInternalBotMessage({
    inputPeer: input.inputPeer,
    actorUserId: input.actorUserId,
    botUserId: input.botUserId,
    outputMsgGlobalId: input.outputMsgGlobalId,
    text: input.text,
  })
  await clearChatgptRichDraft({
    inputPeer: input.inputPeer,
    actorUserId: input.actorUserId,
    botUserId: input.botUserId,
    runId: input.runId,
  })
  await markRunStreaming({ runId: input.runId, visibleTextLength: input.text.length })
  logFinalRichDelivery({
    runId: input.runId,
    outputMsgGlobalId: input.outputMsgGlobalId,
    delivery: "edit",
    visibleTextLength: input.text.length,
  })
  return input.outputMsgGlobalId
}

function logFinalRichDelivery(input: {
  readonly runId: string
  readonly outputMsgGlobalId: bigint
  readonly messageId?: number
  readonly delivery: "send" | "edit"
  readonly visibleTextLength: number
}): void {
  log.info("ChatGPT final rich delivery", {
    runId: input.runId,
    outputMsgGlobalId: input.outputMsgGlobalId.toString(),
    ...(input.messageId !== undefined ? { messageId: input.messageId } : {}),
    delivery: input.delivery,
    parseRichMarkdown: true,
    visibleTextLength: input.visibleTextLength,
  })
}

async function pushChatgptRichDraft(input: {
  readonly inputPeer: InputPeer
  readonly actorUserId: number
  readonly botUserId: number
  readonly runId: string
  readonly richText: RichMessage
  readonly messageId?: bigint
}): Promise<void> {
  await pushRichMessageDraftUpdate({
    inputPeer: input.inputPeer,
    currentUserId: input.actorUserId,
    senderUserId: input.botUserId,
    draftId: chatgptRichDraftId(input.runId),
    richText: input.richText,
    messageId: input.messageId,
  })
}

async function clearChatgptRichDraft(input: {
  readonly inputPeer: InputPeer
  readonly actorUserId: number
  readonly botUserId: number
  readonly runId: string
  readonly messageId?: bigint
}): Promise<void> {
  await pushRichMessageDraftUpdate({
    inputPeer: input.inputPeer,
    currentUserId: input.actorUserId,
    senderUserId: input.botUserId,
    draftId: chatgptRichDraftId(input.runId),
    messageId: input.messageId,
    clear: true,
  })
}

function chatgptRichDraftId(runId: string): string {
  return `chatgpt:${runId}`
}

function handleStreamPart(part: AgentStreamPart): { readonly textDelta?: string } {
  if (part.type === "text_delta") {
    return { textDelta: part.text }
  }
  if (part.type === "error") {
    throw new Error(part.message)
  }
  return {}
}

function providerToolsForRun(): readonly ChatgptProviderTool[] {
  const value = CHATGPT_PROVIDER_TOOLS_ENABLED?.trim().toLowerCase()
  if (value === "false" || value === "0") {
    return []
  }

  return [
    { type: "web_search" },
    { type: "image_generation", action: "auto", outputFormat: "png", partialImages: 1 },
    { type: "code_interpreter", container: "auto" },
  ]
}

function summarizePromptForLog(prompt: ChatgptPrompt): Record<string, unknown> {
  const roles: Record<string, number> = {}
  const partTypes: Record<string, number> = {}
  const fileKinds: Record<string, number> = {}
  let textCharCount = 0
  let signedUrlFileCount = 0
  let unavailableFileCount = 0

  for (const message of prompt.input) {
    roles[message.role] = (roles[message.role] ?? 0) + 1
    for (const part of message.parts) {
      partTypes[part.type] = (partTypes[part.type] ?? 0) + 1
      if (part.type === "text") {
        textCharCount += part.text.length
        continue
      }
      if (part.type === "file") {
        fileKinds[part.file.kind] = (fileKinds[part.file.kind] ?? 0) + 1
        signedUrlFileCount += part.file.signedUrl ? 1 : 0
        unavailableFileCount += part.file.signedUrl ? 0 : 1
      }
    }
  }

  return {
    promptVersion: prompt.promptVersion,
    inputMessageCount: prompt.input.length,
    inputRoles: roles,
    inputPartTypes: partTypes,
    inputFileKinds: fileKinds,
    inputTextCharCount: textCharCount,
    signedUrlFileCount,
    unavailableFileCount,
    priorOutputMsgCount: prompt.priorOutputMsgGlobalIds.length,
  }
}

function buildPromptCacheKey(input: {
  readonly promptVersion: string
  readonly model: string
  readonly connectionId: number
  readonly runKey: string
}): string {
  const hash = createHash("sha256")
    .update(`${input.connectionId}:${input.runKey}`)
    .digest("base64url")
    .slice(0, 32)
  return `inline:${input.promptVersion}:${input.model}:${hash}`
}

async function findTriggerMessage(globalId: bigint): Promise<{ readonly messageId: number } | undefined> {
  const [row] = await db.select({ messageId: messages.messageId }).from(messages).where(eq(messages.globalId, globalId)).limit(1)
  return row
}
