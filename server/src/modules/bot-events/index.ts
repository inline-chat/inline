import { Log } from "@in/server/utils/log"

export const sendBotEvent = (text: string) => {
  try {
    const telegramToken = process.env["TELEGRAM_TOKEN"]
    const chatId = "-1002262866594"
    fetch(`https://api.telegram.org/bot${telegramToken}/sendMessage`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        chat_id: chatId,
        text: text,
      }),
    }).catch((error) => {
      Log.shared.error("Failed to send bot event", error)
    })
  } catch (error) {
    Log.shared.error("Failed to send bot event", error)
  }
}
