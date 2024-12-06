import { Elysia, t } from "elysia"
import { setup } from "@in/server/setup"
import { insertIntoWaitlist } from "@in/server/db/models/waitlist"
import { db } from "@in/server/db"
import { type NewWaitlistSubscriber, waitlist as wdb } from "@in/server/db/schema"
import { sql, count } from "drizzle-orm"
import { ipinfo } from "@in/server/libs/ipinfo"
import { getIp } from "@in/server/utils/ip"
import { Log } from "@in/server/utils/log"

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
        // Send user data to Telegram API
        const telegramToken = process.env["TELEGRAM_TOKEN"]
        const chatId = "-1002262866594"

        let location: string | undefined
        try {
          let ip = await getIp(request, server)
          let ipInfo = ip ? await ipinfo(ip) : undefined
          location = `${ipInfo?.country}, ${ipInfo?.city}`
        } catch (error) {
          Log.shared.error("Error getting IP info", { error })
        }

        const message = `New Waitlist Subscriber: \n${body.email} \n(${location}, ${body.timeZone})`

        await fetch(`https://api.telegram.org/bot${telegramToken}/sendMessage`, {
          method: "POST",
          headers: {
            "Content-Type": "application/json",
          },
          body: JSON.stringify({
            chat_id: chatId,
            text: message,
          }),
        })
      } catch (error) {
        Log.shared.error("Error sending message to Telegram:", { error })
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
