import { and, eq, inArray } from "drizzle-orm"
import { CHATGPT_CONNECTION_PROVIDER } from "@inline-chat/agent-chatgpt"
import { db } from "@in/server/db"
import { internalAgentProviderStates, type DbInternalAgentProviderState } from "@in/server/db/schema"
import { Encryption2 } from "@in/server/modules/encryption/encryption2"

export type ChatgptReplayState = {
  readonly responseId?: string
  readonly items: readonly unknown[]
}

export async function saveChatgptProviderState(input: {
  readonly runId: string
  readonly outputMsgGlobalId: bigint
  readonly connectionId: number
  readonly model: string
  readonly issuer: string
  readonly responseId?: string
  readonly items: readonly unknown[]
}): Promise<void> {
  if (input.items.length === 0 && !input.responseId) {
    return
  }

  await db
    .insert(internalAgentProviderStates)
    .values({
      runId: input.runId,
      provider: CHATGPT_CONNECTION_PROVIDER,
      issuer: input.issuer,
      model: input.model,
      responseId: input.responseId,
      connectionId: input.connectionId,
      outputMsgGlobalId: input.outputMsgGlobalId,
      encryptedStateCiphertext: encryptJson({
        responseId: input.responseId,
        items: input.items,
      } satisfies ChatgptReplayState),
      encryptedItemCount: input.items.length,
    })
    .onConflictDoUpdate({
      target: [internalAgentProviderStates.runId, internalAgentProviderStates.provider],
      set: {
        issuer: input.issuer,
        model: input.model,
        responseId: input.responseId,
        connectionId: input.connectionId,
        outputMsgGlobalId: input.outputMsgGlobalId,
        encryptedStateCiphertext: encryptJson({
          responseId: input.responseId,
          items: input.items,
        } satisfies ChatgptReplayState),
        encryptedItemCount: input.items.length,
      },
    })
}

export async function loadReplayItemsForMessages(input: {
  readonly outputMsgGlobalIds: readonly bigint[]
  readonly connectionId: number
  readonly model: string
  readonly issuer: string
}): Promise<unknown[]> {
  if (input.outputMsgGlobalIds.length === 0) {
    return []
  }

  const rows = await db
    .select()
    .from(internalAgentProviderStates)
    .where(
      and(
        eq(internalAgentProviderStates.provider, CHATGPT_CONNECTION_PROVIDER),
        eq(internalAgentProviderStates.connectionId, input.connectionId),
        eq(internalAgentProviderStates.model, input.model),
        eq(internalAgentProviderStates.issuer, input.issuer),
        inArray(internalAgentProviderStates.outputMsgGlobalId, [...input.outputMsgGlobalIds]),
      ),
    )

  return rows.flatMap(decodeItems)
}

function decodeItems(row: DbInternalAgentProviderState): unknown[] {
  try {
    const state = JSON.parse(Encryption2.decryptToString(Buffer.from(row.encryptedStateCiphertext))) as ChatgptReplayState
    return Array.isArray(state.items) ? [...state.items] : []
  } catch {
    return []
  }
}

function encryptJson(value: unknown): Buffer {
  return Encryption2.encrypt(Buffer.from(JSON.stringify(value), "utf8"))
}
