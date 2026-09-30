import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js"

export const MESSAGE_RESULTS_RESOURCE_URI = "ui://inline/message-results-v1.html"
export const MESSAGE_RESULTS_MIME_TYPE = "text/html;profile=mcp-app"

// Keep this function self-contained: its compiled JavaScript is embedded in the
// resource, so the deployed dist artifact needs no asset copy or remote bundle.
function messageResultsComponent(): void {
  const root = document.getElementById("root")!
  const parent = window.parent
  let initialized = false
  let disposed = false
  let lastSize = ""
  let inputOffsetId: string | null = null

  type RecordValue = Record<string, unknown>
  type MessageRow = {
    id: string
    text: string
    snippet?: string
    out: boolean
    fromId: string | null
    senderDisplayName?: string
    date: string | null
    media: RecordValue | null
  }
  const record = (value: unknown): value is RecordValue => value !== null && typeof value === "object" && !Array.isArray(value)
  const nullableString = (value: unknown): value is string | null => value === null || typeof value === "string"
  const id = (value: unknown): value is string => typeof value === "string" && /^[1-9]\d*$/.test(value)

  const send = (message: RecordValue): void => parent.postMessage({ jsonrpc: "2.0", ...message }, "*")
  const sizeChanged = (): void => {
    if (!initialized || disposed) return
    const bounds = root.getBoundingClientRect()
    const width = Math.ceil(bounds.width)
    const height = Math.ceil(bounds.height)
    const key = `${width}:${height}`
    if (key === lastSize) return
    lastSize = key
    send({ method: "ui/notifications/size-changed", params: { width, height } })
  }
  const resizeObserver = typeof ResizeObserver === "function" ? new ResizeObserver(sizeChanged) : null
  resizeObserver?.observe(root)

  const element = <K extends keyof HTMLElementTagNameMap>(tag: K, text?: string, className?: string): HTMLElementTagNameMap[K] => {
    const node = document.createElement(tag)
    if (text !== undefined) node.textContent = text
    if (className) node.className = className
    return node
  }
  const status = (text: string, error = false): void => {
    root.replaceChildren(element("p", text, "status"))
    root.setAttribute("aria-busy", error ? "false" : "true")
    root.firstElementChild?.setAttribute("role", error ? "alert" : "status")
    sizeChanged()
  }
  const messageDate = (value: string | null): Date | null => {
    if (value === null || !/^\d+$/.test(value)) return null
    const date = new Date(Number(value) * 1000)
    return Number.isFinite(date.getTime()) ? date : null
  }
  const timeFormat = new Intl.DateTimeFormat(undefined, { hour: "numeric", minute: "2-digit" })
  const dayFormat = new Intl.DateTimeFormat(undefined, { month: "short", day: "numeric" })
  const yearFormat = new Intl.DateTimeFormat(undefined, { month: "short", day: "numeric", year: "numeric" })
  const fullDateFormat = new Intl.DateTimeFormat(undefined, { dateStyle: "full", timeStyle: "short" })
  const sameDay = (first: Date, second: Date): boolean => first.getFullYear() === second.getFullYear()
    && first.getMonth() === second.getMonth() && first.getDate() === second.getDate()
  const timestamp = (date: Date): string => {
    const now = new Date()
    const yesterday = new Date(now)
    yesterday.setDate(yesterday.getDate() - 1)
    const day = sameDay(date, now) ? "Today" : sameDay(date, yesterday) ? "Yesterday"
      : (date.getFullYear() !== now.getFullYear() ? yearFormat : dayFormat).format(date)
    return `${day}, ${timeFormat.format(date)}`
  }
  const named = (value: unknown): string | null => typeof value === "string" && value.trim() ? value.trim() : null
  const senderName = (message: MessageRow, chat: RecordValue): string | null => {
    if (message.out) return "You"
    const suppliedName = named(message.senderDisplayName)
    if (suppliedName) return suppliedName
    if (chat.kind === "dm" && record(chat.peer)
      && (chat.peer.userId === message.fromId || chat.peer.userId == null)) {
      return named(chat.peer.displayName) ?? (named(chat.peer.username) ? `@${named(chat.peer.username)}` : null)
    }
    return null
  }
  // Match InlineAvatarCore/InlineAvatarPresentation.swift: UTF-8 byte sum,
  // the native 12-color palette, one initial, and a lighter top gradient stop.
  const avatarPalette = [
    [0.86, 0.15, 0.47], [1, 0.58, 0], [0.54, 0.32, 0.92], [0.86, 0.64, 0.02],
    [0, 0.63, 0.58], [0.02, 0.48, 1], [0, 0.72, 0.65], [0.20, 0.68, 0.30],
    [0.92, 0.22, 0.20], [0.35, 0.34, 0.84], [0.12, 0.72, 0.48], [0, 0.68, 0.86],
  ]
  const avatarStyle = (name: string | null): { base: string; top: string; initial: string | null } => {
    const seed = name?.replace(/^@+/, "") || "User"
    const index = new TextEncoder().encode(seed).reduce((sum, byte) => (sum + byte) % avatarPalette.length, 0)
    const [r, g, b] = avatarPalette[index]! as [number, number, number]
    const maximum = Math.max(r, g, b)
    const minimum = Math.min(r, g, b)
    const delta = maximum - minimum
    const lightness = (maximum + minimum) / 2
    const saturation = delta === 0 ? 0 : delta / (1 - Math.abs(2 * lightness - 1))
    const hue = delta === 0 ? 0 : 60 * (maximum === r ? ((g - b) / delta + 6) % 6
      : maximum === g ? (b - r) / delta + 2 : (r - g) / delta + 4)
    const segmenter = typeof Intl.Segmenter === "function" ? new Intl.Segmenter(undefined, { granularity: "grapheme" }) : null
    const initial = name ? (segmenter ? Array.from(segmenter.segment(seed))[0]?.segment : Array.from(seed)[0]) ?? null : null
    return {
      base: `rgb(${r * 255} ${g * 255} ${b * 255})`,
      top: `hsl(${hue} ${saturation * 100}% ${Math.min(1, lightness + 0.2) * 100}%)`,
      initial: initial?.toUpperCase() ?? null,
    }
  }
  const avatarUrl = (result: RecordValue, fromId: string | null): string | null => {
    const metadata = record(result._meta) && record(result._meta.inline) ? result._meta.inline : null
    const value = metadata && record(metadata.senderAvatarUrls) && fromId ? metadata.senderAvatarUrls[fromId] : null
    if (typeof value !== "string" || value.length > 4096) return null
    try {
      const url = new URL(value)
      return url.origin === "https://api.inline.chat" && url.pathname === "/file"
        && !url.username && !url.password && !url.hash
        && ["id", "exp", "sig"].every((key) => Boolean(url.searchParams.get(key))) ? url.href : null
    } catch {
      return null
    }
  }
  const avatar = (style: ReturnType<typeof avatarStyle>, url: string | null): HTMLElement => {
    const node = element("span", undefined, "avatar")
    node.setAttribute("aria-hidden", "true")
    node.append(element("span", style.initial ?? "", style.initial ? "avatar-initial" : "avatar-person"))
    if (url) {
      const photo = element("img")
      photo.alt = ""
      photo.width = 28
      photo.height = 28
      photo.referrerPolicy = "no-referrer"
      photo.loading = "lazy"
      photo.decoding = "async"
      photo.addEventListener("error", () => { photo.hidden = true }, { once: true })
      photo.src = url
      node.append(photo)
    }
    return node
  }
  const applyHostContext = (context: unknown): void => {
    if (!record(context)) return
    if (context.theme === "dark" || context.theme === "light") document.documentElement.dataset.theme = context.theme
  }

  const render = (result: unknown): void => {
    if (!record(result) || result.isError === true) {
      status("Inline could not load these messages. Try the request again in chat.", true)
      return
    }
    const data = result.structuredContent
    if (!record(data) || !record(data.chat) || !id(data.chat.chatId) || typeof data.chat.title !== "string"
      || !["dm", "home_thread", "space_chat"].includes(String(data.chat.kind)) || !Array.isArray(data.messages)
      || (data.nextOffsetId !== undefined && (!nullableString(data.nextOffsetId) || (data.nextOffsetId !== null && !id(data.nextOffsetId))))
      || !["all", "links", "media", "photos", "videos", "documents", "files"].includes(String(data.content))
      || !nullableString(data.since) || !nullableString(data.until) || (data.senderUserId !== undefined && !nullableString(data.senderUserId))
      || (data.query !== undefined && !nullableString(data.query))) {
      status("Inline returned a message result this card could not display. Try the request again in chat.", true)
      return
    }
    const rows: MessageRow[] = []
    for (const value of data.messages) {
      if (!record(value) || !id(value.id) || value.chatId !== data.chat.chatId || typeof value.text !== "string"
        || typeof value.out !== "boolean" || !nullableString(value.fromId) || !nullableString(value.date)
        || (value.senderDisplayName !== undefined && typeof value.senderDisplayName !== "string")
        || (value.snippet !== undefined && typeof value.snippet !== "string")
        || (value.media !== null && (!record(value.media) || !["photo", "video", "document", "voice", "nudge"].includes(String(value.media.kind))))) {
        status("Inline returned a message result this card could not display. Try the request again in chat.", true)
        return
      }
      rows.push(value as MessageRow)
    }

    const chat = data.chat
    const nextOffsetId = data.nextOffsetId ?? null
    const header = element("header")
    header.append(element("h2", chat.title as string))
    const context = chat.kind === "dm" ? "Direct message"
      : chat.kind === "home_thread" ? "Home thread"
      : record(chat.space) && typeof chat.space.name === "string" && chat.space.name ? chat.space.name : "Workspace"
    const hasQuery = typeof data.query === "string" && data.query.length > 0
    const filtered = hasQuery || (typeof data.content === "string" && data.content !== "all")
      || typeof data.since === "string" || typeof data.until === "string" || typeof data.senderUserId === "string"
    const noun = hasQuery ? (rows.length === 1 ? "match" : "matches") : (rows.length === 1 ? "message" : "messages")
    const scope = inputOffsetId ? "older " : hasQuery ? "" : filtered ? "filtered " : "recent "
    header.append(element("p", `${context} · ${rows.length} ${scope}${noun} · Newest first`, "coverage"))
    const filters: string[] = []
    if (hasQuery) filters.push(`“${data.query}”`)
    if (typeof data.content === "string" && data.content !== "all") filters.push(data.content[0]!.toUpperCase() + data.content.slice(1))
    if (typeof data.senderUserId === "string") {
      const author = rows.find((message) => message.fromId === data.senderUserId)
      const name = author ? senderName(author, chat) : null
      filters.push(name ? `From ${name}` : "Selected sender")
    }
    if (typeof data.since === "string") {
      const date = messageDate(data.since)
      filters.push(date ? `Since ${timestamp(date)}` : "Start date filter")
    }
    if (typeof data.until === "string") {
      const date = messageDate(data.until)
      filters.push(date ? `Until ${timestamp(date)}` : "End date filter")
    }
    if (filters.length) header.append(element("p", filters.join(" · "), "filters"))

    const list = element("ol")
    list.setAttribute("aria-label", "Returned messages, newest first")
    list.tabIndex = 0
    for (const [index, message] of rows.entries()) {
      const row = element("li", undefined, message.out ? "message outgoing" : "message incoming")
      const name = senderName(message, chat)
      const style = avatarStyle(name)
      row.style.setProperty("--avatar-base", style.base)
      row.style.setProperty("--avatar-top", style.top)
      const content = element("div", undefined, "message-content")
      const sender = element("strong", name ?? "Member", name ? "sender" : "sender unknown-sender")
      sender.dir = "auto"
      content.append(sender)
      const bubble = element("div", undefined, "bubble")
      if (!message.out) row.append(avatar(style, avatarUrl(result, message.fromId)))
      const excerpt = message.snippet && message.snippet.length < message.text.length ? message.snippet : message.text
      const body = element("p", excerpt || (message.media ? "" : "Empty message"), "message-text")
      body.dir = "auto"
      if (body.textContent) bubble.append(body)
      if (message.media) {
        const kinds: Record<string, string> = { photo: "Photo", video: "Video", document: "Document", voice: "Voice message", nudge: "Nudge" }
        const fileName = message.media.kind === "document" ? named(message.media.fileName) : null
        const attachment = element("p", fileName ? `Document · ${fileName}` : kinds[String(message.media.kind)], "attachment")
        attachment.dir = "auto"
        bubble.append(attachment)
      }
      if (excerpt !== message.text) {
        const button = element("button", "Show more")
        button.type = "button"
        const bodyId = `message-text-${index}`
        body.id = bodyId
        button.setAttribute("aria-controls", bodyId)
        button.setAttribute("aria-expanded", "false")
        let expanded = false
        button.addEventListener("click", () => {
          expanded = !expanded
          body.textContent = expanded ? message.text : excerpt
          button.textContent = expanded ? "Show less" : "Show more"
          button.setAttribute("aria-expanded", String(expanded))
          sizeChanged()
        })
        bubble.append(button)
      }
      const date = messageDate(message.date)
      if (date) {
        const time = element("time", timestamp(date))
        time.dateTime = date.toISOString()
        time.title = fullDateFormat.format(date)
        bubble.append(time)
      }
      content.append(bubble)
      row.append(content)
      list.append(row)
    }

    const footer = element("footer")
    if (nextOffsetId !== null) {
      if (!rows.length) footer.append(element("p", "No messages returned on this page."))
      footer.append(element("p", "Older results may be available. Ask in chat to continue."))
    } else if (!rows.length) {
      footer.append(element("p", filtered ? "No messages matched these filters on this page." : "No recent messages returned."))
    }
    root.replaceChildren(header, list, ...(footer.childElementCount ? [footer] : []))
    root.setAttribute("aria-busy", "false")
    sizeChanged()
  }

  const onMessage = (event: MessageEvent): void => {
    if (disposed || event.source !== parent || !record(event.data) || event.data.jsonrpc !== "2.0") return
    const message = event.data
    if (message.method === "ping" && (typeof message.id === "string" || typeof message.id === "number")) {
      send({ id: message.id, result: {} })
    } else if (message.method === "ui/resource-teardown" && (typeof message.id === "string" || typeof message.id === "number")) {
      disposed = true
      window.clearTimeout(initializationTimeout)
      resizeObserver?.disconnect()
      window.removeEventListener("message", onMessage)
      window.removeEventListener("resize", sizeChanged)
      root.replaceChildren()
      send({ id: message.id, result: {} })
    } else if (message.id === 1 && message.method === undefined) {
      if (initialized) return
      window.clearTimeout(initializationTimeout)
      if (!record(message.result) || message.error || message.result.protocolVersion !== "2026-01-26") {
        status("Inline could not connect this message card. Try the request again in chat.", true)
        return
      }
      applyHostContext(message.result.hostContext)
      initialized = true
      send({ method: "ui/notifications/initialized", params: {} })
      sizeChanged()
    } else if (initialized && message.method === "ui/notifications/tool-result") {
      render(message.params)
    } else if (initialized && (message.method === "ui/notifications/tool-input" || message.method === "ui/notifications/tool-input-partial")) {
      inputOffsetId = record(message.params) && record(message.params.arguments) && id(message.params.arguments.offsetId)
        ? message.params.arguments.offsetId : null
      status("Loading Inline messages…")
    } else if (initialized && message.method === "ui/notifications/tool-cancelled") {
      status("The message request was cancelled. Try again in chat.", true)
    } else if (initialized && message.method === "ui/notifications/host-context-changed") {
      applyHostContext(message.params)
    }
  }
  const initializationTimeout = window.setTimeout(() => {
    if (!initialized && !disposed) status("Inline could not connect this message card. Try the request again in chat.", true)
  }, 10_000)
  window.addEventListener("message", onMessage)
  window.addEventListener("resize", sizeChanged)
  status("Loading Inline messages…")
  send({ id: 1, method: "ui/initialize", params: {
    appInfo: { name: "inline-message-results", version: "1.0.0" },
    appCapabilities: { availableDisplayModes: ["inline"] },
    protocolVersion: "2026-01-26",
  } })
}

