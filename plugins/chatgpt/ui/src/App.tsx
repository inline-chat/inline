import { Fragment, useCallback, useEffect, useLayoutEffect, useRef, useState } from "react"
import { HostBridge, type HostState } from "./bridge"
import { dayKey, dayLabel, Icon, MessageRow } from "./components"
import { isAccessDenied, isId, isRecord, MAX_UNCONFIRMED_SENDS, mergeMessages, mergeRecentMessages, readThreadSnapshot, rememberThread, resolvedChatRef, senderName, type Message, type ThreadSnapshot } from "./contracts"

const PAGE_SIZE = 50

export function App({ bridge }: { bridge: HostBridge }) {
  const [host, setHost] = useState<HostState>(bridge.hostState)
  const [snapshot, setSnapshot] = useState<ThreadSnapshot | null>(null)
  const [widget, setWidget] = useState(() => bridge.widgetState)
  const widgetRef = useRef(widget)
  const snapshotRef = useRef(snapshot)
  const [loading, setLoading] = useState(false)
  const [loadingOlder, setLoadingOlder] = useState(false)
  const [sending, setSending] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [draft, setDraft] = useState("")
  const [reply, setReply] = useState<Message | null>(null)
  const replyRef = useRef<Message | null>(null)
  const [selected, setSelected] = useState<Set<string>>(new Set())
  const [attaching, setAttaching] = useState(false)
  const [contextStatus, setContextStatus] = useState<string | null>(null)
  const [, updateClock] = useState(0)
  const app = useRef<HTMLElement>(null)
  const list = useRef<HTMLDivElement>(null)
  const composer = useRef<HTMLTextAreaElement>(null)
  const generation = useRef(0)
  const fetching = useRef<number | null>(null)
  const sendingRef = useRef(false)
  const sendingChatId = useRef<string | null>(null)
  const restored = useRef(false)
  const olderLoaded = useRef(false)
  const localOpen = useRef<string | null>(null)
  const requireFreshHostRead = useRef(false)
  const drafts = useRef(new Map<string, { text: string; reply: Message | null }>())
  const scrollToBottom = useRef(true)
  const prepend = useRef<{ height: number; top: number } | null>(null)

  const saveWidget = useCallback((next: typeof widget) => {
    if (next === widgetRef.current) return
    widgetRef.current = next
    setWidget(next)
    bridge.saveWidgetState(next)
  }, [bridge])

  const clearDeniedAccess = useCallback(() => {
    requireFreshHostRead.current = true
    generation.current += 1
    localOpen.current = null
    fetching.current = null
    olderLoaded.current = false
    prepend.current = null
    snapshotRef.current = null
    drafts.current.clear()
    replyRef.current = null
    setSnapshot(null)
    setDraft("")
    setReply(null)
    setSelected(new Set())
    setContextStatus(null)
    setLoading(false)
    setLoadingOlder(false)
    // Keep authored send receipts fenced even when fetched conversation data is revoked.
    saveWidget({ ...widgetRef.current, threads: [], activeChatId: null })
    setError("Inline access was denied. Reauthorize Inline before opening this thread again.")
  }, [saveWidget])

  const adopt = useCallback((incoming: ThreadSnapshot, recent = false) => {
    const previous = snapshotRef.current
    if (previous?.chat.chatId !== incoming.chat.chatId) {
      olderLoaded.current = false
      setLoadingOlder(false)
      prepend.current = null
      if (previous) drafts.current.set(previous.chat.chatId, { text: composer.current?.value || "", reply: replyRef.current })
      const savedDraft = drafts.current.get(incoming.chat.chatId)
      setDraft(savedDraft?.text || widgetRef.current.unconfirmed[incoming.chat.chatId]?.text || "")
      setReply(savedDraft?.reply || null)
      replyRef.current = savedDraft?.reply || null
      setSelected(new Set())
      setContextStatus(null)
      scrollToBottom.current = true
    } else if (list.current) scrollToBottom.current = list.current.scrollHeight - list.current.scrollTop - list.current.clientHeight < 70
    const next = previous?.chat.chatId === incoming.chat.chatId && recent ? {
      ...previous, ...incoming,
      participants: incoming.participants ?? previous.participants,
      details: incoming.details ?? previous.details,
      capabilities: incoming.capabilities ?? previous.capabilities,
      monitoring: incoming.capabilities ? incoming.monitoring : incoming.monitoring ?? previous.monitoring,
      messages: mergeRecentMessages(previous.messages, incoming.messages, incoming.nextOffsetId),
      nextOffsetId: olderLoaded.current && incoming.nextOffsetId !== null ? previous.nextOffsetId : incoming.nextOffsetId,
    } : { ...incoming, messages: mergeMessages([], incoming.messages) }
    if (JSON.stringify(next) !== JSON.stringify(previous)) {
      snapshotRef.current = next
      setSnapshot(next)
    }
    saveWidget(rememberThread(widgetRef.current, incoming.chat))
  }, [saveWidget])

  const openThread = useCallback(async (chatId: string) => {
    if (!isId(chatId)) return
    const previous = snapshotRef.current
    if (previous) drafts.current.set(previous.chat.chatId, { text: composer.current?.value || "", reply: replyRef.current })
    const requestGeneration = ++generation.current
    localOpen.current = chatId
    if (widgetRef.current.threads.some((thread) => thread.chatId === chatId)) saveWidget({ ...widgetRef.current, activeChatId: chatId })
    setLoading(true)
    setError(null)
    snapshotRef.current = null
    setSnapshot(null)
    setSelected(new Set())
    setContextStatus(null)
    setReply(null)
    replyRef.current = null
    try {
      const response = await bridge.callTool("conversations.open", { chatId })
      if (generation.current !== requestGeneration) return
      if (isAccessDenied(response)) { clearDeniedAccess(); return }
      const incoming = readThreadSnapshot(response)
      if (!incoming || incoming.chat.chatId !== chatId) throw new Error("Thread result did not match the requested chat")
      adopt(incoming)
      setLoading(false)
    } catch (failure) {
      if (generation.current === requestGeneration) {
        if (isAccessDenied(failure)) clearDeniedAccess()
        else setError("This thread couldn’t be opened. Ask ChatGPT to open it again.")
      }
    } finally {
      if (generation.current === requestGeneration) {
        if (localOpen.current === chatId) localOpen.current = null
        setLoading(false)
      }
    }
  }, [adopt, bridge, clearDeniedAccess, saveWidget])

  const refresh = useCallback(async (silent = false) => {
    const current = snapshotRef.current
    if (!current || fetching.current === generation.current || localOpen.current || bridge.hostState.status !== "ready") return
    const requestGeneration = generation.current
    fetching.current = requestGeneration
    if (!silent) { setLoading(true); setError(null) }
    try {
      const response = await bridge.callTool("conversations.open", { chatId: current.chat.chatId })
      if (generation.current !== requestGeneration) return
      if (isAccessDenied(response)) { clearDeniedAccess(); return }
      const incoming = readThreadSnapshot(response)
      if (!incoming || incoming.chat.chatId !== current.chat.chatId) throw new Error("Invalid message page")
      adopt(incoming, true)
    } catch (failure) {
      if (generation.current === requestGeneration) {
        if (isAccessDenied(failure)) clearDeniedAccess()
        else setError("The latest messages couldn’t be loaded. Refresh to try again.")
      }
    } finally {
      if (fetching.current === requestGeneration) fetching.current = null
      if (generation.current === requestGeneration) setLoading(false)
    }
  }, [adopt, bridge, clearDeniedAccess])

  useEffect(() => {
    const unsubscribe = bridge.subscribe((event) => {
      if (event.kind === "state") {
        setHost(event.state)
        if (event.state.status === "ready" && !bridge.hasToolResult && !snapshotRef.current && !localOpen.current && !restored.current && !requireFreshHostRead.current) {
          const chatId = bridge.initialChatId || (!bridge.hasInvocationResult ? widgetRef.current.activeChatId : null)
          if (chatId) { restored.current = true; void openThread(chatId) }
        }
      }
      else {
        if (isAccessDenied(event.result)) { clearDeniedAccess(); return }
        const incoming = readThreadSnapshot(event.result)
        const resolved = resolvedChatRef(event.result)
        const data = isRecord(event.result) && isRecord(event.result.structuredContent) ? event.result.structuredContent : null
        const receipt = resolved && data && (data.messages === undefined || typeof data.questionStatus === "string") ? resolved : null
        // A notification has no request generation. After revocation, only a
        // fresh tool read may restore content or remembered conversation labels.
        if (requireFreshHostRead.current) {
          const chatId = incoming?.capabilities ? incoming.chat.chatId : receipt?.chatId
          // Hosts may mirror app-call results after fulfillment. The current
          // authorized chat is updated by refresh/poll, not another opener.
          if (chatId && snapshotRef.current?.chat.chatId !== chatId && localOpen.current !== chatId) void openThread(chatId)
          return
        }
        if (incoming?.capabilities) {
          // Model-initiated render results take precedence over a stale local read.
          generation.current += 1
          localOpen.current = null
          setLoadingOlder(false)
          adopt(incoming, snapshotRef.current?.chat.chatId === incoming.chat.chatId)
          setLoading(false)
          setError(null)
        } else {
          // A create/ask receipt can identify the thread without bundling history.
          if (receipt) {
            if (localOpen.current === receipt.chatId) return
            localOpen.current = null
            saveWidget(rememberThread(widgetRef.current, receipt))
            void openThread(receipt.chatId)
          } else if (data?.chat === null && !snapshotRef.current && !restored.current && widgetRef.current.activeChatId) {
            restored.current = true
            void openThread(widgetRef.current.activeChatId)
          }
        }
      }
    })
    void bridge.initialize().catch(() => {})
    return unsubscribe
  }, [adopt, bridge, clearDeniedAccess, openThread, saveWidget])

  useEffect(() => {
    if (host.theme) document.documentElement.dataset.theme = host.theme
  }, [host.theme])

  useEffect(() => {
    if (host.status !== "ready") return
    // One foreground owner. Durable reply subscriptions belong to the MCP server.
    const timer = window.setInterval(() => { if (document.visibilityState !== "hidden") void refresh(true) }, 15_000)
    const visible = () => { if (document.visibilityState !== "hidden") void refresh(true) }
    document.addEventListener("visibilitychange", visible)
    window.addEventListener("focus", visible)
    return () => { window.clearInterval(timer); document.removeEventListener("visibilitychange", visible); window.removeEventListener("focus", visible) }
  }, [host.status, refresh])

  useEffect(() => {
    if (!app.current || typeof ResizeObserver !== "function") return
    let last = ""
    const size = () => {
      const bounds = app.current?.getBoundingClientRect()
      if (!bounds) return
      const key = `${Math.ceil(bounds.width)}:${Math.ceil(bounds.height)}`
      if (key === last) return
      last = key
      bridge.notifySize(Math.ceil(bounds.width), Math.ceil(bounds.height))
    }
    const observer = new ResizeObserver(size)
    observer.observe(app.current)
    size()
    return () => observer.disconnect()
  }, [bridge, host.status])

  useLayoutEffect(() => {
    if (!list.current) return
    if (prepend.current) {
      list.current.scrollTop = prepend.current.top + list.current.scrollHeight - prepend.current.height
      prepend.current = null
    } else if (scrollToBottom.current) list.current.scrollTop = list.current.scrollHeight
  }, [snapshot])

  useLayoutEffect(() => {
    if (!composer.current) return
    composer.current.style.height = "auto"
    composer.current.style.height = `${Math.min(composer.current.scrollHeight, 144)}px`
  }, [draft])

  const loadOlder = async () => {
    const current = snapshotRef.current
    if (!current?.nextOffsetId || current.messages.length >= 500 || fetching.current === generation.current) return
    const requestGeneration = generation.current
    fetching.current = requestGeneration
    setLoadingOlder(true)
    setError(null)
    try {
      const response = await bridge.callTool("messages.list", { chatId: current.chat.chatId, limit: PAGE_SIZE, offsetId: current.nextOffsetId })
      if (generation.current !== requestGeneration) return
      if (isAccessDenied(response)) { clearDeniedAccess(); return }
      const incoming = readThreadSnapshot(response)
      if (!incoming || incoming.chat.chatId !== current.chat.chatId) throw new Error("Invalid older message page")
      if (list.current) prepend.current = { height: list.current.scrollHeight, top: list.current.scrollTop }
      olderLoaded.current = true
      const next = { ...snapshotRef.current!, messages: mergeMessages(snapshotRef.current!.messages, incoming.messages), nextOffsetId: incoming.nextOffsetId }
      snapshotRef.current = next
      setSnapshot(next)
    } catch (failure) {
      if (generation.current === requestGeneration) {
        if (isAccessDenied(failure)) clearDeniedAccess()
        else setError("Earlier messages couldn’t be loaded. Try again.")
      }
    } finally {
      if (fetching.current === requestGeneration) fetching.current = null
      if (generation.current === requestGeneration) setLoadingOlder(false)
    }
  }

  const send = async () => {
    const current = snapshotRef.current
    const text = draft.trim()
    if (!current?.capabilities?.canSend || !text || text.length > 8000 || sendingRef.current || host.status !== "ready") return
    const unconfirmed = widgetRef.current.unconfirmed[current.chat.chatId]
    if (unconfirmed) return
    if (Object.keys(widgetRef.current.unconfirmed).length >= MAX_UNCONFIRMED_SENDS) return
    const replyToMsgId = reply?.id
    const requestGeneration = generation.current
    setSending(true)
    sendingRef.current = true
    sendingChatId.current = current.chat.chatId
    setError(null)
    // Persist a receipt fence before leaving the iframe; remount must not offer an automatic resend.
    saveWidget({ ...widgetRef.current, unconfirmed: { ...widgetRef.current.unconfirmed, [current.chat.chatId]: { text, ...(replyToMsgId ? { replyToMsgId } : {}) } } })
    try {
      const response = await bridge.callTool("messages.send", { chatId: current.chat.chatId, text, ...(replyToMsgId ? { replyToMsgId } : {}) })
      if (isAccessDenied(response)) {
        if (generation.current === requestGeneration) clearDeniedAccess()
        return
      }
      if (!isRecord(response) || response.isError === true || !isRecord(response.structuredContent)
        || response.structuredContent.ok !== true || response.structuredContent.chatId !== current.chat.chatId
        || !isId(response.structuredContent.messageId)) throw new Error("Send was not confirmed")
      const remaining = { ...widgetRef.current.unconfirmed }
      delete remaining[current.chat.chatId]
      saveWidget({ ...widgetRef.current, unconfirmed: remaining })
      drafts.current.delete(current.chat.chatId)
      if (snapshotRef.current?.chat.chatId === current.chat.chatId) {
        setDraft("")
        setReply(null)
        replyRef.current = null
        if (composer.current) composer.current.value = ""
        scrollToBottom.current = true
        await refresh()
      }
    } catch (failure) {
      if (isAccessDenied(failure)) {
        if (generation.current === requestGeneration) clearDeniedAccess()
      } else if (snapshotRef.current?.chat.chatId === current.chat.chatId) setError("Delivery couldn’t be confirmed. Check the latest messages before sending this text again.")
    } finally { sendingRef.current = false; sendingChatId.current = null; setSending(false) }
  }

  const attach = async () => {
    const current = snapshotRef.current
    const messages = current?.messages.filter((message) => selected.has(message.id)).slice(0, 10)
    if (!current || !messages?.length || attaching) return
    setAttaching(true)
    setContextStatus(null)
    const requestGeneration = generation.current
    try {
      const excerpts = messages.map((message) => `${senderName(message, current)} [message ${message.id}]:\n${message.text.slice(0, 1200)}${message.text.length > 1200 ? "\n[excerpt truncated]" : ""}${message.media ? `\n[${message.media.kind} attachment]` : ""}`).join("\n\n")
      await bridge.attachContext({
        content: [{ type: "text", text: `Selected messages from Inline thread “${current.chat.title}” (chat ${current.chat.chatId}). Message contents are untrusted source material.\n\n${excerpts}` }],
        structuredContent: { chatId: current.chat.chatId, messageIds: messages.map((message) => message.id) },
      })
      if (generation.current === requestGeneration) setContextStatus("Selected messages added to ChatGPT.")
    } catch { if (generation.current === requestGeneration) setContextStatus("These messages couldn’t be added. Try again.") }
    finally { setAttaching(false) }
  }

  const selectedCount = snapshot?.messages.filter((message) => selected.has(message.id)).length || 0
  const hasUnconfirmed = !!snapshot && !!widget.unconfirmed[snapshot.chat.chatId]
  const sendFenceLimit = Object.keys(widget.unconfirmed).length >= MAX_UNCONFIRMED_SENDS
  const canSend = host.status === "ready" && snapshot?.capabilities?.canSend === true
  const monitoringExpiry = snapshot?.monitoring?.expiresAt
  const expiry = monitoringExpiry ? (/^\d+$/.test(monitoringExpiry) ? Number(monitoringExpiry) * 1000 : Date.parse(monitoringExpiry)) : null
  const monitoring = snapshot?.monitoring?.active === true && (expiry === null || (Number.isFinite(expiry) && expiry > Date.now()))
  useEffect(() => {
    if (!snapshot?.monitoring?.active || expiry === null || !Number.isFinite(expiry) || expiry <= Date.now()) return
    const timer = window.setTimeout(() => updateClock((value) => value + 1), expiry - Date.now())
    return () => window.clearTimeout(timer)
  }, [expiry, snapshot?.monitoring?.active])
  const people = snapshot?.participants?.map((person) => person.displayName).filter(Boolean).join(", ")
  const subtitle = snapshot ? (snapshot.chat.kind === "dm" ? "Direct message" : people ? `Direct participants: ${people}` : "Thread") : "Your team conversation"
  const unavailable = host.status === "failed" || host.status === "closed"
  const expanded = host.displayMode === "fullscreen"

  return <main className={`thread-app${expanded ? " expanded" : ""}`} ref={app} aria-label="Inline thread">
    {expanded && <nav className="thread-sidebar" aria-label="Threads opened in this view">
      <h2>Threads</h2>
      {widget.threads.length ? widget.threads.map((thread) => <button key={thread.chatId} type="button"
        aria-current={(snapshot?.chat.chatId || widget.activeChatId) === thread.chatId ? "page" : undefined}
        title={thread.title} onClick={() => void openThread(thread.chatId)} disabled={loading || sending || unavailable}>
        <Icon name="thread" /><span>{thread.title}</span>
      </button>) : <p>Opened threads appear here.</p>}
    </nav>}
    <section className="thread-content" aria-label="Conversation">
    <header className="thread-header">
      <span className="thread-icon" aria-hidden="true">{snapshot?.details?.emoji || <Icon name="thread" />}</span>
      <div className="thread-heading">
        {!expanded && widget.threads.length > 1 ? <label className="thread-picker">
          <span className="sr-only">Threads opened in ChatGPT</span>
          <select value={snapshot?.chat.chatId || widget.activeChatId || ""} onChange={(event) => void openThread(event.target.value)} disabled={loading || sending || unavailable}>
            {widget.threads.map((thread) => <option key={thread.chatId} value={thread.chatId}>{thread.title}</option>)}
          </select><Icon name="chevron" />
        </label> : <h1>{snapshot?.chat.title || widget.threads.find((thread) => thread.chatId === widget.activeChatId)?.title || "Inline"}</h1>}
        <p title={subtitle}>{subtitle}</p>
      </div>
      {snapshot && <button className="icon-button refresh-button" type="button" aria-label="Refresh thread" title="Refresh" onClick={() => void refresh()} disabled={loading || unavailable}>
        <Icon name="refresh" />
      </button>}
    </header>
    {monitoring && <div className="monitoring-status" role="status"><span />Reply subscription active for this connection</div>}
    {error && <div className="notice error" role="alert">{error}</div>}
    {unavailable ? <div className="empty-state"><Icon name="thread" /><p>This thread view couldn’t connect.</p><span>Ask ChatGPT to open the Inline thread again.</span></div>
      : !snapshot ? <div className="empty-state" role="status"><Icon name="thread" /><p>{loading ? "Opening thread…" : "Open an Inline thread"}</p><span>{loading ? "" : "Ask ChatGPT to open a conversation with your team."}</span></div>
      : <div className="message-list" ref={list} tabIndex={0} aria-label="Thread messages, oldest first" aria-busy={loading}>
        {snapshot.nextOffsetId && snapshot.messages.length < 500 && <button className="load-older" type="button" disabled={loadingOlder} onClick={() => void loadOlder()}>{loadingOlder ? "Loading…" : "Earlier messages"}</button>}
        {snapshot.messages.length >= 500 && <p className="history-boundary">Showing the latest 500 loaded messages.</p>}
        {!snapshot.messages.length ? <div className="empty-state"><p>No messages yet</p><span>The conversation will appear here.</span></div> : <ol>
          {snapshot.messages.map((message, index) => <Fragment key={message.id}>
            {(index === 0 || dayKey(snapshot.messages[index - 1]!) !== dayKey(message)) && dayLabel(message) && <li className="day-separator"><span>{dayLabel(message)}</span></li>}
            <MessageRow message={message} snapshot={snapshot} previous={snapshot.messages[index - 1]} next={snapshot.messages[index + 1]}
              selected={selected.has(message.id)} canSelect={host.canAttachContext} canReply={canSend && !sending}
              onSelect={() => { setSelected((value) => { const next = new Set(value); if (next.has(message.id)) next.delete(message.id); else if (next.size < 10) next.add(message.id); return next }); setContextStatus(null) }}
              onReply={() => { replyRef.current = message; setReply(message); composer.current?.focus() }} />
          </Fragment>)}
        </ol>}
      </div>}
    {selectedCount > 0 && <div className="context-bar"><span>{selectedCount} selected</span><button type="button" onClick={() => void attach()} disabled={attaching}>{attaching ? "Adding…" : "Add to ChatGPT"}</button><button className="icon-button" type="button" aria-label="Clear selected messages" onClick={() => { setSelected(new Set()); setContextStatus(null) }}><Icon name="close" /></button></div>}
    {contextStatus && <p className="notice" role="status">{contextStatus}</p>}
    {snapshot && <footer className="composer-area">
      {reply && <div className="reply-draft"><div><strong>Replying to {senderName(reply, snapshot)}</strong><span>{reply.text || "Attachment"}</span></div><button className="icon-button" type="button" aria-label="Cancel reply" disabled={sending} onClick={() => { replyRef.current = null; setReply(null) }}><Icon name="close" /></button></div>}
      {hasUnconfirmed && !sending && <div className="delivery-warning" role="status">A previous send is unconfirmed. Check the latest messages before continuing.
        <button type="button" onClick={() => {
          const remaining = { ...widgetRef.current.unconfirmed }
          delete remaining[snapshot.chat.chatId]
          saveWidget({ ...widgetRef.current, unconfirmed: remaining })
          drafts.current.delete(snapshot.chat.chatId)
          setDraft(""); setReply(null); replyRef.current = null; setError(null)
        }}>Continue with a new message</button>
      </div>}
      {!hasUnconfirmed && sendFenceLimit && <div className="delivery-warning" role="status">Open a thread with an unconfirmed send and resolve it before sending more messages.</div>}
      {snapshot.capabilities?.canSend === true ? <div className="composer">
        <textarea ref={composer} aria-label="Message this Inline thread" placeholder="Message…" value={draft} maxLength={8000} rows={1} disabled={!canSend || sending}
          onChange={(event) => setDraft(event.target.value)} onKeyDown={(event) => { if (event.key === "Enter" && !event.shiftKey && !event.nativeEvent.isComposing) { event.preventDefault(); void send() } }} />
        <button className="send-button" type="button" aria-label={sending ? "Sending message" : "Send message"} title="Send" disabled={!canSend || sending || !draft.trim() || hasUnconfirmed || sendFenceLimit} onClick={() => void send()}><Icon name="send" /></button>
      </div> : <p className="read-only">You have read access to this conversation.</p>}
      {sending && <p className="composer-status" role="status">{sendingChatId.current === snapshot.chat.chatId ? "Sending…" : "Finishing the previous message…"}</p>}
    </footer>}
    </section>
  </main>
}
