import { Elysia, t } from "elysia"
import { setup } from "@in/server/setup"
import { insertIntoWaitlist } from "@in/server/db/models/waitlist"

export const waitlist = new Elysia({ prefix: "/waitlist" })
  .use(setup)
  .post(
    "/subscribe",
    async ({ body }) => {
      await insertIntoWaitlist(body)

      try {
        // Send user data to Telegram API
        const telegramToken = process.env["TELEGRAM_TOKEN"]
        const chatId = "-1002262866594"
        const emailParts = body.email?.split("@")
        const nameFromEmail = emailParts?.[0]?.replace(/[^a-zA-Z0-9]/g, " ")
        const message = `New Subscriber: \n\nEmail: ${body.email} \nName: ${nameFromEmail} \nTime Zone: ${body.timeZone} \n\n\n☕️ SHIP FASTER DENA & MO!!!`
        let result = await fetch(`https://api.telegram.org/bot${telegramToken}/sendMessage`, {
          method: "POST",
          headers: {
            "Content-Type": "application/json",
          },
          body: JSON.stringify({
            chat_id: chatId,
            text: message,
          }),
        })
        console.log("Message sent to Telegram:", await result.json())
      } catch (error) {
        console.error("Error sending message to Telegram:", error)
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