// Geometry and system colors follow MacTheme/Theme.swift and InlineTheme/ThemeCatalog.swift.
// Each returned hit retains its own author/date; sparse search results are never grouped.
export function createMessageResultsHtml(): string {
  return `<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>Inline messages</title>
<style>
:root{color-scheme:light dark;--background:#fff;--text:#1d1d1f;--muted:#6e6e73;--border:#e9e9ec;--accent:#007aff;--incoming:#ececec;--outgoing:#00a7f8;--name-mix:#000;--attachment:rgba(0,0,0,.045)}
@media(prefers-color-scheme:dark){:root:not([data-theme="light"]){--background:#1c1c1e;--text:#f5f5f7;--muted:#a1a1a6;--border:#38383a;--accent:#5ab0ff;--incoming:#2e2e2e;--outgoing:#0a84ff;--name-mix:#fff;--attachment:rgba(255,255,255,.06)}}
:root[data-theme="dark"]{--background:#1c1c1e;--text:#f5f5f7;--muted:#a1a1a6;--border:#38383a;--accent:#5ab0ff;--incoming:#2e2e2e;--outgoing:#0a84ff;--name-mix:#fff;--attachment:rgba(255,255,255,.06)}
:root[data-theme="light"]{color-scheme:light}:root[data-theme="dark"]{color-scheme:dark}
*{box-sizing:border-box}body{margin:0;background:var(--background);color:var(--text);font:14px/1.45 -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;-webkit-font-smoothing:antialiased}
#root{width:100%;overflow-wrap:anywhere}header,.status{padding:14px 16px;margin:0}header{border-bottom:1px solid var(--border)}h2{font-size:15px;line-height:1.35;font-weight:600;margin:0}p{margin:0}.coverage,.filters{font-size:12px;line-height:1.4;color:var(--muted)}.coverage{margin-top:3px}.filters{margin-top:5px;white-space:pre-wrap}
ol{list-style:none;padding:14px 16px 16px;margin:0;max-height:440px;overflow:auto;overscroll-behavior:contain}ol:empty{display:none}.message{display:flex;align-items:flex-end;gap:8px}.message+.message{margin-top:14px}.message-content{display:flex;flex-direction:column;align-items:flex-start;min-width:0;max-width:min(420px,calc(100% - 36px))}.sender{display:block;max-width:100%;padding:0 11px 3px;font-size:12px;line-height:16px;font-weight:600;color:color-mix(in srgb,var(--avatar-base) 68%,var(--name-mix));overflow:hidden;text-overflow:ellipsis;white-space:nowrap}.unknown-sender{color:var(--muted)}
.avatar{position:relative;flex:0 0 28px;width:28px;height:28px;overflow:hidden;border-radius:50%;background:linear-gradient(var(--avatar-top),var(--avatar-base));box-shadow:inset 0 0 0 .5px rgba(0,0,0,.1);color:#fff;user-select:none}.avatar-initial{display:flex;align-items:center;justify-content:center;width:100%;height:100%;font-size:15.4px;font-weight:400;line-height:1}.avatar-person:before,.avatar-person:after{content:"";position:absolute;background:#fff}.avatar-person:before{width:7px;height:7px;left:10.5px;top:6px;border-radius:50%}.avatar-person:after{width:14px;height:8px;left:7px;top:15px;border-radius:8px 8px 3px 3px}.avatar img{position:absolute;inset:0;width:28px;height:28px;object-fit:cover}.avatar img[hidden]{display:none}
.bubble{min-width:0;max-width:100%;padding:6px 11px;background:var(--incoming);border-radius:14px 14px 14px 4px}.message-text{white-space:pre-wrap}.attachment{padding:7px 9px;background:var(--attachment);border-radius:7px;font-size:12px;line-height:1.4}.message-text+.attachment{margin-top:6px}time{display:block;text-align:right;color:var(--muted);font-size:10px;line-height:14px;margin-top:3px}.outgoing{justify-content:flex-end}.outgoing .message-content{align-items:flex-end}.outgoing .sender{color:var(--muted)}.outgoing .bubble{background:var(--outgoing);color:#fff;border-radius:14px 14px 4px 14px}.outgoing time{color:rgba(255,255,255,.85)}.outgoing .attachment{background:rgba(255,255,255,.16)}
footer{padding:10px 16px;border-top:1px solid var(--border);font-size:12px;line-height:1.4;color:var(--muted)}footer p+p{margin-top:3px}
button{font:inherit;font-size:12px;background:none;color:var(--accent);border:0;border-radius:3px;padding:3px 0;margin-top:2px;cursor:pointer}.outgoing button{color:#fff}button:hover{text-decoration:underline}button:focus-visible,ol:focus-visible{outline:2px solid var(--accent);outline-offset:3px}.outgoing button:focus-visible{outline-color:#fff}
</style></head><body><main id="root" aria-label="Inline message results" aria-busy="true"><p class="status" role="status">Loading Inline messages…</p></main>
<script>(${messageResultsComponent.toString()})()</script></body></html>`
}

export function registerMessageResultsUi(server: McpServer): void {
  server.registerResource(
    "inline-message-results",
    MESSAGE_RESULTS_RESOURCE_URI,
    {
      title: "Inline message results",
      description: "Read-only message text and source details returned by Inline. Full text expansion is local to this result.",
      mimeType: MESSAGE_RESULTS_MIME_TYPE,
    },
    async () => ({
      contents: [{
        uri: MESSAGE_RESULTS_RESOURCE_URI,
        mimeType: MESSAGE_RESULTS_MIME_TYPE,
        text: createMessageResultsHtml(),
        _meta: { ui: {
          prefersBorder: true,
          domain: "https://mcp.inline.chat",
          csp: { connectDomains: [], resourceDomains: ["https://api.inline.chat"], frameDomains: [] },
        } },
      }],
    }),
  )
}
