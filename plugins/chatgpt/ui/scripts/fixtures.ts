import type { ThreadSnapshot } from "../src/contracts"

/** Local preview/test data. Never imported into the production component bundle. */
export function sampleThread(chatId = "800", title = "Feedback on the proposal"): ThreadSnapshot {
  const now = Math.floor(Date.now() / 1000)
  const base = Number(chatId) * 100
  return {
    chat: { chatId, title, kind: "home_thread" },
    details: { emoji: "💬", isPublic: false, groupParticipantCount: 0 },
    participants: [
      { userId: "1", displayName: "You" },
      { userId: "2", displayName: "Sam" },
      { userId: "3", displayName: "Alex" },
    ],
    capabilities: { canSend: true },
    monitoring: { active: true, expiresAt: new Date(Date.now() + 3_600_000).toISOString() },
    nextOffsetId: null,
    messages: [
      { id: String(base + 1), chatId, text: "Sam, Alex — can you take a look at this proposal? We’re deciding how to make the first version useful without expanding the scope.", out: true, fromId: "1", date: String(now - 600), replyToMsgId: null, editDate: null, media: null, links: [] },
      { id: String(base + 2), chatId, text: "The overall direction makes sense. I’d make the reply workflow the focus of the first release.", out: false, fromId: "2", senderDisplayName: "Sam", date: String(now - 480), replyToMsgId: null, editDate: null, media: null, links: [] },
      { id: String(base + 3), chatId, text: "It should keep working after you close the view. That’s the part I’d want to test first.", out: false, fromId: "2", senderDisplayName: "Sam", date: String(now - 450), replyToMsgId: null, editDate: null, media: null, links: [] },
      { id: String(base + 4), chatId, text: "Agreed. Keep the thread view familiar and simple. We can add more actions once this feels solid.", out: false, fromId: "3", senderDisplayName: "Alex", date: String(now - 210), replyToMsgId: String(base + 1), editDate: null, media: null, links: [] },
      { id: String(base + 5), chatId, text: "That’s helpful. I’ll fold both of those into the next draft.", out: true, fromId: "1", date: String(now - 60), replyToMsgId: null, editDate: null, media: null, links: [] },
    ],
  }
}
