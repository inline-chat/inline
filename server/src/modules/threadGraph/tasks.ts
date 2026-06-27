import { Log } from "@in/server/utils/log"
import {
  materializeReplyThreadLink,
  replaceMessageThreadLinks,
  type MaterializeReplyThreadInput,
  type ReplaceMessageThreadLinksInput,
} from "./links"

const log = new Log("threadGraph.tasks")

export function queueReplyThreadGraphMaterialization(input: MaterializeReplyThreadInput): void {
  queueMicrotask(() => {
    void materializeReplyThreadLink(input).catch((error) => {
      log.error("Failed to materialize reply-thread graph link", {
        replyThreadId: input.replyThread.id,
        parentChatId: input.replyThread.parentChatId,
        parentMessageId: input.replyThread.parentMessageId,
        error,
      })
    })
  })
}

export function queueMessageThreadLinkMaterialization(input: ReplaceMessageThreadLinksInput): void {
  queueMicrotask(() => {
    void replaceMessageThreadLinks(input).catch((error) => {
      log.error("Failed to materialize message thread graph links", {
        sourceChatId: input.sourceChatId,
        sourceMessageGlobalId: input.sourceMessageGlobalId,
        sourceMessageId: input.sourceMessageId,
        sourceMessageRevision: input.sourceMessageRevision,
        error,
      })
    })
  })
}
