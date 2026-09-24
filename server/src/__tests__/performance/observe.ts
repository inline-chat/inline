import { spyOn } from "bun:test"
import { MessageModel } from "@in/server/db/models/messages"
import { BotUpdatesModel } from "@in/server/db/models/botUpdates"
import { Notifications } from "@in/server/modules/notifications/notifications"
import * as titles from "@in/server/modules/threadTitles"
import * as links from "@in/server/modules/threadGraph/links"
import * as parents from "@in/server/modules/subthreadParentMaterialization"
import * as subthreads from "@in/server/modules/subthreads"
import { trackBackgroundWork } from "../background"

/** Observe real functions, without substituting domain behavior. The registry's
 * silent, human-only, named-thread fixtures have no provider work or Bot streams.
 * The projector's two reads complete its no-stream branch. Adding Bot/media/title
 * scenarios requires observing their full jobs here before measuring them. */
export function observeScenarioWork() {
  const work = trackBackgroundWork()
  // Capture originals before spyOn mutates the module's live bindings.
  const tracked = {
    messageLinks: work.wrap(links.replaceMessageThreadLinks),
    replyLink: work.wrap(links.materializeReplyThreadLink),
    firstMessage: work.wrap(parents.materializeFirstMessageExperience),
    parentUpdate: work.wrap(subthreads.emitMessageSubthreadUpdateIfNeeded),
    title: work.wrap(titles.maybeScheduleThreadTitleGeneration),
    message: work.wrap(MessageModel.getMessage),
    streams: work.wrap(BotUpdatesModel.getStreamsForBotUserIds),
    readNotification: work.wrap(Notifications.sendMessagesReadUpToToUser),
  }
  const spies = [
    spyOn(links, "replaceMessageThreadLinks").mockImplementation(tracked.messageLinks),
    spyOn(links, "materializeReplyThreadLink").mockImplementation(tracked.replyLink),
    spyOn(parents, "materializeFirstMessageExperience").mockImplementation(tracked.firstMessage),
    spyOn(subthreads, "emitMessageSubthreadUpdateIfNeeded").mockImplementation(tracked.parentUpdate),
    spyOn(titles, "maybeScheduleThreadTitleGeneration").mockImplementation(tracked.title),
    spyOn(MessageModel, "getMessage").mockImplementation(tracked.message),
    spyOn(BotUpdatesModel, "getStreamsForBotUserIds").mockImplementation(tracked.streams),
    spyOn(Notifications, "sendMessagesReadUpToToUser").mockImplementation(tracked.readNotification),
  ]
  return {
    drain: work.drain,
    async close() {
      try { await work.drain() } finally { for (const spy of spies) spy.mockRestore() }
    },
  }
}
