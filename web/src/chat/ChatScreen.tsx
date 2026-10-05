import { useEffect, useLayoutEffect, useMemo, useRef, useState, useSyncExternalStore } from "react"
import { Link } from "@tanstack/react-router"
import {
  DbObjectKind,
  MessageSendingStatus,
  readMessages,
  type Chat,
  type Message,
} from "@inline/client/core"
import { protocolId, type MessageID } from "@inline/ids"
import {
  chatRoute,
  useAccount,
  useConversationNavigation,
  Avatar,
  chatTitle,
  Icon,
} from "../Workspace"
import { useRows, nameForUser, safeMediaUrl } from "../data"
import type { OpenConversation } from "../navigation"
import { Conversation, type ConversationSnapshot } from "../conversation/Conversation"
import { projectConversation } from "../conversation/projection"

export function ChatScreen() {
  const account = useAccount()
  const navigation = useConversationNavigation()
  const opened: OpenConversation = chatRoute.useLoaderData()
  const snapshot = useSyncExternalStore(
    opened.conversation.subscribe,
    opened.conversation.getSnapshot,
    opened.conversation.getSnapshot,
  )
  const chats = useRows(account.db, DbObjectKind.Chat)
  const chat = chats.find((item) => item.id === opened.chat.id)
  useEffect(() => {
    if (!chat || snapshot.unavailable) void navigation.close(opened.conversation)
  }, [chat, snapshot.unavailable, navigation, opened.conversation])
  if (!chat || snapshot.unavailable)
    return (
      <div className="welcome">
        <h1>This conversation is unavailable</h1>
        <Link to="/">Back to conversations</Link>
      </div>
    )
  return (
    <ConversationView
      key={chat.id}
      chat={chat}
      conversation={opened.conversation}
      snapshot={snapshot}
    />
  )
}

