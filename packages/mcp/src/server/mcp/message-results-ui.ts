import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js"

export const LEGACY_MESSAGE_RESULTS_RESOURCE_URI = "ui://inline/message-results-v1.html"
export const MESSAGE_RESULTS_RESOURCE_URI = "ui://inline/message-results-v2.html"
export const MESSAGE_RESULTS_MIME_TYPE = "text/html;profile=mcp-app"

// Compiled function is embedded in the resource; no remote JS or asset copy.
// Tool content is rendered with DOM/text APIs, never interpolated into HTML.
function messageResultsComponent(): void {
  type R = Record<string, unknown>
  type Message = R & { id: string; chatId: string; text: string; out: boolean; fromId: string | null; date: string | null; media: R | null }
  type Chat = { chatId: string; status: "available" | "unavailable"; chat: R | null }
  type Item = { chatId: string; messageId: string; status: "available" | "unavailable"; message: Message | null }
  type Page = { kind: string; nextOffsetId: string | null; nextAfterId: string | null; anchorMessageId: string | null; firstUnreadMessageId: string | null; note: string | null }
  type Data = { presentation: "sources" | "catch_up"; chats: Chat[]; items: Item[]; activeChatId: string | null; page: Page }
  type State = { items: Item[]; page: Page; metadata: R; scrollTop: number; entry: string | null }
  const root = document.getElementById("root")!
  const parent = window.parent
  const record = (v: unknown): v is R => v !== null && typeof v === "object" && !Array.isArray(v)
  const id = (v: unknown): v is string => typeof v === "string" && /^[1-9]\d*$/.test(v)
  const nullableId = (v: unknown): v is string | null => v === null || id(v)
  const named = (v: unknown): string | null => typeof v === "string" && v.trim() ? v.trim() : null
  const node = <K extends keyof HTMLElementTagNameMap>(tag: K, text?: string, cls?: string): HTMLElementTagNameMap[K] => {
    const el = document.createElement(tag)
    if (text !== undefined) el.textContent = text
    if (cls) el.className = cls
    return el
  }
  const button = (text: string, cls: string, action: () => void): HTMLButtonElement => {
    const el = node("button", text, cls); el.type = "button"; el.addEventListener("click", action); return el
  }
  let initialized = false, disposed = false, requestId = 1, generation = 0, navigation = 0
  let expanded = false, mobileList = false, allSources = false, loading = false, awaitingResult = true
  let outerArguments: R | null = null
  let data: Data | null = null, initialMetadata: R = {}, activeChatId: string | null = null, notice: string | null = null
  let capabilities: R = {}, host: R = {}, lastSize = ""
  const states = new Map<string, State>()
  const ownToolInputs = new Map<number, { args: R; completed: boolean; resultEchoed: boolean }>()
  let echoedToolCall: number | null = null
  const pending = new Map<number, { resolve: (value: unknown) => void; reject: (error: Error) => void; timer: number }>()
  const send = (message: R): void => parent.postMessage({ jsonrpc: "2.0", ...message }, "*")
  const request = (method: string, params: R): Promise<unknown> => new Promise((resolve, reject) => {
    const callId = ++requestId
    const timer = window.setTimeout(() => { pending.delete(callId); ownToolInputs.delete(callId); reject(new Error("Host timeout")) }, 15_000)
    if (method === "tools/call" && record(params.arguments)) ownToolInputs.set(callId, { args: params.arguments, completed: false, resultEchoed: false })
    // Retain only a few completed calls for hosts delivering notification echoes
    // after the correlated response. No message text/URLs are kept here.
    if (ownToolInputs.size > 8) for (const [key, call] of ownToolInputs) { if (call.completed) { ownToolInputs.delete(key); break } }
    pending.set(callId, { resolve, reject, timer }); send({ id: callId, method, params })
  })
  const sizeChanged = (): void => {
    if (!initialized || disposed) return
    const rect = root.getBoundingClientRect(), width = Math.ceil(rect.width), height = Math.ceil(rect.height)
    const key = `${width}:${height}`
    if (key !== lastSize) { lastSize = key; send({ method: "ui/notifications/size-changed", params: { width, height } }) }
  }
  const observer = typeof ResizeObserver === "function" ? new ResizeObserver(sizeChanged) : null
  observer?.observe(root)
  const status = (text: string, error = false): void => {
    const el = node("p", text, "status"); el.setAttribute("role", error ? "alert" : "status")
    root.replaceChildren(el); root.setAttribute("aria-busy", String(!error)); sizeChanged()
  }
  const canCall = (): boolean => record(capabilities.serverTools)
  const canOpen = (): boolean => record(capabilities.openLinks)
  const canExpand = (): boolean => Array.isArray(host.availableDisplayModes) && host.availableDisplayModes.includes("fullscreen")
  const dateOf = (v: unknown): Date | null => {
    if (typeof v !== "string" || !/^\d+$/.test(v)) return null
    const date = new Date(Number(v) * 1000); return Number.isFinite(date.getTime()) ? date : null
  }
  const sameDay = (a: Date, b: Date): boolean => a.getFullYear() === b.getFullYear() && a.getMonth() === b.getMonth() && a.getDate() === b.getDate()
  const timeFormat = new Intl.DateTimeFormat(undefined, { hour: "numeric", minute: "2-digit" })
  const fullFormat = new Intl.DateTimeFormat(undefined, { dateStyle: "full", timeStyle: "short" })
  const dayLabel = (date: Date): string => {
    const now = new Date(), yesterday = new Date(now); yesterday.setDate(yesterday.getDate() - 1)
    return sameDay(date, now) ? "Today" : sameDay(date, yesterday) ? "Yesterday" : new Intl.DateTimeFormat(undefined, { month: "short", day: "numeric", ...(date.getFullYear() === now.getFullYear() ? {} : { year: "numeric" }) }).format(date)
  }
  const time = (v: unknown, day = false): HTMLElement | null => {
    const date = dateOf(v); if (!date) return null
    const el = node("time", `${day ? `${dayLabel(date)}, ` : ""}${timeFormat.format(date)}`)
    el.dateTime = date.toISOString(); el.title = fullFormat.format(date); return el
  }
  const safeLink = (v: unknown): string | null => {
    if (typeof v !== "string" || v.length > 4096 || Array.from(v).some((char) => char.codePointAt(0)! <= 32)) return null
    try { const url = new URL(v); return ["https:", "http:"].includes(url.protocol) && !url.username && !url.password ? url.href : null } catch { return null }
  }
  // Signed presentation files have one exact origin/path. media.url is ignored.
  const fileUrl = (v: unknown): string | null => {
    const link = safeLink(v); if (!link) return null
    const url = new URL(link)
    return url.origin === "https://api.inline.chat" && url.pathname === "/file" && !url.hash
      && ["id", "exp", "sig"].every((key) => url.searchParams.getAll(key).length === 1 && Boolean(url.searchParams.get(key)))
      && /^\d+$/.test(url.searchParams.get("exp")!) && Number(url.searchParams.get("exp")) > Date.now() / 1000 ? link : null
  }
  const originalLink = (value: unknown, fileUniqueId: unknown): string | null => {
    const proxy = fileUrl(value); if (proxy) return proxy
    const link = safeLink(value)
    if (!link || typeof fileUniqueId !== "string" || !/^[A-Za-z0-9_-]{6,128}$/.test(fileUniqueId)) return null
    try {
      const url = new URL(link)
      // Canonical direct R2 capabilities are host-open-only. They can never
      // become image src, iframe src, or broaden the embedded resource CSP.
      if (url.protocol !== "https:" || !/^[a-f0-9]{32}\.r2\.cloudflarestorage\.com$/.test(url.hostname) || url.port || url.username || url.password || url.hash) return null
      const path = url.pathname.split("/").map((part) => decodeURIComponent(part))
      if (path.length !== 5 || !path[1] || path[2] !== "files" || path[3] !== fileUniqueId || !path[4] || path.some((part) => part.includes("/") || part === "." || part === "..")) return null
      const keys = ["X-Amz-Algorithm", "X-Amz-Credential", "X-Amz-Date", "X-Amz-Expires", "X-Amz-SignedHeaders", "X-Amz-Signature"]
      if (keys.some((key) => url.searchParams.getAll(key).length !== 1)) return null
      if (url.searchParams.get("X-Amz-Algorithm") !== "AWS4-HMAC-SHA256" || url.searchParams.get("X-Amz-SignedHeaders") !== "host" || !/^[a-f0-9]{64}$/.test(url.searchParams.get("X-Amz-Signature")!)) return null
      const date = url.searchParams.get("X-Amz-Date")!
      if (!/^\d{8}T\d{6}Z$/.test(date) || !new RegExp(`^[A-Za-z0-9]+/${date.slice(0, 8)}/auto/s3/aws4_request$`).test(url.searchParams.get("X-Amz-Credential")!)) return null
      const signedAt = Date.parse(`${date.slice(0, 4)}-${date.slice(4, 6)}-${date.slice(6, 8)}T${date.slice(9, 11)}:${date.slice(11, 13)}:${date.slice(13, 15)}Z`)
      if (!Number.isFinite(signedAt) || signedAt > Date.now() + 15 * 60 * 1000 || new Date(signedAt).toISOString().replace(/[-:]/g, "").replace(".000", "") !== date) return null
      const expires = url.searchParams.get("X-Amz-Expires")!
      if (!/^\d+$/.test(expires) || Number(expires) < 1 || Number(expires) > 604800 || signedAt + Number(expires) * 1000 <= Date.now()) return null
      return url.href
    } catch { return null }
  }
  const metadataOf = (result: R): R => record(result._meta) && record(result._meta.inline) ? result._meta.inline : {}
  const openLink = async (url: string, target: HTMLElement): Promise<void> => {
    if (!canOpen()) return
    try { await request("ui/open-link", { url }) } catch {
      if (!disposed && target.isConnected) { const el = node("p", "Could not open this link. Try again in chat.", "action-error"); el.setAttribute("role", "alert"); target.append(el); sizeChanged() }
    }
  }
  const richText = (el: HTMLElement, text: string, entities: unknown): void => {
    const values = Array.isArray(entities) ? entities : []
    const valid = values.filter((v): v is R => {
      if (!record(v) || !Number.isSafeInteger(v.offset) || !Number.isSafeInteger(v.length) || (v.offset as number) < 0 || (v.length as number) <= 0 || (v.offset as number) + (v.length as number) > text.length) return false
      const boundary = (at: number) => !(at > 0 && at < text.length && /[\uD800-\uDBFF]/.test(text[at - 1]!) && /[\uDC00-\uDFFF]/.test(text[at]!))
      return boundary(v.offset as number) && boundary((v.offset as number) + (v.length as number))
    }).slice(0, 500)
    const cuts = [...new Set([0, text.length, ...valid.flatMap((v) => [v.offset as number, (v.offset as number) + (v.length as number)])])].sort((a, b) => a - b)
    const tags: Record<string, keyof HTMLElementTagNameMap> = { 5: "strong", 6: "em", 8: "code", 9: "code", 15: "u", 16: "s", 17: "mark" }
    for (let i = 0; i < cuts.length - 1; i++) {
      const start = cuts[i]!, end = cuts[i + 1]!
      const covering = valid.filter((v) => (v.offset as number) <= start && (v.offset as number) + (v.length as number) >= end)
      let child: Node = document.createTextNode(text.slice(start, end))
      for (const v of covering) { const tag = tags[String(v.type)]; if (tag) { const wrapper = node(tag); if (v.type === 9) wrapper.className = "preformatted"; wrapper.append(child); child = wrapper } }
      const entity = covering.find((v) => v.type === 2 || v.type === 3)
      const url = safeLink(entity ? entity.type === 3 ? entity.url : text.slice(entity.offset as number, (entity.offset as number) + (entity.length as number)) : null)
      if (url && canOpen()) {
        const link = node("a"); link.href = url; link.rel = "noopener noreferrer"
        link.addEventListener("click", (event) => { event.preventDefault(); void openLink(url, el) }); link.append(child); child = link
      }
      el.append(child)
    }
  }
  const senderName = (message: R, chat: R | null): string | null => {
    if (message.out === true) return "You"
    const supplied = named(message.senderDisplayName); if (supplied) return supplied
    if (chat?.kind === "dm" && record(chat.peer) && (chat.peer.userId === message.fromId || chat.peer.userId == null)) return named(chat.peer.displayName) ?? (named(chat.peer.username) ? `@${named(chat.peer.username)}` : null)
    return null
  }
  // Native InlineAvatarCore palette and UTF-8 name seed; one grapheme initial.
  const palette = ["#db2678", "#ff9400", "#8a52eb", "#dba305", "#00a194", "#057aff", "#00b8a6", "#33ad4d", "#eb3833", "#5957d6", "#1fb87a", "#00addb"]
  const colorFor = (name: string | null): string => palette[new TextEncoder().encode(name?.replace(/^@+/, "") || "User").reduce((sum, byte) => (sum + byte) % palette.length, 0)]!
  const avatar = (name: string | null, rawUrl: unknown): HTMLElement => {
    const el = node("span", undefined, "avatar"); el.setAttribute("aria-hidden", "true"); el.style.setProperty("--avatar-color", colorFor(name))
    const seed = name?.replace(/^@+/, "") || "", segmenter = typeof Intl.Segmenter === "function" ? new Intl.Segmenter(undefined, { granularity: "grapheme" }) : null
    const initial = (segmenter ? Array.from(segmenter.segment(seed))[0]?.segment : Array.from(seed)[0]) ?? ""
    el.append(node("span", initial.toUpperCase(), initial ? "avatar-initial" : "avatar-person"))
    const url = fileUrl(rawUrl)
    if (url) { const img = node("img"); img.alt = ""; img.referrerPolicy = "no-referrer"; img.loading = "lazy"; img.decoding = "async"; img.addEventListener("error", () => { img.hidden = true }, { once: true }); img.src = url; el.append(img) }
    return el
  }
  const bytes = (v: unknown): string | null => {
    if (typeof v !== "number" || !Number.isFinite(v) || v < 0) return null
    const i = v === 0 ? 0 : Math.min(3, Math.floor(Math.log(v) / Math.log(1000)))
    return `${new Intl.NumberFormat(undefined, { maximumFractionDigits: i ? 1 : 0 }).format(v / 1000 ** i)} ${["B", "KB", "MB", "GB"][i]}`
  }
  const duration = (v: unknown): string | null => typeof v === "number" && Number.isFinite(v) && v >= 0 ? `${Math.floor(v / 60)}:${String(Math.floor(v % 60)).padStart(2, "0")}` : null
  let closePhoto: (() => void) | null = null
  const showPhoto = (url: string, label: string, trigger: HTMLElement): void => {
    closePhoto?.()
    if (!fileUrl(url)) { trigger.parentElement?.append(node("p", "Attachment expired. Load its source again in chat.", "media-unavailable")); sizeChanged(); return }
    const dialog = node("div", undefined, "media-viewer"); dialog.setAttribute("role", "dialog"); dialog.setAttribute("aria-modal", "true"); dialog.setAttribute("aria-label", label)
    const content = node("div", undefined, "media-viewer-content")
    const close = (): void => { dialog.remove(); window.removeEventListener("keydown", keydown); closePhoto = null; if (trigger.isConnected) trigger.focus() }
    const keydown = (event: KeyboardEvent): void => {
      if (event.key === "Escape") close()
      if (event.key === "Tab") {
        const controls = Array.from(dialog.querySelectorAll<HTMLElement>("button,a")), first = controls[0], last = controls.at(-1)
        if (event.shiftKey && document.activeElement === first) { event.preventDefault(); last?.focus() }
        else if (!event.shiftKey && document.activeElement === last) { event.preventDefault(); first?.focus() }
      }
    }
    closePhoto = close
    const closeButton = button("Close", "close-media", close), toolbar = node("div", undefined, "media-toolbar")
    toolbar.append(node("strong", label), closeButton)
    const img = node("img"); img.alt = label; img.referrerPolicy = "no-referrer"; img.decoding = "async"
    img.addEventListener("error", () => { img.remove(); content.append(node("p", "This photo is unavailable. Try loading its source again.", "media-unavailable")) }, { once: true }); img.src = url
    content.append(toolbar, img)
    if (canOpen()) content.append(button("Open in browser", "open-original", () => { void openLink(url, content) }))
    dialog.append(content); dialog.addEventListener("click", (event) => { if (event.target === dialog) close() }); root.append(dialog); window.addEventListener("keydown", keydown); closeButton.focus()
  }
  const media = (item: Item, metadata: R, compact: boolean): HTMLElement | null => {
    const value = item.message?.media; if (!value) return null
    const el = node("div", undefined, `attachment${compact ? " source-media" : ""}`)
    const names: Record<string, string> = { photo: "Photo", video: "Video", document: "File", voice: "Voice message", nudge: "Nudge" }
    const label = named(value.fileName) ?? names[String(value.kind)] ?? "Attachment"
    const signed = record(metadata.messageMedia) && record(metadata.messageMedia[`${item.chatId}:${item.messageId}`]) ? metadata.messageMedia[`${item.chatId}:${item.messageId}`] as R : {}
    const thumbnail = fileUrl(signed.thumbnailUrl), original = value.kind === "photo" ? fileUrl(signed.originalUrl) : originalLink(signed.originalUrl, signed.originalFileUniqueId)
    if (thumbnail && ["photo", "video", "document"].includes(String(value.kind))) {
      const frame = node("div", undefined, value.kind === "document" ? "photo-frame document-thumbnail" : "photo-frame"), img = node("img")
      img.alt = label; img.referrerPolicy = "no-referrer"; img.loading = "lazy"; img.decoding = "async"
      if (typeof value.width === "number" && typeof value.height === "number" && value.width > 0 && value.height > 0) frame.style.aspectRatio = String(Math.min(3, Math.max(0.6, value.width / value.height)))
      img.addEventListener("error", () => { img.remove(); frame.append(node("span", "Preview unavailable", "media-unavailable")); sizeChanged() }, { once: true }); img.src = thumbnail; frame.append(img)
      if (value.kind === "document") el.classList.add("with-document-thumbnail")
      if (original && value.kind === "photo") {
        const open = button("", "photo-open", () => { showPhoto(original, label, open) }); open.setAttribute("aria-label", "Open photo"); open.append(frame); el.append(open)
      } else el.append(frame)
    }
    const details = node("div", undefined, "file-details"); details.append(node("strong", label, "file-name"))
    const types: Record<string, string> = { "application/pdf": "PDF", "text/plain": "Text", "application/zip": "ZIP", "application/vnd.openxmlformats-officedocument.wordprocessingml.document": "Word document", "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet": "Spreadsheet" }
    const mime = named(value.mimeType)
    const facts = [value.kind === "document" && mime ? types[mime] ?? mime.split("/").at(-1)?.toUpperCase() : null, bytes(value.sizeBytes), duration(value.durationSeconds)].filter(Boolean)
    if (facts.length) details.append(node("span", facts.join(" · "), "file-meta"))
    if (original && value.kind === "photo") { const open = button("Open photo", "media-open", () => { showPhoto(original, label, open) }); details.append(open) }
    else if (original && canOpen() && ["video", "document", "voice"].includes(String(value.kind))) details.append(button(value.kind === "document" ? "Open file" : value.kind === "video" ? "Open video" : "Open audio", "media-open", () => { const fresh = originalLink(original, signed.originalFileUniqueId)
      if (fresh) void openLink(fresh, el); else { el.append(node("p", "Attachment expired. Load its source again in chat.", "media-unavailable")); sizeChanged() } }))
    else if (value.kind !== "nudge") details.append(node("span", original ? "Opening attachments is unavailable in this host" : "Attachment unavailable", "media-unavailable"))
    // Clickable photos already communicate their kind. Avoid a duplicate tile.
    if (thumbnail && original && value.kind === "photo") {
      if (named(value.fileName)) el.append(node("span", label, "file-meta"))
    } else el.append(details)
    return el
  }
  const parse = (result: unknown): { data: Data; metadata: R } | null => {
    if (!record(result) || result.isError === true || !record(result.structuredContent)) return null
    const payload = result.structuredContent
    // Old published v1 resource definitions render selected evidence only.
    const legacy = !payload.presentation && record(payload.chat) && Array.isArray(payload.messages)
    const candidate = legacy ? {
      presentation: "sources", chats: [{ chatId: (payload.chat as R).chatId, status: "available", chat: payload.chat }],
      items: (payload.messages as unknown[]).map((message) => ({ chatId: (payload.chat as R).chatId, messageId: record(message) ? message.id : null, status: "available", message })),
      activeChatId: null, page: { kind: "selected", nextOffsetId: null, nextAfterId: null, anchorMessageId: null, firstUnreadMessageId: null, note: null },
    } : payload
    if (!["sources", "catch_up"].includes(String(candidate.presentation)) || !Array.isArray(candidate.chats) || candidate.chats.length > 20
      || !Array.isArray(candidate.items) || candidate.items.length > (legacy ? 50 : candidate.presentation === "sources" ? 20 : 100)
      || !nullableId(candidate.activeChatId) || !record(candidate.page)) return null
    const chats: Chat[] = [], chatIds = new Set<string>()
    for (const v of candidate.chats) {
      if (!record(v) || !id(v.chatId) || chatIds.has(v.chatId) || !["available", "unavailable"].includes(String(v.status))
        || (v.status === "available" ? !record(v.chat) || v.chat.chatId !== v.chatId || typeof v.chat.title !== "string" : v.chat !== null)) return null
      chatIds.add(v.chatId); chats.push(v as Chat)
    }
    if (candidate.activeChatId !== null && !chatIds.has(candidate.activeChatId as string)) return null
    const items: Item[] = [], keys = new Set<string>()
    for (const v of candidate.items) {
      if (!record(v) || !id(v.chatId) || !chatIds.has(v.chatId) || !id(v.messageId) || !["available", "unavailable"].includes(String(v.status))) return null
      const m = v.message
      if (v.status === "available" ? !record(m) || m.id !== v.messageId || m.chatId !== v.chatId || typeof m.text !== "string" || typeof m.out !== "boolean"
        || !(m.fromId === null || id(m.fromId)) || !(m.date === null || typeof m.date === "string")
        || (m.senderDisplayName !== undefined && typeof m.senderDisplayName !== "string") || (m.snippet !== undefined && typeof m.snippet !== "string")
        || (m.media !== null && (!record(m.media) || !["photo", "video", "document", "voice", "nudge"].includes(String(m.media.kind)))) : m !== null) return null
      if (candidate.presentation === "catch_up" && v.chatId !== candidate.activeChatId) return null
      const key = `${v.chatId}:${v.messageId}`; if (keys.has(key)) return null
      keys.add(key); items.push(v as Item)
    }
    const page = candidate.page as R
    if (!["selected", "latest", "older", "newer", "context", "unread"].includes(String(page.kind)) || !nullableId(page.nextOffsetId)
      || !(page.nextAfterId === undefined || nullableId(page.nextAfterId)) || !nullableId(page.anchorMessageId) || !nullableId(page.firstUnreadMessageId)
      || !(page.note === null || typeof page.note === "string")) return null
    if (candidate.presentation === "catch_up" && (!candidate.activeChatId || page.kind === "selected")) return null
    return { data: { presentation: candidate.presentation as Data["presentation"], chats, items, activeChatId: candidate.activeChatId as string | null,
      page: { ...(page as unknown as Page), nextAfterId: page.nextAfterId as string | null ?? null } }, metadata: metadataOf(result) }
  }
  const chatFor = (chatId: string): Chat | undefined => data?.chats.find((chat) => chat.chatId === chatId)
  const title = (chat: Chat | undefined): string => named(chat?.chat?.title) ?? "Unavailable chat"
  const subtitle = (chat: Chat): string | null => {
    const space = record(chat.chat?.space) ? named(chat.chat.space.name) : null
    return space && space !== title(chat) ? space : chat.chat?.kind === "dm" ? "Direct message" : null
  }
  const excerpt = (message: Message): string => {
    // Preserve original UTF-16 entity offsets; normalized snippets cannot.
    const chars = Array.from(message.text); return chars.length > 240 ? `${chars.slice(0, 240).join("").trimEnd()}…` : message.text
  }
  const savePosition = (): void => {
    if (!activeChatId || !expanded) return
    const history = root.querySelector<HTMLElement>(".history"), state = states.get(activeChatId)
    if (history && state) state.scrollTop = history.scrollTop
  }
  const load = async (chatId: string, options: R = {}): Promise<void> => {
    if (!data || !canCall()) return
    savePosition()
    const epoch = generation, seq = ++navigation, previous = states.get(chatId)
    let authoritativeFailure = false
    const history = root.querySelector<HTMLElement>(".history"), oldHeight = history?.scrollHeight ?? 0, oldTop = history?.scrollTop ?? previous?.scrollTop ?? 0
    const anchorRow = history ? Array.from(history.querySelectorAll<HTMLElement>(".message")).find((row) => row.getBoundingClientRect().bottom > history.getBoundingClientRect().top) : null
    const anchorId = anchorRow?.dataset.messageId
    const anchorDelta = anchorRow && history ? anchorRow.getBoundingClientRect().top - history.getBoundingClientRect().top : 0
    const paging = options.offsetId !== undefined || options.afterId !== undefined
    activeChatId = chatId; loading = true; notice = null; mobileList = false
    if (!paging) states.delete(chatId)
    render()
    try {
      const result = await request("tools/call", { name: "messages.view", arguments: { presentation: "catch_up", chatIds: data.chats.map((chat) => chat.chatId), activeChatId: chatId, ...options } })
      if (disposed || epoch !== generation || seq !== navigation) return
      const parsed = parse(result)
      if (!parsed || parsed.data.presentation !== "catch_up" || parsed.data.activeChatId !== chatId || parsed.data.chats.length !== data.chats.length
        || parsed.data.chats.some((chat) => !data!.chats.some((old) => old.chatId === chat.chatId))) { authoritativeFailure = true; throw new Error("Invalid result") }
      data = parsed.data
      initialMetadata = parsed.metadata
      for (const chat of data.chats) if (chat.status === "unavailable") states.delete(chat.chatId)
      if (data.chats.find((chat) => chat.chatId === chatId)?.status !== "available") {
        loading = false; notice = "This conversation is unavailable or you no longer have access."; render(); return
      }
      const items = paging && previous ? options.offsetId ? [...data.items, ...previous.items] : [...previous.items, ...data.items] : data.items
      let unique = [...new Map(items.map((item) => [`${item.chatId}:${item.messageId}`, item])).values()]
      const page = { ...data.page }
      if (paging && previous) {
        if (options.offsetId) page.nextAfterId = previous.page.nextAfterId; else page.nextOffsetId = previous.page.nextOffsetId
        page.firstUnreadMessageId = previous.page.firstUnreadMessageId ?? page.firstUnreadMessageId
        page.anchorMessageId = previous.page.anchorMessageId
        page.kind = previous.page.kind
        page.note ??= previous.page.note
      }
      // Bound ephemeral DOM/history and preserve recoverable opposite paging.
      // Older pages trim the far newer tail; newer pages trim the older head.
      if (unique.length > 300) {
        unique = options.offsetId ? unique.slice(0, 300) : unique.slice(-300)
        if (options.offsetId) page.nextAfterId = unique.at(-1)!.messageId
        else page.nextOffsetId = unique[0]!.messageId
      }
      const metadata = paging && previous ? {
        ...previous.metadata, ...parsed.metadata,
        senderAvatarUrls: { ...(record(previous.metadata.senderAvatarUrls) ? previous.metadata.senderAvatarUrls : {}), ...(record(parsed.metadata.senderAvatarUrls) ? parsed.metadata.senderAvatarUrls : {}) },
        messageMedia: { ...(record(previous.metadata.messageMedia) ? previous.metadata.messageMedia : {}), ...(record(parsed.metadata.messageMedia) ? parsed.metadata.messageMedia : {}) },
      } : parsed.metadata
      if (record(metadata.messageMedia)) {
        const retained = new Set(unique.map((item) => `${item.chatId}:${item.messageId}`))
        metadata.messageMedia = Object.fromEntries(Object.entries(metadata.messageMedia).filter(([key]) => retained.has(key)))
      }
      if (record(metadata.senderAvatarUrls)) {
        const retainedSenders = new Set(unique.flatMap((item) => {
          const reply = record(item.message?.replyToMessage) ? item.message.replyToMessage : null
          return [item.message?.fromId, reply?.fromId].filter((sender): sender is string => id(sender))
        }))
        metadata.senderAvatarUrls = Object.fromEntries(Object.entries(metadata.senderAvatarUrls).filter(([sender]) => retainedSenders.has(sender)))
      }
      // Nearest-newer unread windows enter at their earliest returned message.
      const entry = page.anchorMessageId ?? page.firstUnreadMessageId ?? (page.kind === "unread" ? unique[0]?.messageId ?? "latest" : "latest")
      states.set(chatId, { items: unique, page, metadata, scrollTop: previous?.scrollTop ?? 0, entry: paging ? null : entry })
      loading = false; render()
      const updated = root.querySelector<HTMLElement>(".history")
      if (updated && paging) {
        const anchor = anchorId ? updated.querySelector<HTMLElement>(`.message[data-message-id="${anchorId}"]`) : null
        updated.scrollTop = anchor ? updated.scrollTop + anchor.getBoundingClientRect().top - updated.getBoundingClientRect().top - anchorDelta
          : options.offsetId ? Math.max(0, oldTop + updated.scrollHeight - oldHeight) : oldTop
        states.get(chatId)!.scrollTop = updated.scrollTop
      }
    } catch {
      if (disposed || epoch !== generation || seq !== navigation) return
      loading = false
      if (paging && previous && !authoritativeFailure) states.set(chatId, previous)
      else states.delete(chatId)
      notice = "Could not load this conversation. Try again or ask in chat."; render()
    }
  }
  const switchChat = (chatId: string): void => {
    if (!data || chatFor(chatId)?.status !== "available") return
    savePosition(); navigation++; loading = false; notice = null; activeChatId = chatId; mobileList = false
    if (states.has(chatId)) render(); else void load(chatId, { startAt: "unread" })
  }
  const setDisplay = async (mode: "inline" | "fullscreen"): Promise<boolean> => {
    if (!Array.isArray(host.availableDisplayModes) || !host.availableDisplayModes.includes(mode)) return false
    const epoch = generation
    try {
      const response = await request("ui/request-display-mode", { mode })
      if (disposed || epoch !== generation || !record(response)) return false
      expanded = response.mode === "fullscreen"; host.displayMode = response.mode
      if (mode === "fullscreen" && !expanded) {
        notice = "Expanded view isn’t available here."
        if (data?.presentation === "sources") allSources = true
      }
      render()
      return expanded === (mode === "fullscreen")
    } catch {
      if (disposed || epoch !== generation) return false
      notice = "The host could not expand this reader. Continue in chat."; render(); return false
    }
  }
  const showContext = async (item: Item): Promise<void> => {
    if (expanded || await setDisplay("fullscreen")) await load(item.chatId, { anchorMessageId: item.messageId })
  }
  const serviceLabel = (service: R): string => service.kind === "pinned_message" ? "Pinned a message" : service.kind === "thread_backlink" ? named(service.title) ? `Thread: ${named(service.title)}` : "Created a thread" : "Service message"
  const source = (item: Item, metadata: R, contextAction = true): HTMLElement => {
    const row = node("li", undefined, `source${item.status === "unavailable" ? " unavailable-source" : ""}`)
    row.dataset.chatId = item.chatId; row.dataset.messageId = item.messageId
    const chat = chatFor(item.chatId), provenance = node("div", undefined, "source-provenance")
    provenance.append(node("strong", title(chat), "source-chat")); const space = chat ? subtitle(chat) : null
    if (space) provenance.append(node("span", space, "source-space")); row.append(provenance)
    if (!item.message) { row.append(node("p", "This source is unavailable or you no longer have access.", "media-unavailable")); return row }
    const message = item.message, name = senderName(message, chat?.chat ?? null)
    row.style.setProperty("--source-color", colorFor(name))
    const quote = node("div", undefined, "source-quote"), author = node("div", undefined, "source-author")
    author.append(node("strong", name ?? "Member", name ? "sender" : "sender unknown-sender")); const date = time(message.date, true); if (date) author.append(date); quote.append(author)
    const short = excerpt(message), body = node("p", undefined, "message-text"); body.dir = "auto"
    richText(body, short || (record(message.serviceMessage) ? serviceLabel(message.serviceMessage) : message.media ? "" : "Empty message"), message.entities); quote.append(body)
    const attachment = media(item, metadata, true); if (attachment) quote.append(attachment)
    if (message.textTruncated === true) quote.append(node("p", "Message text is truncated.", "media-unavailable"))
    if (short !== message.text) {
      let open = false
      const toggle = button("Show more", "expand-text", () => { open = !open; body.replaceChildren(); richText(body, open ? message.text : short, message.entities); toggle.textContent = open ? "Show less" : "Show more"; toggle.setAttribute("aria-expanded", String(open)); sizeChanged() })
      toggle.setAttribute("aria-expanded", "false"); quote.append(toggle)
    }
    row.append(quote)
    if (contextAction && canCall() && (expanded || canExpand())) row.append(button("Show context", "show-context", () => { void showContext(item) }))
    return row
  }
  const historyRow = (item: Item, metadata: R, grouped: boolean): HTMLElement => {
    const message = item.message!, chat = chatFor(item.chatId)?.chat ?? null, name = senderName(message, chat)
    if (record(message.serviceMessage)) {
      const service = message.serviceMessage, row = node("li", undefined, "message service-message")
      row.dataset.messageId = item.messageId; row.dataset.chatId = item.chatId
      const label = serviceLabel(service)
      row.append(node("span", label))
      if (service.kind === "pinned_message" && id(service.messageId) && canCall()) row.append(button("Show message", "service-jump", () => { void load(item.chatId, { anchorMessageId: service.messageId }) }))
      return row
    }
    const row = node("li", undefined, `message ${message.out ? "outgoing" : "incoming"}${grouped ? " grouped" : ""}`)
    row.dataset.messageId = item.messageId; row.dataset.chatId = item.chatId; row.style.setProperty("--source-color", colorFor(name))
    const avatars = record(metadata.senderAvatarUrls) ? metadata.senderAvatarUrls : {}
    if (!message.out) row.append(avatar(name, message.fromId ? avatars[message.fromId] : null))
    const content = node("div", undefined, "message-content"), bubble = node("div", undefined, "bubble")
    if (!grouped && !message.out) content.append(node("strong", name ?? "Member", name ? "sender" : "sender unknown-sender"))
    if (id(message.replyToMsgId)) {
      const targetId = message.replyToMsgId, preview = record(message.replyToMessage) ? message.replyToMessage : null, reply = node("div", undefined, "reply-preview")
      if (preview) reply.append(node("strong", senderName(preview, chat) ?? "Member"), node("span", named(preview.text)?.slice(0, 160) ?? (preview.media ? "Attachment" : "Message")))
      else reply.append(node("span", "Reply to a message"))
      const jump = (): void => {
        const target = root.querySelector<HTMLElement>(`.history .message[data-message-id="${targetId}"]`)
        if (target) { const history = root.querySelector<HTMLElement>(".history")!; history.scrollTop = target.offsetTop - history.offsetTop - 24; target.classList.add("highlighted"); target.tabIndex = -1; target.focus({ preventScroll: true }) }
        else if (canCall()) void load(item.chatId, { anchorMessageId: targetId })
      }
      if (canCall() || states.get(item.chatId)?.items.some((entry) => entry.messageId === targetId)) { const control = button("", "reply-jump", jump); control.setAttribute("aria-label", "Show replied-to message"); control.append(reply); bubble.append(control) } else bubble.append(reply)
    }
    const body = node("p", undefined, "message-text"); body.dir = "auto"; richText(body, message.text || (message.media ? "" : "Empty message"), message.entities)
    if (body.textContent) bubble.append(body)
    if (message.textTruncated === true) bubble.append(node("p", "Message text is truncated.", "media-unavailable"))
    const attachment = media(item, metadata, false); if (attachment) bubble.append(attachment)
    const stamp = node("div", undefined, "message-stamp"); if (dateOf(message.editDate)) stamp.append(node("span", "edited")); const date = time(message.date); if (date) stamp.append(date)
    if (stamp.childElementCount) bubble.append(stamp); content.append(bubble); row.append(content); return row
  }
  const render = (): void => {
    if (!data || disposed) return
    closePhoto?.(); root.replaceChildren(); root.setAttribute("aria-busy", String(loading))
    root.dataset.presentation = data.presentation; root.dataset.displayMode = expanded ? "fullscreen" : "inline"; root.dataset.pane = mobileList ? "list" : "chat"
    // Source collections stay a single ordered evidence surface, including in
    // fullscreen. They never turn into a misleading merged conversation.
    if (data.presentation === "sources" || !expanded) {
      const header = node("header", undefined, "compact-header")
      header.append(node("h2", data.presentation === "sources" ? "Sources" : data.chats.length === 1 ? title(data.chats[0]) : "Catch up in Inline"))
      if (data.presentation === "catch_up") {
        header.append(node("p", data.chats.map((chat) => title(chat)).join(" · "), "coverage preview-chat-list"))
        if (canExpand()) header.append(button("Expand", "expand-reader", () => { void setDisplay("fullscreen") }))
      } else if (expanded && Array.isArray(host.availableDisplayModes) && host.availableDisplayModes.includes("inline")) header.append(button("Close", "close-reader", () => { void setDisplay("inline") }))
      root.append(header)
      const list = node("ol", undefined, "source-list"); list.setAttribute("aria-label", data.presentation === "sources" ? "Selected original messages, in requested order" : "Conversation preview")
      const current = activeChatId ? states.get(activeChatId) : null, items = data.presentation === "sources" ? data.items : current?.items ?? data.items
      const preview = data.presentation === "sources" ? expanded || allSources ? items : items.slice(0, 5) : current?.page.kind === "latest" ? items.slice(-3) : items.slice(0, 3)
      for (const item of preview) list.append(source(item, current?.metadata ?? initialMetadata, data.presentation === "sources")); root.append(list)
      if (!items.length) root.append(node("p", loading ? "Loading conversation…" : "No messages returned in this window.", "empty-state"))
      if (data.presentation === "sources" && items.length > 5 && !expanded) root.append(button(allSources ? "Show fewer sources" : canExpand() ? `View all ${items.length} sources` : `Show all ${items.length} sources`, "show-all-sources", () => { if (canExpand() && !allSources) void setDisplay("fullscreen"); else { allSources = !allSources; render() } }))
      if (data.presentation === "catch_up") root.append(node("p", current?.page.note ?? "Preview of the loaded conversation window. Reading here does not mark messages read.", "compact-note"))
      if (notice) { const warning = node("p", notice, "action-error"); warning.setAttribute("role", "status"); root.append(warning) }; sizeChanged(); return
    }
    const reader = node("section", undefined, `reader${data.chats.length === 1 ? " single-chat" : ""}`); reader.setAttribute("aria-label", "Inline catch-up reader")
    if (data.chats.length > 1) {
      const nav = node("nav", undefined, "chat-list"); nav.setAttribute("aria-label", "Selected chats"); const heading = node("div", undefined, "chat-list-heading"); heading.append(node("strong", "Inline"))
      if (Array.isArray(host.availableDisplayModes) && host.availableDisplayModes.includes("inline")) heading.append(button("Close", "close-list", () => { savePosition(); void setDisplay("inline") }))
      nav.append(heading)
      for (const chat of data.chats) {
        const item = chat.status === "available" && canCall() ? button("", `chat-item${chat.chatId === activeChatId ? " active" : ""}`, () => { switchChat(chat.chatId) }) : node("div", undefined, "chat-item unavailable-chat")
        item.dataset.chatId = chat.chatId; if (chat.chatId === activeChatId) item.setAttribute("aria-current", "true")
        const metadata = states.get(chat.chatId)?.metadata ?? initialMetadata, avatars = record(metadata.chatAvatarUrls) ? metadata.chatAvatarUrls : {}
        item.append(avatar(chat.status === "available" ? title(chat) : null, avatars[chat.chatId]))
        const labels = node("span", undefined, "chat-labels"); labels.append(node("strong", title(chat), "chat-title"))
        labels.append(node("span", chat.status === "unavailable" ? "Unavailable" : named(chat.chat?.lastMessagePreview) ?? subtitle(chat) ?? "Conversation", "chat-preview")); item.append(labels)
        const unread = chat.chat?.unreadCount
        if (typeof unread === "number" && Number.isSafeInteger(unread) && unread > 0) { const badge = node("span", String(unread), "unread-badge"); badge.setAttribute("aria-label", `${unread} unread messages`); item.append(badge) }
        nav.append(item)
      }
      reader.append(nav)
    }
    const pane = node("section", undefined, "message-pane"), header = node("header", undefined, "reader-header")
    if (data.chats.length > 1) header.append(button("‹ Chats", "back-to-chats", () => { savePosition(); mobileList = true; render() }))
    const titles = node("div", undefined, "reader-title"), chat = activeChatId ? chatFor(activeChatId) : undefined
    titles.append(node("h2", title(chat))); const space = chat ? subtitle(chat) : null; if (space) titles.append(node("p", space, "coverage")); header.append(titles)
    if (canCall() && activeChatId) {
      if ((id(chat?.chat?.readMaxId) || chat?.chat?.readMaxId === "0") && typeof chat?.chat?.unreadCount === "number" && chat.chat.unreadCount > 0) {
        const unread = button("Since last read", "load-unread", () => { void load(activeChatId!, { startAt: "unread" }) }); unread.disabled = loading; header.append(unread)
      }
      const latest = button("Latest", "load-latest", () => { void load(activeChatId!, { startAt: "latest" }) }); latest.disabled = loading; header.append(latest)
    }
    if (Array.isArray(host.availableDisplayModes) && host.availableDisplayModes.includes("inline")) header.append(button("Close", "close-reader", () => { savePosition(); void setDisplay("inline") }))
    pane.append(header)
    const history = node("div", undefined, "history"); history.tabIndex = 0; history.setAttribute("aria-label", `${title(chat)} conversation history`)
    const state = activeChatId ? states.get(activeChatId) : null
    if (state && canCall() && state.page.nextOffsetId) { const older = button(loading ? "Loading…" : "Load older messages", "load-older", () => { void load(activeChatId!, { offsetId: state.page.nextOffsetId }) }); older.disabled = loading; history.append(older) }
    if (notice) { const warning = node("p", notice, "action-error"); warning.setAttribute("role", "alert"); history.append(warning); if (!state && canCall()) history.append(button("Try again", "retry-chat", () => { void load(activeChatId!, { startAt: "unread" }) })) }
    if (state) {
      const list = node("ol", undefined, "history-list"); list.setAttribute("aria-label", "Messages, oldest first")
      let previous: Message | null = null, boundaryShown = false
      const readMax = chat?.chat?.readMaxId
      for (const item of state.items) {
        if (!item.message) { list.append(source(item, state.metadata, false)); previous = null; continue }
        const message = item.message, date = dateOf(message.date), previousDate = dateOf(previous?.date), newDay = date && (!previousDate || !sameDay(date, previousDate))
        if (newDay) list.append(node("li", dayLabel(date), "date-separator"))
        const unread = state.page.firstUnreadMessageId === item.messageId
        const sinceRead = !boundaryShown && state.page.kind === "unread" && (id(readMax) || readMax === "0") && BigInt(item.messageId) > BigInt(readMax as string)
        if (unread || sinceRead) { list.append(node("li", unread ? "Unread messages" : "Since last read", unread ? "unread-separator" : "read-boundary-separator")); boundaryShown = true }
        const grouped = !!previous && !newDay && !unread && !sinceRead && message.fromId !== null && message.fromId === previous.fromId && message.out === previous.out
          && date !== null && previousDate !== null && Math.abs(date.getTime() - previousDate.getTime()) <= 5 * 60 * 1000
        list.append(historyRow(item, state.metadata, grouped)); previous = record(message.serviceMessage) ? null : message
      }
      history.append(list)
      if (!state.items.length) history.append(node("p", "No messages returned in this window.", "empty-state"))
      if (canCall() && state.page.nextAfterId) { const newer = button(loading ? "Loading…" : "Load newer messages", "load-newer", () => { void load(activeChatId!, { afterId: state.page.nextAfterId }) }); newer.disabled = loading; history.append(newer) }
      if (state.page.note) history.append(node("p", state.page.note, "page-note"))
    } else if (loading) history.append(node("p", "Loading conversation…", "empty-state"))
    pane.append(history, node("p", "Reading here doesn’t mark messages read.", "reader-note")); reader.append(pane); root.append(reader)
    if (state) {
      if (state.entry) { const target = state.entry === "latest" ? null : history.querySelector<HTMLElement>(`.message[data-message-id="${state.entry}"]`); history.scrollTop = target ? Math.max(0, target.offsetTop - history.offsetTop - 24) : history.scrollHeight; state.entry = null }
      else history.scrollTop = state.scrollTop
      state.scrollTop = history.scrollTop; history.addEventListener("scroll", () => { state.scrollTop = history.scrollTop }, { passive: true })
    }
    sizeChanged()
  }
  const applyHost = (context: unknown): void => {
    if (!record(context)) return
    host = { ...host, ...context }
    if (context.theme === "dark" || context.theme === "light") document.documentElement.dataset.theme = context.theme
    if (context.displayMode === "inline" || context.displayMode === "fullscreen") { savePosition(); expanded = context.displayMode === "fullscreen" }
    if (record(context.safeAreaInsets)) for (const side of ["top", "right", "bottom", "left"]) { const v = context.safeAreaInsets[side]; if (typeof v === "number" && Number.isFinite(v) && v >= 0) root.style.setProperty(`--safe-${side}`, `${v}px`) }
    if (record(context.containerDimensions)) { const height = context.containerDimensions.height ?? context.containerDimensions.maxHeight; if (typeof height === "number" && Number.isFinite(height) && height > 0) root.style.setProperty("--host-height", `${height}px`) }
  }
  const accept = (result: unknown): void => {
    generation++; navigation++; loading = false; states.clear(); allSources = false; notice = null
    const parsed = parse(result)
    if (!parsed) { data = null; initialMetadata = {}; status("Inline could not display this result. Try again in chat.", true); return }
    data = parsed.data; initialMetadata = parsed.metadata; activeChatId = data.activeChatId
    if (activeChatId && data.presentation === "catch_up") states.set(activeChatId, { items: data.items, page: data.page, metadata: parsed.metadata, scrollTop: 0,
      entry: data.page.anchorMessageId ?? data.page.firstUnreadMessageId ?? (data.page.kind === "unread" ? data.items[0]?.messageId ?? "latest" : "latest") })
    render()
  }
  const matchesOuterScope = (result: unknown): boolean => {
    if (!outerArguments) return true
    const parsed = parse(result)
    if (!parsed) return true // An authoritative failed/malformed result clears old data.
    const current = parsed.data
    if (outerArguments.presentation === "sources" && Array.isArray(outerArguments.items)) {
      const requested = [...new Set(outerArguments.items.filter(record).map((item) => `${item.chatId}:${item.messageId}`))]
      return current.presentation === "sources" && requested.length === current.items.length && requested.every((key, i) => key === `${current.items[i]?.chatId}:${current.items[i]?.messageId}`)
    }
    if (outerArguments.presentation === "catch_up" && Array.isArray(outerArguments.chatIds)) {
      const selected = [...new Set(outerArguments.chatIds)]
      const active = outerArguments.activeChatId ?? current.chats.find((chat) => chat.status === "available")?.chatId ?? selected[0]
      if (current.presentation !== "catch_up" || selected.length !== current.chats.length || !selected.every((key) => current.chats.some((chat) => chat.chatId === key)) || current.activeChatId !== active) return false
      if (current.chats.find((chat) => chat.chatId === active)?.status === "unavailable") return true
      if (id(outerArguments.offsetId)) return current.page.kind === "older"
      if (id(outerArguments.afterId)) return current.page.kind === "newer"
      if (id(outerArguments.anchorMessageId)) return current.page.kind === "context" && (current.page.anchorMessageId === outerArguments.anchorMessageId || current.items.length === 0 && current.page.note !== null)
      return outerArguments.startAt === "unread" ? ["unread", "latest"].includes(current.page.kind) : current.page.kind === "latest"
    }
    return !id(outerArguments.chatId) || current.chats.length === 1 && current.chats[0]?.chatId === outerArguments.chatId
  }
  const onMessage = (event: MessageEvent): void => {
    if (disposed || event.source !== parent || !record(event.data) || event.data.jsonrpc !== "2.0") return
    const message = event.data
    if (message.method === "ping" && (typeof message.id === "string" || typeof message.id === "number")) send({ id: message.id, result: {} })
    else if (message.method === "ui/resource-teardown" && (typeof message.id === "string" || typeof message.id === "number")) {
      disposed = true; generation++; closePhoto?.(); window.clearTimeout(initializationTimeout); observer?.disconnect(); window.removeEventListener("message", onMessage); window.removeEventListener("resize", sizeChanged)
      for (const call of pending.values()) { window.clearTimeout(call.timer); call.reject(new Error("Disposed")) }; pending.clear(); ownToolInputs.clear(); root.replaceChildren(); send({ id: message.id, result: {} })
    } else if (message.id === 1 && message.method === undefined && !initialized) {
      window.clearTimeout(initializationTimeout)
      if (!record(message.result) || message.error || message.result.protocolVersion !== "2026-01-26") { status("Inline could not connect this reader. Try again in chat.", true); return }
      capabilities = record(message.result.hostCapabilities) ? message.result.hostCapabilities : {}; applyHost(message.result.hostContext); initialized = true; send({ method: "ui/notifications/initialized", params: {} }); sizeChanged()
    } else if (typeof message.id === "number" && message.method === undefined && pending.has(message.id)) {
      const call = pending.get(message.id)!; pending.delete(message.id)
      const own = ownToolInputs.get(message.id)
      if (own) { own.completed = true; if (own.resultEchoed) ownToolInputs.delete(message.id) }
      window.clearTimeout(call.timer)
      if (message.error) call.reject(new Error("Host request failed")); else call.resolve(message.result)
    } else if (initialized && message.method === "ui/notifications/tool-result") {
      // Widget tool calls return through correlated IDs; duplicate/stale outer
      // notifications cannot overwrite subsequent chat/page navigation.
      if (echoedToolCall !== null) {
        const own = ownToolInputs.get(echoedToolCall)
        if (own) { own.resultEchoed = true; if (own.completed) ownToolInputs.delete(echoedToolCall) }
        echoedToolCall = null
      } else if (awaitingResult && matchesOuterScope(message.params)) { awaitingResult = false; accept(message.params) }
    } else if (initialized && message.method === "ui/notifications/tool-input-partial") {
      // Optional streaming inputs are not authoritative; wait for complete args.
    } else if (initialized && message.method === "ui/notifications/tool-input") {
      const args = record(message.params) && record(message.params.arguments) ? message.params.arguments : null
      const sameArgs = (a: R, b: R): boolean => {
        const keys = Object.keys(a).sort(), other = Object.keys(b).sort()
        return keys.length === other.length && keys.every((key, index) => key === other[index] && JSON.stringify(a[key]) === JSON.stringify(b[key]))
      }
      // The standard permits hosts to echo input/result notifications for app
      // tool calls. Correlated RPC responses own these page merges exclusively.
      const echo = args ? [...ownToolInputs.entries()].find(([, own]) => sameArgs(own.args, args)) : null
      if (echo) { echoedToolCall = echo[0]; return }
      echoedToolCall = null
      for (const [key, own] of ownToolInputs) if (own.completed) ownToolInputs.delete(key)
      outerArguments = args
      generation++; navigation++; awaitingResult = true; data = null; initialMetadata = {}; states.clear(); closePhoto?.(); status("Loading Inline messages…")
    } else if (initialized && message.method === "ui/notifications/tool-cancelled") {
      generation++; navigation++; awaitingResult = false; data = null; states.clear(); closePhoto?.(); status("The message request was cancelled. Try again in chat.", true)
    } else if (initialized && message.method === "ui/notifications/host-context-changed") { applyHost(message.params); render() }
  }
  const initializationTimeout = window.setTimeout(() => { if (!initialized && !disposed) status("Inline could not connect this reader. Try again in chat.", true) }, 10_000)
  window.addEventListener("message", onMessage); window.addEventListener("resize", sizeChanged); status("Loading Inline messages…")
  send({ id: 1, method: "ui/initialize", params: { appInfo: { name: "inline-message-results", version: "2.0.0" }, appCapabilities: { availableDisplayModes: ["inline", "fullscreen"] }, protocolVersion: "2026-01-26" } })
}

