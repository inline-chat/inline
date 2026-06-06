import { Log } from "@in/server/utils/log"
import {
  API_BASE_URL,
  INLINE_ALERTS_BOT_TOKEN,
  INLINE_ALERTS_CHAT_ID,
  isDev,
} from "@in/server/env"

const shouldSendAlerts = () => !isDev

export const sendBotEvent = sendInlineAlert
export const sendInlineOnlyBotEvent = sendInlineAlert

function sendInlineAlert(text: string) {
  if (!shouldSendAlerts()) return
  // Fire-and-forget. These notifications are best-effort and should never affect the caller.
  void sendInlineBotEvent(text)
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