function ConversationView({
  chat,
  conversation,
  snapshot,
}: {
  chat: Chat
  conversation: Conversation
  snapshot: ConversationSnapshot
}) {
  const account = useAccount()
  const navigation = useConversationNavigation()
  const users = useRows(account.db, DbObjectKind.User)
  const spaces = useRows(account.db, DbObjectKind.Space)
  const userMap = useMemo(() => new Map(users.map((user) => [user.id, user])), [users])
  useEffect(
    () => () => {
      void navigation.close(conversation)
    },
    [conversation, navigation],
  )
  const rows = useMemo(() => projectConversation(snapshot.messages), [snapshot.messages])
  const title = chatTitle(chat, userMap)
  const listRef = useRef<HTMLDivElement>(null)
  const contentRef = useRef<HTMLDivElement>(null)
  const composeRef = useRef<HTMLTextAreaElement>(null)
  const [attached, setAttached] = useState(true)
  const following = useRef(true)
  const anchor = useRef<{ key: string; offset: number }[]>([])
  const [readError, setReadError] = useState("")
  const retryRead = useRef<() => void>(() => {})
  const readFrontier = useRef<MessageID | undefined>(undefined)
  const localSend = useRef(false)
  const peer = useMemo(
    () =>
      chat.peerUserId
        ? { type: { oneofKind: "user" as const, user: { userId: protocolId(chat.peerUserId) } } }
        : { type: { oneofKind: "chat" as const, chat: { chatId: protocolId(chat.id) } } },
    [chat.id, chat.peerUserId],
  )

  const capture = () => {
    const list = listRef.current
    if (!list) return
    const atBottom = list.scrollHeight - list.clientHeight - list.scrollTop < 36
    following.current = atBottom
    setAttached(atBottom)
    if (atBottom) {
      anchor.current = []
      return
    }
    const viewportTop = list.getBoundingClientRect().top
    anchor.current = Array.from(list.querySelectorAll<HTMLElement>("[data-message-key]"))
      .filter((row) => row.getBoundingClientRect().bottom > viewportTop)
      .slice(0, 6)
      .map((row) => ({
        key: row.dataset.messageKey!,
        offset: viewportTop - row.getBoundingClientRect().top,
      }))
  }
  const restore = () => {
    const list = listRef.current
    if (!list) return
    if (following.current || localSend.current) {
      list.scrollTop = list.scrollHeight
      localSend.current = false
      return
    }
    const elements = new Map(
      Array.from(list.querySelectorAll<HTMLElement>("[data-message-key]")).map((row) => [
        row.dataset.messageKey!,
        row,
      ]),
    )
    const saved = anchor.current.find((item) => elements.has(item.key))
    const row = saved ? elements.get(saved.key) : undefined
    if (row && saved)
      list.scrollTop +=
        row.getBoundingClientRect().top - list.getBoundingClientRect().top + saved.offset
  }
  useLayoutEffect(restore, [rows])
  useEffect(() => {
    if (!contentRef.current || !listRef.current) return
    const observer = new ResizeObserver(restore)
    observer.observe(contentRef.current)
    observer.observe(listRef.current)
    return () => observer.disconnect()
  }, [])
  useLayoutEffect(() => {
    const input = composeRef.current
    if (input) {
      input.style.height = "auto"
      input.style.height = `${Math.min(input.scrollHeight, 160)}px`
    }
  }, [snapshot.draft])

  // Read only messages actually visible in this focused tab; mounting a chat is insufficient.
  useEffect(() => {
    const list = listRef.current
    if (!list || snapshot.loading) return
    let timer: ReturnType<typeof setTimeout> | undefined
    let saving = false
    let disposed = false
    const visible = new Set<MessageID>()
    const flush = () => {
      if (
        disposed ||
        saving ||
        document.visibilityState !== "visible" ||
        !document.hasFocus() ||
        !snapshot.atLatest ||
        !snapshot.historyCertified
      )
        return
      const candidates = [...visible].filter((id) => BigInt(id) > 0n)
      const max = candidates.sort((a, b) => (BigInt(a) < BigInt(b) ? -1 : 1)).at(-1)
      if (!max || (readFrontier.current && BigInt(max) <= BigInt(readFrontier.current))) return
      saving = true
      void account.realtime.mutateAccepted(readMessages({ peerId: peer, maxId: max })).then(
        () => {
          readFrontier.current = max
          if (!disposed) {
            setReadError("")
            saving = false
            flush()
          }
        },
        () => {
          saving = false
          if (!disposed)
            setReadError("Read status could not be saved. It will retry when you return.")
        },
      )
    }
    const retry = () => {
      if (following.current) flush()
    }
    retryRead.current = retry
    const observer = new IntersectionObserver(
      (entries) => {
        for (const entry of entries) {
          const id = (entry.target as HTMLElement).dataset.readId as MessageID
          if (entry.isIntersecting && entry.intersectionRatio >= 0.6) visible.add(id)
          else visible.delete(id)
        }
        if (timer) clearTimeout(timer)
        timer = setTimeout(flush, 150)
      },
      { root: list, threshold: [0, 0.6] },
    )
    for (const row of list.querySelectorAll("[data-read-id]")) observer.observe(row)
    window.addEventListener("focus", flush)
    document.addEventListener("visibilitychange", flush)
    return () => {
      disposed = true
      if (retryRead.current === retry) retryRead.current = () => {}
      observer.disconnect()
      if (timer) clearTimeout(timer)
      window.removeEventListener("focus", flush)
      document.removeEventListener("visibilitychange", flush)
    }
  }, [
    account,
    peer,
    snapshot.messages,
    snapshot.loading,
    snapshot.atLatest,
    snapshot.historyCertified,
  ])

  const send = async () => {
    if (!snapshot.draft.trim() || snapshot.sending) return
    try {
      await conversation.send()
      following.current = true
      localSend.current = true
      setAttached(true)
      restore()
      composeRef.current?.focus()
    } catch {
      /* controller retains compose and exposes the failure */
    }
  }
  const replyMessage = snapshot.replyTo
    ? snapshot.messages.find((message) => message.messageId === snapshot.replyTo)
    : undefined
  return (
    <div className="chat-screen">
      <header className="chat-header">
        <Link to="/" className="icon-button mobile-back" aria-label="Back to conversations">
          <Icon name="back" />
        </Link>
        <Avatar
          title={title}
          emoji={chat.emoji}
          user={chat.peerUserId ? userMap.get(chat.peerUserId) : undefined}
          thread={!chat.peerUserId}
        />
        <div>
          <h1>{title}</h1>
          <p>
            {spaces.find((space) => space.id === chat.spaceId)?.name ||
              (chat.peerUserId
                ? "Direct message"
                : chat.isPublic
                  ? "Public thread"
                  : "Private thread")}
          </p>
        </div>
        {chat.createState && (
          <span className="muted">
            {chat.createState === "pending" ? "Creating…" : "Creation failed"}
          </span>
        )}
      </header>
      <div className="timeline-shell">
        <div
          ref={listRef}
          className="timeline"
          aria-label={`Messages in ${title}`}
          tabIndex={0}
          onScroll={capture}
        >
          <div ref={contentRef} className="timeline-content">
            <div className="history-control">
              {snapshot.hasOlder ? (
                <button
                  disabled={snapshot.loadingOlder}
                  onClick={() => {
                    capture()
                    void conversation.loadOlder()
                  }}
                >
                  {snapshot.loadingOlder ? "Loading history…" : "Load earlier messages"}
                </button>
              ) : snapshot.loading ? (
                <span>Opening messages…</span>
              ) : null}
            </div>
            {!snapshot.messages.length && !snapshot.loading && (
              <div className="empty-chat">
                <Avatar title={title} emoji={chat.emoji} thread={!chat.peerUserId} />
                <h2>{title}</h2>
                <p>Start the conversation.</p>
              </div>
            )}
            {rows.map((row) =>
              row.kind === "day" ? (
                <div className="day-separator" key={row.key}>
                  <span>{formatDay(row.date)}</span>
                </div>
              ) : (
                <article
                  key={row.key}
                  data-message-key={row.key}
                  data-message-id={row.message.messageId}
                  className={`message ${row.groupedWithPrevious ? "grouped" : ""} ${
                    row.message.out ? "outgoing" : ""
                  }`}
                >
                  <div className="message-avatar">
                    {!row.groupedWithPrevious && (
                      <Avatar
                        title={nameForUser(userMap.get(row.message.fromId))}
                        user={userMap.get(row.message.fromId)}
                      />
                    )}
                  </div>
                  <div className="message-body">
                    {!row.groupedWithPrevious && (
                      <header>
                        <strong>{nameForUser(userMap.get(row.message.fromId))}</strong>
                        {userMap.get(row.message.fromId)?.bot && (
                          <span className="bot-label">BOT</span>
                        )}
                        <time
                          dateTime={
                            row.message.date
                              ? new Date(row.message.date * 1000).toISOString()
                              : undefined
                          }
                        >
                          {formatTime(row.message.date)}
                        </time>
                      </header>
                    )}
                    {row.message.replyToMsgId && (
                      <div className="reply-quote">
                        ↳{" "}
                        {snapshot.messages.find(
                          (message) => message.messageId === row.message.replyToMsgId,
                        )?.message || "Reply to a message"}
                      </div>
                    )}
                    {row.message.message && (
                      <div className="message-text" dir="auto">
                        {row.message.message}
                      </div>
                    )}
                    <Media message={row.message} />
                    {row.message.serviceMessage && <p className="muted">Conversation updated</p>}
                    {row.message.status === MessageSendingStatus.Sending && (
                      <small className="send-state">Queued</small>
                    )}
                    {row.message.status === MessageSendingStatus.Failed && (
                      <button
                        className="send-failed"
                        onClick={() =>
                          void conversation.retry(row.message.messageId).catch(() => undefined)
                        }
                      >
                        Not sent · Retry
                      </button>
                    )}
                    {row.message.editDate && <small className="send-state">edited</small>}
                  </div>
                  <button
                    className="message-reply icon-button"
                    aria-label={`Reply to ${nameForUser(userMap.get(row.message.fromId))}`}
                    title="Reply"
                    onClick={() => {
                      conversation.setReplyTo(row.message.messageId)
                      composeRef.current?.focus()
                    }}
                    disabled={BigInt(row.message.messageId) <= 0n}
                  >
                    <Icon name="reply" />
                  </button>
                  <span
                    data-read-id={row.message.messageId}
                    className="read-marker"
                    aria-hidden="true"
                  />
                </article>
              ),
            )}
          </div>
        </div>
        {(!attached || !snapshot.atLatest) && (
          <button
            className="jump-latest"
            onClick={() => {
              following.current = true
              setAttached(true)
              void conversation.loadLatest()
              restore()
            }}
          >
            <Icon name="down" />
            Latest messages
          </button>
        )}
      </div>
      <div className="composer-area">
        {(snapshot.draftError || snapshot.error || readError) && (
          <div className="compose-error" role="alert">
            {snapshot.draftError || snapshot.error || readError}
            <button
              disabled={
                !snapshot.draftError &&
                !snapshot.error &&
                (!attached || !snapshot.atLatest || !snapshot.historyCertified)
              }
              onClick={() => {
                if (!snapshot.draftError && snapshot.errorRetry?.kind === "send") void send()
                else if (snapshot.draftError || snapshot.error)
                  void conversation.retryError().catch(() => undefined)
                else retryRead.current()
              }}
            >
              {snapshot.draftError
                ? "Save draft again"
                : snapshot.errorRetry?.kind === "send"
                  ? "Send again"
                  : "Retry"}
            </button>
          </div>
        )}
        {snapshot.replyTo && (
          <div className="compose-reply">
            <div>
              <strong>
                Reply to {replyMessage ? nameForUser(userMap.get(replyMessage.fromId)) : "message"}
              </strong>
              <span>{replyMessage?.message || "Message"}</span>
            </div>
            <button
              className="icon-button"
              aria-label="Cancel reply"
              onClick={() => conversation.setReplyTo()}
            >
              <Icon name="close" />
            </button>
          </div>
        )}
        <form
          className="composer"
          onSubmit={(event) => {
            event.preventDefault()
            void send()
          }}
        >
          <textarea
            ref={composeRef}
            aria-label={`Message ${title}`}
            placeholder={`Message ${title}`}
            value={snapshot.draft}
            disabled={snapshot.loading || chat.createState === "failed"}
            rows={1}
            onChange={(event) =>
              void conversation.setDraft(event.target.value).catch(() => undefined)
            }
            onKeyDown={(event) => {
              if (event.key === "Escape" && snapshot.replyTo) {
                event.preventDefault()
                conversation.setReplyTo()
              }
              if (
                event.key !== "Enter" ||
                event.nativeEvent.isComposing ||
                event.keyCode === 229 ||
                event.shiftKey
              )
                return
              const mobile = window.matchMedia("(pointer: coarse)").matches
              if (!mobile || event.metaKey || event.ctrlKey) {
                event.preventDefault()
                void send()
              }
            }}
          />
          <button
            className="send-button"
            aria-label="Send message"
            title="Send message"
            disabled={
              !snapshot.draft.trim() ||
              snapshot.sending ||
              snapshot.loading ||
              chat.createState === "failed"
            }
          >
            <Icon name="send" />
          </button>
        </form>
        <div className="compose-hint">
          {snapshot.sending
            ? "Saving message…"
            : navigator.onLine === false
              ? "Offline · your message will send when you reconnect"
              : "Enter to send · Shift + Enter for a new line"}
        </div>
      </div>
    </div>
  )
}