// Native references: EmbeddedMessageView, MacTheme/Theme, DocumentView,
// ChatRowListViewModel. Compact sources have no nested scrolling or navigation.
export function createMessageResultsHtml(): string {
  return `<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><meta name="referrer" content="no-referrer"><title>Inline messages</title><style>
:root{color-scheme:light dark;--background:#fff;--text:#1d1d1f;--muted:#737378;--border:#e9e9ec;--accent:#007aff;--incoming:#efeff1;--outgoing:#00a7f8;--sidebar:#f8f8fa;--attachment:rgba(0,0,0,.04)}
@media(prefers-color-scheme:dark){:root:not([data-theme="light"]){--background:#1c1c1e;--text:#f5f5f7;--muted:#a1a1a6;--border:#38383a;--accent:#5ab0ff;--incoming:#303032;--outgoing:#0a84ff;--sidebar:#232325;--attachment:rgba(255,255,255,.06)}}
:root[data-theme="dark"]{color-scheme:dark;--background:#1c1c1e;--text:#f5f5f7;--muted:#a1a1a6;--border:#38383a;--accent:#5ab0ff;--incoming:#303032;--outgoing:#0a84ff;--sidebar:#232325;--attachment:rgba(255,255,255,.06)}:root[data-theme="light"]{color-scheme:light}
*{box-sizing:border-box}body{margin:0;background:var(--background);color:var(--text);font:14px/1.45 -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;-webkit-font-smoothing:antialiased}#root{width:100%;overflow-wrap:anywhere}p,h2{margin:0}h2{font-size:15px;font-weight:600;line-height:1.35}button,a{-webkit-tap-highlight-color:transparent}button{font:inherit;border:0;background:none;color:var(--accent);cursor:pointer;border-radius:5px;padding:4px 6px;font-size:12px}button:hover{background:var(--attachment)}button:disabled{cursor:default;color:var(--muted)}button:focus-visible,a:focus-visible,.history:focus-visible{outline:2px solid var(--accent);outline-offset:2px}a{color:var(--accent);text-decoration:underline;text-underline-offset:2px}ol{list-style:none;padding:0;margin:0}.coverage,.page-note,.compact-note,.reader-note,.file-meta,.media-unavailable{color:var(--muted);font-size:12px;line-height:1.4}.status,.empty-state{padding:18px 16px;color:var(--muted)}.action-error{font-size:12px;color:#bb3333;padding:8px 12px}.compact-header{display:flex;align-items:center;flex-wrap:wrap;gap:4px 12px;padding:12px 16px 5px}.compact-header .coverage{width:100%;order:2}.compact-header .close-reader,.expand-reader{margin-left:auto}.source-list{padding:4px 16px 12px}.source+.source{margin-top:15px}.source-provenance{display:flex;align-items:baseline;flex-wrap:wrap;gap:3px 8px;font-size:12px;margin-bottom:4px}.source-chat{font-weight:500}.source-space{color:var(--muted);font-size:11px}.source-quote{border-left:3px solid var(--source-color,var(--accent));padding:5px 9px;border-radius:3px 7px 7px 3px;background:color-mix(in srgb,var(--source-color,var(--accent)) 6%,var(--background))}.source-author{display:flex;align-items:baseline;flex-wrap:wrap;gap:3px 10px;margin-bottom:2px}.sender{font-size:12px;font-weight:600;color:color-mix(in srgb,var(--source-color,var(--accent)) 76%,var(--text));line-height:16px}.unknown-sender{color:var(--muted)}time{color:var(--muted);font-size:10px;white-space:nowrap}.message-text{white-space:pre-wrap;overflow-wrap:anywhere;line-height:1.45}.show-context{margin:3px 0 0 -6px}.show-all-sources{margin:0 16px 12px}.compact-note{padding:0 16px 12px}.attachment{display:flex;flex-direction:column;gap:6px;margin-top:6px;max-width:100%;border-radius:8px}.file-details{display:flex;flex-direction:column;align-items:flex-start;gap:1px;background:var(--attachment);padding:7px 9px;border-radius:7px}.file-name{font-size:12px;font-weight:500;white-space:normal}.media-open{padding:2px 0}.photo-frame{position:relative;width:280px;max-width:100%;aspect-ratio:1.55;border-radius:9px;overflow:hidden;background:var(--attachment);display:flex;align-items:center;justify-content:center}.photo-frame img{width:100%;height:100%;object-fit:contain}.with-document-thumbnail{flex-direction:row;align-items:center}.document-thumbnail{width:48px!important;height:48px;flex:0 0 48px}.photo-open{padding:0;display:block;max-width:100%}.source-media .photo-frame{width:160px;max-height:120px}.source-media .file-details{max-width:340px}.preformatted{display:block;white-space:pre-wrap;padding:5px;border-radius:5px;background:var(--attachment)}code{font:12px/1.45 ui-monospace,SFMono-Regular,Menlo,monospace}mark{background:#ffe79b;color:#1d1d1f}
.reader{display:grid;grid-template-columns:210px minmax(0,1fr);height:var(--host-height,100dvh);max-height:100dvh;padding:var(--safe-top,0px) var(--safe-right,0px) var(--safe-bottom,0px) var(--safe-left,0px);min-height:200px}.reader.single-chat{grid-template-columns:minmax(0,1fr)}.chat-list{background:var(--sidebar);border-right:1px solid var(--border);overflow-y:auto;min-width:0;padding:5px}.chat-list-heading{display:flex;align-items:center;justify-content:space-between;padding:12px 10px;font-size:15px;font-weight:600}.chat-item{display:flex;width:100%;align-items:center;gap:8px;text-align:left;padding:9px 7px;margin:1px 0;color:var(--text);border-radius:7px;min-width:0}.chat-item.active{background:color-mix(in srgb,var(--accent) 13%,var(--sidebar))}.chat-labels{display:flex;flex-direction:column;min-width:0;flex:1}.chat-title{font-size:13px;font-weight:500;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}.chat-preview{font-size:11px;color:var(--muted);overflow:hidden;text-overflow:ellipsis;white-space:nowrap}.unread-badge{color:#fff;background:var(--accent);padding:1px 5px;border-radius:10px;font-size:10px;min-width:18px;text-align:center}.avatar{position:relative;flex:0 0 28px;width:28px;height:28px;border-radius:50%;overflow:hidden;background:linear-gradient(color-mix(in srgb,var(--avatar-color) 65%,white),var(--avatar-color));color:#fff}.avatar-initial{display:flex;align-items:center;justify-content:center;height:100%;font-size:15px}.avatar-person:before,.avatar-person:after{content:"";position:absolute;background:#fff}.avatar-person:before{width:7px;height:7px;left:10.5px;top:6px;border-radius:50%}.avatar-person:after{width:14px;height:8px;left:7px;top:15px;border-radius:8px 8px 3px 3px}.avatar img{position:absolute;inset:0;width:100%;height:100%;object-fit:cover}.avatar img[hidden]{display:none}.message-pane{display:flex;flex-direction:column;min-height:0;min-width:0}.reader-header{display:flex;align-items:center;gap:8px;padding:10px 14px;border-bottom:1px solid var(--border);min-height:55px}.close-list{display:none}.reader-title{flex:1;min-width:0}.reader-title h2{overflow:hidden;text-overflow:ellipsis;white-space:nowrap}.back-to-chats{display:none}.history{flex:1;min-height:0;overflow-y:auto;overscroll-behavior:contain;padding:12px 16px;overflow-anchor:none}.history-list{padding-bottom:8px}.date-separator,.unread-separator,.read-boundary-separator{text-align:center;font-size:11px;color:var(--muted);padding:12px 0 8px}.date-separator:first-child{padding-top:0}.unread-separator,.read-boundary-separator{color:var(--accent);margin:8px 0;display:flex;align-items:center;gap:12px}.unread-separator:before,.unread-separator:after,.read-boundary-separator:before,.read-boundary-separator:after{content:"";height:1px;flex:1;background:color-mix(in srgb,var(--accent) 25%,var(--background))}.message{display:flex;gap:7px;align-items:flex-end;margin-top:12px}.message.service-message{display:flex;justify-content:center;align-items:center;flex-wrap:wrap;font-size:12px;color:var(--muted);padding:8px}.message.grouped{margin-top:3px}.message.grouped .avatar{visibility:hidden}.message-content{display:flex;flex-direction:column;align-items:flex-start;max-width:min(460px,calc(100% - 35px));min-width:0}.message-content>.sender{padding:0 10px 3px}.bubble{padding:6px 10px;background:var(--incoming);border-radius:14px 14px 14px 4px;min-width:0;max-width:100%}.message.grouped .bubble{border-top-left-radius:7px}.message-stamp{display:flex;align-items:center;justify-content:flex-end;gap:5px;font-size:10px;color:var(--muted);margin-top:3px}.outgoing{justify-content:flex-end}.outgoing .message-content{align-items:flex-end;max-width:min(460px,calc(100% - 28px))}.outgoing .bubble{background:var(--outgoing);color:#fff;border-radius:14px 14px 4px 14px}.outgoing.grouped .bubble{border-top-right-radius:7px;border-top-left-radius:14px}.outgoing .message-stamp,.outgoing time,.outgoing .file-meta,.outgoing .media-unavailable{color:rgba(255,255,255,.85)}.outgoing button,.outgoing a{color:#fff}.outgoing .attachment,.outgoing .file-details{--attachment:rgba(255,255,255,.15)}.reply-jump{display:block;width:100%;text-align:left;padding:0;color:inherit;font-size:12px;margin-bottom:4px}.reply-preview{display:flex;flex-direction:column;border-left:3px solid var(--accent);background:var(--attachment);border-radius:3px 5px 5px 3px;padding:4px 7px;font-size:12px;max-width:100%;overflow:hidden}.reply-preview span{overflow:hidden;text-overflow:ellipsis;display:-webkit-box;-webkit-line-clamp:2;-webkit-box-orient:vertical}.outgoing .reply-preview{border-color:rgba(255,255,255,.8)}.highlighted .bubble{outline:2px solid var(--accent);outline-offset:3px}.load-older,.load-newer{display:block;margin:0 auto 10px}.load-newer{margin:10px auto 0}.page-note{padding:8px 0}.reader-note{border-top:1px solid var(--border);padding:8px 14px;font-size:10px}.media-viewer{position:fixed;inset:0;z-index:10;background:rgba(0,0,0,.75);display:flex;align-items:center;justify-content:center;padding:16px}.media-viewer-content{display:flex;flex-direction:column;max-width:100%;max-height:100%;background:var(--background);border-radius:10px;padding:10px;gap:8px;min-width:0}.media-viewer-content>img{max-width:100%;max-height:calc(100dvh - 140px);object-fit:contain;min-height:0}.media-toolbar{display:flex;align-items:center;gap:12px;font-size:12px}.media-toolbar strong{flex:1}.media-toolbar button{flex-shrink:0}
@media(max-width:600px){.reader{grid-template-columns:minmax(0,1fr)}.reader:not(.single-chat) .chat-list{display:none}.back-to-chats{display:block}.reader.single-chat .back-to-chats{display:none}#root[data-pane="list"] .reader:not(.single-chat) .chat-list{display:block}#root[data-pane="list"] .reader:not(.single-chat) .message-pane{display:none}.chat-item{padding:12px 10px}.chat-list-heading{padding:12px 10px}.reader-header{padding:8px;flex-wrap:wrap}.reader-title{min-width:90px}.load-unread{order:4;margin-left:auto}.load-latest{order:5}.close-list{display:block}.reader-title h2{font-size:14px}.history{padding:10px}.message-content{max-width:calc(100% - 35px)}.reader-note{font-size:10px;padding:7px 10px}.compact-header,.source-list{padding-left:12px;padding-right:12px}.source-author{gap:2px 8px}.media-viewer{padding:8px}}
</style></head><body><main id="root" aria-label="Inline messages" aria-busy="true"><p class="status" role="status">Loading Inline messages…</p></main><script>(${messageResultsComponent.toString()})()</script></body></html>`
}

export function registerMessageResultsUi(server: McpServer): void {
  for (const uri of [MESSAGE_RESULTS_RESOURCE_URI, LEGACY_MESSAGE_RESULTS_RESOURCE_URI]) {
    server.registerResource(uri === MESSAGE_RESULTS_RESOURCE_URI ? "inline-message-results" : "inline-message-results-legacy", uri, {
      title: "Inline messages", description: "Selected original messages or an expanded read-only Inline catch-up reader.", mimeType: MESSAGE_RESULTS_MIME_TYPE,
    }, async () => ({ contents: [{ uri, mimeType: MESSAGE_RESULTS_MIME_TYPE, text: createMessageResultsHtml(), _meta: { ui: {
      prefersBorder: true, domain: "https://mcp.inline.chat", csp: { connectDomains: [], resourceDomains: ["https://api.inline.chat"], frameDomains: [] },
    } } }] }))
  }
}
