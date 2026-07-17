import { Layer } from "effect"
import { db } from "@in/server/db"
import {
  insertIntoWaitlist,
} from "@in/server/db/models/waitlist"
import {
  waitlist,
} from "@in/server/db/schema"
import { ipinfo } from "@in/server/libs/ipinfo"
import {
  sendBotEvent,
} from "@in/server/modules/bot-events"
import { Log } from "@in/server/utils/log"
import { count } from "drizzle-orm"
import {
  WaitlistOperations,
  makeWaitlistOperations,
} from "./waitlist.effect"

export const WaitlistOperationsLive = Layer.succeed(
  WaitlistOperations,
  makeWaitlistOperations({
    count: async () => {
      const [result] = await db
        .select({ count: count() })
        .from(waitlist)
      return result?.count ?? 0
    },
    insert: insertIntoWaitlist,
    notify: async (input, clientIp) => {
      let location: string | undefined
      try {
        const info =
          clientIp === undefined
            ? undefined
            : await ipinfo(clientIp)
        location = `${info?.country}, ${info?.city}`
      } catch (cause) {
        Log.shared.error("Error getting IP info", {
          error: cause,
        })
      }

      sendBotEvent(
        `New Waitlist Subscriber: \n${input.email} \n(${location}, ${input.timeZone})`,
      )
    },
    noteNotificationFailure: (cause) => {
      Log.shared.error(
        "Error sending waitlist alert:",
        { error: cause },
      )
    },
  }),
)
