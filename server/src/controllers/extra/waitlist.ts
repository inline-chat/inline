import { Elysia, t } from "elysia"
import { setup } from "@in/server/setup"
import { insertIntoWaitlist } from "@in/server/db/models/waitlist"
import { db } from "@in/server/db"
import { type NewWaitlistSubscriber, waitlist as wdb } from "@in/server/db/schema"
import { sql, count } from "drizzle-orm"
import { ipinfo } from "@in/server/libs/ipinfo"
import { getIp } from "@in/server/utils/ip"
import { Log } from "@in/server/utils/log"
import { sendBotEvent } from "@in/server/modules/bot-events"

export const waitlist = new Elysia({ prefix: "/waitlist" })
  .use(setup)
  .get("/super_secret_sub_count", async () => {
    const [result] = await db.select({ count: count() }).from(wdb)
    return result?.count
  })
  .post(
    "/subscribe",
    async ({ body, request, server }) => {
      await insertIntoWaitlist(body)

      try {
        let location: string | undefined
        try {
          let ip = await getIp(request, server)
          let ipInfo = ip ? await ipinfo(ip) : undefined
          location = `${ipInfo?.country}, ${ipInfo?.city}`
        } catch (error) {
          Log.shared.error("Error getting IP info", { error })
        }

        const message = `New Waitlist Subscriber: \n${body.email} \n(${location}, ${body.timeZone})`
        sendBotEvent(message)
      } catch (error) {
        Log.shared.error("Error sending waitlist alert:", { error })
      }

      return {
        ok: true,
      }
    },
    {
      body: t.Object({
        email: t.String(),
        name: t.Optional(t.String()),
        userAgent: t.Optional(t.String()),
        timeZone: t.Optional(t.String()),
      }),
    },
  )
  .post("/verify", () => "todo")
