import { applicationBackgroundWork } from "@in/server/lifecycle/backgroundWork"
import { Log } from "@in/server/utils/log"
import {
  materializeReplyThreadLink,
  replaceMessageThreadLinks,
  type MaterializeReplyThreadInput,
  type ReplaceMessageThreadLinksInput,
} from "./links"

const log = new Log("threadGraph.tasks")

export function queueReplyThreadGraphMaterialization(input: MaterializeReplyThreadInput): void {
  const work = Promise.resolve().then(() => materializeReplyThreadLink(input)).catch((error) => {
    log.error("Failed to materialize reply-thread graph link", {
      replyThreadId: input.replyThread.id,
      parentChatId: input.replyThread.parentChatId,
      parentMessageId: input.replyThread.parentMessageId,
      error,
    })
  })
  // Register before the worker starts so an immediate shutdown joins queued work.
  applicationBackgroundWork.track(work)
}

export function queueMessageThreadLinkMaterialization(input: ReplaceMessageThreadLinksInput): void {
  const work = Promise.resolve().then(() => replaceMessageThreadLinks(input)).catch((error) => {
    log.error("Failed to materialize message thread graph links", {
      sourceChatId: input.sourceChatId,
      sourceMessageGlobalId: input.sourceMessageGlobalId,
      sourceMessageId: input.sourceMessageId,
      sourceMessageRevision: input.sourceMessageRevision,
      error,
    })
  })
  // Register before the worker starts so an immediate shutdown joins queued work.
  applicationBackgroundWork.track(work)
}
