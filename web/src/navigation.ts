import { DbObjectKind, type Chat } from "@inline/client/core"
import { parseInlineId, protocolId } from "@inline/ids"
import type { Account } from "./core"
import { Conversation } from "./conversation/Conversation"
import { NavigationChat } from "./core/navigation-chat"

export type OpenConversation = { conversation: Conversation; chat: Chat }

/** One browser pane owns one prepared conversation, including navigation races. */
export class ConversationNavigation {
  private current?: OpenConversation
  private preparation?: Promise<void>
  private retiring: Promise<void> = Promise.resolve()
  private retired?: Conversation
  private generation = 0

  constructor(private readonly account: Account) {}

  async open(rawId: string, signal: AbortSignal): Promise<OpenConversation> {
    const id = parseInlineId<"chat">(rawId, { positive: true })
    if (!id) throw new Error("Invalid conversation link")
    if (this.current?.chat.id === id) {
      const opened = this.current
      await this.preparation
      if (signal.aborted || this.current !== opened)
        throw new DOMException("Navigation cancelled", "AbortError")
      return opened
    }
    const generation = ++this.generation
    const recover = this.current == null && this.retired != null
    // Retire before activating another chat-keyed resident window.
    this.retireCurrent()
    this.current = undefined
    const assertCurrent = () => {
      if (signal.aborted || generation !== this.generation)
        throw new DOMException("Navigation cancelled", "AbortError")
    }
    assertCurrent()
    await this.awaitRetirement(recover)
    assertCurrent()
    let chat = this.account.db.get(this.account.db.ref(DbObjectKind.Chat, id))
    if (!chat) {
      const query = new NavigationChat(
        { peerId: { type: { oneofKind: "chat", chat: { chatId: protocolId(id) } } } },
        id,
        () => !signal.aborted && generation === this.generation,
      )
      try {
        await this.account.realtime.query(query)
      } finally {
        query.dispose()
      }
      assertCurrent()
      if (query.discarded)
        throw new Error("This conversation changed while opening. Please open it again.")
      chat = this.account.db.get(this.account.db.ref(DbObjectKind.Chat, id))
    }
    if (!chat) throw new Error("This conversation is unavailable")
    const opened = {
      chat,
      conversation: new Conversation(this.account.db, this.account.realtime, chat),
    }
    this.current = opened
    const onAbort = () => {
      if (this.current === opened) this.close(opened.conversation)
    }
    signal.addEventListener("abort", onAbort, { once: true })
    this.preparation = opened.conversation.start()
    try {
      await this.preparation
      assertCurrent()
      return opened
    } catch (error) {
      this.close(opened.conversation)
      throw error
    } finally {
      signal.removeEventListener("abort", onAbort)
    }
  }

  close(conversation?: Conversation): Promise<void> {
    if (conversation && this.current?.conversation !== conversation) return this.retiring
    ++this.generation
    this.retireCurrent()
    this.current = undefined
    this.preparation = undefined
    return this.retiring
  }

  private retireCurrent() {
    const conversation = this.current?.conversation
    if (!conversation) return
    conversation.stop()
    this.retired = conversation
    this.retiring = conversation.drain()
    // React route cleanup retires immediately; the next loader/account close
    // awaits this same promise and surfaces a storage failure.
    void this.retiring.catch(() => undefined)
  }

  private async awaitRetirement(recover: boolean) {
    const retired = this.retired
    const observed = this.retiring
    try {
      await observed
    } catch (error) {
      if (!recover || !retired) throw error
      // Concurrent loaders share one retry. A failed recipe remains owned by
      // the retired pane until an actual durable write succeeds.
      if (this.retiring === observed) {
        this.retiring = retired.retryDraftDrain()
        void this.retiring.catch(() => undefined)
      }
      await this.retiring
    }
    if (this.retired === retired) this.retired = undefined
  }
}
