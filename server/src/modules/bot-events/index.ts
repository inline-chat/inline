import { Log } from "@in/server/utils/log"
import { API_BASE_URL, INLINE_ALERTS_BOT_TOKEN, INLINE_ALERTS_CHAT_ID, TELEGRAM_ALERTS_CHAT_ID, TELEGRAM_TOKEN } from "@in/server/env"

export const sendBotEvent = (text: string) => {
  // Fire-and-forget. These notifications are best-effort and should never affect the caller.
  void sendTelegramBotEvent(text)
  void sendInlineBotEvent(text)
}

export const sendInlineOnlyBotEvent = (text: string) => {
  // Internal alerts path: avoid forwarding sensitive admin details to third-party channels.
  void sendInlineBotEvent(text)
}

const DEFAULT_TELEGRAM_ALERTS_CHAT_ID = "-1002262866594"

async function sendTelegramBotEvent(text: string) {
  const telegramToken = TELEGRAM_TOKEN
  if (!telegramToken) return

  const chatId = TELEGRAM_ALERTS_CHAT_ID ?? DEFAULT_TELEGRAM_ALERTS_CHAT_ID

  try {
    await fetch(`https://api.telegram.org/bot${telegramToken}/sendMessage`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        chat_id: chatId,
        text,
      }),
    })
  } catch (error) {
    Log.shared.error("Failed to send Telegram bot event", { error })
  }
}

async function sendInlineBotEvent(text: string) {
  const botToken = INLINE_ALERTS_BOT_TOKEN
  const chatId = INLINE_ALERTS_CHAT_ID ? Number(INLINE_ALERTS_CHAT_ID) : null
  if (!botToken || !chatId || !Number.isFinite(chatId) || chatId <= 0) return

  try {
    await fetch(`${API_BASE_URL}/v1/sendMessage20250509`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        authorization: `Bearer ${botToken}`,
      },
      body: JSON.stringify({
        peerThreadId: chatId,
        text,
      }),
    })
  } catch (error) {
    Log.shared.error("Failed to send Inline bot event", { error })
  }
}