function Media({ message }: { message: Message }) {
  const media = message.media?.media
  const [failed, setFailed] = useState(false)
  if (media?.oneofKind === "photo") {
    const sizes =
      media.photo.photo?.sizes
        .filter((size) => safeMediaUrl(size.cdnUrl))
        .sort((a, b) => a.w - b.w) ?? []
    const size = sizes.find((item) => item.w >= 800) ?? sizes.at(-1)
    if (!size || failed) return <p className="media-unavailable">Photo unavailable</p>
    return (
      <a
        href={safeMediaUrl(size.cdnUrl)}
        target="_blank"
        rel="noreferrer"
        className="message-photo"
      >
        <img
          src={safeMediaUrl(size.cdnUrl)}
          width={size.w}
          height={size.h}
          loading="lazy"
          alt="Shared photo"
          onError={() => setFailed(true)}
        />
      </a>
    )
  }
  if (media?.oneofKind === "document") {
    const document = media.document.document
    const url = safeMediaUrl(document?.cdnUrl)
    return (
      <div className="document-message">
        <span aria-hidden="true">↧</span>
        <div>
          {url ? (
            <a href={url} target="_blank" rel="noreferrer">
              {document?.fileName || "Document"}
            </a>
          ) : (
            <strong>{document?.fileName || "Document"}</strong>
          )}
          <small>
            {document?.size ? `${Math.ceil(document.size / 1024)} KB` : ""}
            {!url && " · Open in the native app"}
          </small>
        </div>
      </div>
    )
  }
  if (media?.oneofKind === "voice") {
    const url = safeMediaUrl(media.voice.voice?.cdnUrl)
    return url ? (
      <audio controls preload="none" src={url} />
    ) : (
      <p className="media-unavailable">Voice message · Open in the native app</p>
    )
  }
  if (media?.oneofKind === "video") {
    const url = safeMediaUrl(media.video.video?.cdnUrl)
    return url ? (
      <video controls preload="metadata" src={url} />
    ) : (
      <p className="media-unavailable">Video · Open in the native app</p>
    )
  }
  if (media?.oneofKind === "nudge") return <span className="nudge">👋 Nudge</span>
  return null
}

function formatTime(seconds?: number) {
  return seconds
    ? new Intl.DateTimeFormat(undefined, { hour: "numeric", minute: "2-digit" }).format(
        new Date(seconds * 1000),
      )
    : ""
}
function formatDay(seconds: number) {
  const date = new Date(seconds * 1000)
  const today = new Date()
  if (date.toDateString() === today.toDateString()) return "Today"
  return new Intl.DateTimeFormat(undefined, {
    month: "long",
    day: "numeric",
    year: date.getFullYear() !== today.getFullYear() ? "numeric" : undefined,
  }).format(date)
}
