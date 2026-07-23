import type { RpcResult } from "@inline-chat/protocol/core"
import type {
  ChatID,
  MessageID,
  SpaceID,
  UserID,
} from "@inline/ids"
import type { Transaction } from "./transactions"
import type { RealtimeConnectionState } from "./types"

/**
 * View-facing realtime boundary. The direct RealtimeClient and the
 * SharedWorker renderer client both implement this contract.
 */
export interface RealtimeService {
  readonly connectionState: RealtimeConnectionState
  start(): Promise<void>
  stop(): Promise<void>
  execute(
    transaction: Transaction,
  ): Promise<RpcResult["result"] | undefined>
  query(
    transaction: Transaction,
  ): Promise<RpcResult["result"] | undefined>
  mutate(
    transaction: Transaction,
  ): Promise<RpcResult["result"] | undefined>
  /** Resolve after a replay-safe mutation's local outbox commit, not its RPC. */
  mutateAccepted(transaction: Transaction): Promise<void>
  /** InlineKit createThreadLocally semantics, owned by the account core. */
  createThread(input: CreateThreadInput): Promise<ChatID>
  resendMessage(
    chatId: ChatID,
    messageId: MessageID,
  ): Promise<RpcResult["result"] | undefined>
  onConnectionState(
    listener: (state: RealtimeConnectionState) => void,
  ): () => void
}

export type CreateThreadInput = {
  title?: string
  emoji?: string
  isPublic: boolean
  spaceId?: SpaceID
  participants: UserID[]
}
