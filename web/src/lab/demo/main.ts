/**
 * The demo lab: a demo account (the production core against a simulated
 * server in its worker) shown as plain text, with buttons for every world
 * control. Plain DOM and `@inline/reactive` effects; no view framework.
 *
 * `globalThis.__demoLab` holds the page's state as plain data (refreshed on
 * every render) and `globalThis.__demoLabActions` the actions, for browser
 * automation. Errors are shown on the page.
 */
import "./lab.css"
import {
  newClientKey,
  optimisticMessageRow,
  type ChatRow,
  type CoreResource,
  type DialogRow,
  type Intent,
  type MessageRow,
  type RowKey,
  type UserRow,
  type WindowResource,
} from "@inline/core-protocol"
import type { ChatID, MessageID } from "@inline/ids"
import { effect, setErrorHandler, type SubscriptionHandle } from "@inline/reactive"
import {
  DEFAULT_DEMO_CONFIG,
  parseDemoConfig,
  type DemoResult,
  type DemoStatus,
} from "../../../packages/client/src/testing/demo-protocol"
import { connectDemoAccount } from "../../core/demo/connect-demo"
import type { DemoCommandInput } from "../../core/demo/control"

// ---------------------------------------------------------------------------
// Page state, as plain data

type LabRow = { id: string; messageId?: string; fromId: string; text: string; state: string; edited: boolean; reactions?: string }

type LabState = {
  config: { scale: string; seed: number; storage: string }
  contextId: string
  role: string
  core: CoreResource | null
  status: DemoStatus | null
  sidebar: {
    count: number
    rows: Array<{ chatId: string; title: string; unreadCount: number; pinned: boolean }>
  }
  selectedChatId: string | null
  window: { resource: WindowResource | null; count: number; rows: LabRow[] }
  /** Milliseconds since navigation start. */
  timings: {
    coreReadyMs?: number
    sidebarFirstRowsMs?: number
    /** From selecting a chat to its first rows. */
    windowFirstRowsMs?: number
  }
  results: Array<{ at: string; what: string; ok: boolean; error?: string }>
  errors: string[]
}

const element = <T extends HTMLElement = HTMLElement>(id: string): T => {
  const found = document.getElementById(id)
  if (!found) throw new Error(`The page is missing #${id}`)
  return found as T
}

const lab: LabState = {
  config: { ...DEFAULT_DEMO_CONFIG },
  contextId: "",
  role: "connecting",
  core: null,
  status: null,
  sidebar: { count: 0, rows: [] },
  selectedChatId: null,
  window: { resource: null, count: 0, rows: [] },
  timings: {},
  results: [],
  errors: [],
}

let renderQueued = false
/** Paint in the next frame, or after 100 ms when frames do not run (a hidden tab). */
const render = () => {
  if (renderQueued) return
  renderQueued = true
  const run = () => {
    if (!renderQueued) return
    renderQueued = false
    cancelAnimationFrame(frame)
    clearTimeout(timer)
    try {
      paint()
    } catch (error) {
      showError(error)
    }
  }
  const frame = requestAnimationFrame(run)
  const timer = setTimeout(run, 100)
}

const describeError = (error: unknown) =>
  error instanceof Error ? `${error.name}: ${error.message}` : String(error)

const showError = (error: unknown) => {
  lab.errors.push(describeError(error))
  if (lab.errors.length > 50) lab.errors.splice(0, lab.errors.length - 50)
  const list = document.getElementById("errors")
  const section = document.getElementById("errors-section")
  if (list && section) {
    list.replaceChildren(
      ...lab.errors.map((text) => {
        const item = document.createElement("li")
        item.textContent = text
        return item
      }),
    )
    section.hidden = false
  }
  publish()
}

const publish = () => {
  ;(globalThis as { __demoLab?: unknown }).__demoLab = JSON.parse(JSON.stringify(lab)) as unknown
}

window.addEventListener("error", (event) => showError(event.error ?? event.message))
window.addEventListener("unhandledrejection", (event) => showError(event.reason))
setErrorHandler((error) => showError(error))

const since = () => Math.round(performance.now())

const note = (what: string, result: { ok: boolean; error?: string }) => {
  lab.results.unshift({
    at: new Date().toLocaleTimeString(),
    what,
    ok: result.ok,
    ...(result.error ? { error: result.error } : {}),
  })
  lab.results.length = Math.min(lab.results.length, 30)
  if (!result.ok && result.error) showError(new Error(`${what}: ${result.error}`))
  render()
}

/** Wrap a handler so a throw shows on the page. */
const safely =
  <A extends unknown[]>(handler: (...args: A) => unknown) =>
  (...args: A) => {
    try {
      const value = handler(...args)
      if (value instanceof Promise) value.catch(showError)
    } catch (error) {
      showError(error)
    }
  }

// ---------------------------------------------------------------------------
// Connection

const params = new URLSearchParams(location.search)
const config = parseDemoConfig(
  {
    scale: params.get("scale") ?? undefined,
    seed: params.get("seed") ?? undefined,
    storage: params.get("storage") ?? undefined,
  },
  { ...DEFAULT_DEMO_CONFIG, scale: "small" },
)
lab.config = { ...config }
element<HTMLSelectElement>("scale").value = config.scale
element<HTMLInputElement>("seed").value = String(config.seed)
element<HTMLSelectElement>("storage").value = config.storage

const account = connectDemoAccount(config)
const { core, client, demo, userId } = account
lab.contextId = core.contextId
lab.role = core.role
core.onRole((role) => {
  lab.role = role
  render()
})

const coreSub = client.subscribe({ kind: "core" })
const sidebarSub = client.subscribe({ kind: "sidebar", mode: "inbox" })
let windowSub: SubscriptionHandle | null = null
let windowOpenedAt = 0
let stopWindow: (() => void) | null = null

effect(() => {
  const resource = coreSub.resource.get()
  lab.core = resource?.kind === "core" ? resource : null
  if (lab.core?.phase === "ready" && lab.timings.coreReadyMs == null) {
    lab.timings.coreReadyMs = since()
    performance.mark("demo-lab:core-ready")
  }
  render()
})

effect(() => {
  const status = demo.status.get()
  lab.status = status ?? null
  render()
})

const titleOf = (chatId: string) => {
  const chat = client.store.row("chat", chatId).get() as ChatRow | undefined
  return chat?.title ?? `Chat ${chatId}`
}

const SIDEBAR_ROWS = 60

effect(() => {
  const keys = sidebarSub.list.get()
  lab.sidebar.count = keys.length
  lab.sidebar.rows = keys.slice(0, SIDEBAR_ROWS).flatMap((key) => {
    const row = client.store.rowByKey(key).get() as DialogRow | undefined
    if (!row) return []
    return [{ chatId: row.chatId, title: titleOf(row.chatId), unreadCount: row.unreadCount, pinned: row.pinned }]
  })
  if (keys.length > 0 && lab.timings.sidebarFirstRowsMs == null) {
    lab.timings.sidebarFirstRowsMs = since()
    performance.mark("demo-lab:sidebar-first-rows")
  }
  render()
})

const senderName = (fromId: string) => {
  if (fromId === userId) return "me"
  const user = client.store.row("user", fromId).get() as UserRow | undefined
  return user?.firstName ?? fromId
}

const WINDOW_ROWS = 120

const selectChat = (chatId: string) => {
  if (lab.selectedChatId === chatId && windowSub) return
  stopWindow?.()
  windowSub?.unsubscribe()
  lab.selectedChatId = chatId
  lab.timings.windowFirstRowsMs = undefined
  windowOpenedAt = performance.now()
  const handle = client.subscribe({ kind: "chatWindow", chatId: chatId as ChatID, anchor: "latest" })
  windowSub = handle
  stopWindow = effect(() => {
    const keys = handle.list.get()
    const resource = handle.resource.get()
    lab.window.resource = resource?.kind === "window" ? resource : null
    lab.window.count = keys.length
    lab.window.rows = keys.slice(-WINDOW_ROWS).flatMap((key: RowKey) => {
      const row = client.store.rowByKey(key).get() as MessageRow | undefined
      if (!row) return []
      return [
        {
          id: row.id,
          ...(row.messageId ? { messageId: row.messageId } : {}),
          fromId: row.fromId,
          text: row.text,
          state: row.state,
          edited: row.editDate != null,
          ...(row.reactions?.length
            ? { reactions: row.reactions.map((reaction) => `${reaction.emoji}${reaction.count}`).join(" ") }
            : {}),
        },
      ]
    })
    if (keys.length > 0 && lab.timings.windowFirstRowsMs == null) {
      lab.timings.windowFirstRowsMs = Math.round(performance.now() - windowOpenedAt)
      performance.mark("demo-lab:window-first-rows")
    }
    render()
  })
  render()
}

// ---------------------------------------------------------------------------
// Painting

const paint = () => {
  element("core").textContent = JSON.stringify(
    { role: lab.role, contextId: lab.contextId, ...(lab.core ?? { phase: "(no core resource yet)" }) },
    null,
    2,
  )
  element("world").textContent = lab.status
    ? JSON.stringify(lab.status, null, 2)
    : "Waiting for the demo worker. It starts once this tab (or another tab of this demo) leads."
  element("timings").textContent = JSON.stringify(lab.timings, null, 2)

  element("sidebar-count").textContent = `(${lab.sidebar.count} in the inbox${lab.sidebar.count > SIDEBAR_ROWS ? `, first ${SIDEBAR_ROWS} shown` : ""})`
  element("sidebar").replaceChildren(
    ...lab.sidebar.rows.map((row) => {
      const item = document.createElement("li")
      const button = document.createElement("button")
      button.type = "button"
      button.textContent = `${row.pinned ? "📌 " : ""}${row.title}${row.unreadCount > 0 ? `  (${row.unreadCount})` : ""}`
      if (row.unreadCount > 0) button.className = "unread"
      button.addEventListener("click", safely(() => selectChat(row.chatId)))
      item.append(button)
      if (row.chatId === lab.selectedChatId) item.setAttribute("aria-current", "true")
      return item
    }),
  )

  const chatId = lab.selectedChatId
  element("chat-title").textContent = chatId ? `${titleOf(chatId)} (#${chatId})` : "(pick one in the sidebar)"
  const resource = lab.window.resource
  element("window-state").textContent = resource
    ? `${lab.window.count} rows · loading ${resource.loading} · ${resource.hasOlder ? "has older" : "start of chat"} · ${resource.atLatest ? "at latest" : "not at latest"}`
    : ""
  const windowElement = element("window")
  const atBottom = windowElement.scrollTop + windowElement.clientHeight >= windowElement.scrollHeight - 4
  windowElement.textContent = lab.window.rows
    .map(
      (row) =>
        `#${row.messageId ?? "…"} ${senderName(row.fromId)}${row.state === "sent" ? "" : ` [${row.state}]`}${row.edited ? " (edited)" : ""}: ${row.text}${row.reactions ? `  ${row.reactions}` : ""}`,
    )
    .join("\n")
  if (atBottom) windowElement.scrollTop = windowElement.scrollHeight

  element("results").replaceChildren(
    ...lab.results.map((result) => {
      const item = document.createElement("li")
      item.textContent = `${result.at} ${result.ok ? "ok" : "failed"}: ${result.what}${result.error ? ` (${result.error})` : ""}`
      return item
    }),
  )
  publish()
}

// ---------------------------------------------------------------------------
// Actions

const command = async (what: string, input: DemoCommandInput) => {
  const result: DemoResult = await demo.send(input)
  note(what, result)
  return result
}

const requireChat = () => {
  const chatId = lab.selectedChatId
  if (!chatId) throw new Error("Pick a chat in the sidebar first")
  return chatId
}

const sendText = async (text: string) => {
  const chatId = requireChat() as ChatID
  if (text.trim().length === 0) return undefined
  const intent: Extract<Intent, { kind: "sendText" }> = {
    kind: "sendText",
    chatId,
    clientKey: newClientKey(),
    text,
    date: Math.floor(Date.now() / 1_000),
  }
  const optimistic = optimisticMessageRow(intent, userId, intent.date!)
  const result = await client.intent(intent, [
    { row: optimistic, ...(windowSub && lab.window.resource?.atLatest ? { appendTo: [windowSub.sub] } : {}) },
  ])
  note(`send "${text.slice(0, 30)}"`, { ok: result.status !== "rejected", ...(result.reason ? { error: result.reason } : {}) })
  return result
}

const markRead = async () => {
  const chatId = requireChat() as ChatID
  const last = lab.window.rows.findLast((row) => row.messageId != null)
  if (!last?.messageId) throw new Error("No message to read up to")
  const result = await client.intent({ kind: "markRead", chatId, maxId: last.messageId as MessageID })
  note("mark read", { ok: result.status !== "rejected", ...(result.reason ? { error: result.reason } : {}) })
  return result
}

const numberFrom = (id: string, fallback: number) => {
  const value = Number(element<HTMLInputElement>(id).value)
  return Number.isFinite(value) ? value : fallback
}

const on = (id: string, handler: () => unknown) => element(id).addEventListener("click", safely(handler))

element<HTMLFormElement>("config").addEventListener(
  "submit",
  safely((event: SubmitEvent) => {
    event.preventDefault()
    const next = new URLSearchParams({
      scale: element<HTMLSelectElement>("scale").value,
      seed: element<HTMLInputElement>("seed").value || "1",
      storage: element<HTMLSelectElement>("storage").value,
    })
    location.search = next.toString()
  }),
)

const whenSignedOut = () =>
  new Promise<void>((resolve) => {
    let stop: (() => void) | undefined
    const timer = setTimeout(() => {
      stop?.()
      resolve()
    }, 10_000)
    stop = effect(() => {
      const resource = coreSub.resource.get()
      if (resource?.kind === "core" && resource.phase === "signedOut") {
        clearTimeout(timer)
        queueMicrotask(() => stop?.())
        resolve()
      }
    })
  })

on("reset", async () => {
  // Erase the replica (sign out), forget the server's saved state, reload.
  core.post({ kind: "session", action: "signOut" })
  await whenSignedOut()
  await command("forget the server's state", { kind: "resetServer" })
  location.reload()
})

element<HTMLFormElement>("composer").addEventListener(
  "submit",
  safely(async (event: SubmitEvent) => {
    event.preventDefault()
    const input = element<HTMLInputElement>("text")
    const text = input.value
    input.value = ""
    await sendText(text)
  }),
)

on("older", () => {
  if (!windowSub) throw new Error("Pick a chat in the sidebar first")
  windowSub.ensure("older")
})
on("mark-read", markRead)
on("deliver", () => command("deliver here", { kind: "deliver", chatId: requireChat() }))
on("deliver-anywhere", () => command("deliver to a recent chat", { kind: "deliver" }))
on("stream-start", () => {
  const here = element<HTMLInputElement>("stream-here").checked
  return command("start stream", {
    kind: "stream",
    action: "start",
    ratePerSecond: numberFrom("stream-rate", 2),
    ...(here ? { chatId: requireChat() } : {}),
  })
})
on("stream-stop", () => command("stop stream", { kind: "stream", action: "stop" }))
on("agent-start", () =>
  command("start agent", {
    kind: "agent",
    action: "start",
    chatId: requireChat(),
    updatesPerSecond: numberFrom("agent-rate", 40),
    durationMs: numberFrom("agent-seconds", 10) * 1_000,
  }),
)
on("agent-stop", () => command("stop agent", { kind: "agent", action: "stop" }))
on("offline", () => command("go offline", { kind: "network", online: false }))
on("online", () => command("come back online", { kind: "network", online: true }))
on("faults", () =>
  command("set acknowledgement faults", {
    kind: "faults",
    latencyMs: numberFrom("latency", 0),
    lossRate: numberFrom("loss", 0) / 100,
  }),
)
on("other-read", () => command("other device reads", { kind: "otherUser", action: "read", chatId: requireChat() }))
on("other-react", () => command("other member reacts", { kind: "otherUser", action: "react", chatId: requireChat() }))
on("other-edit", () => command("other member edits", { kind: "otherUser", action: "edit", chatId: requireChat() }))
on("other-delete", () => command("other member deletes", { kind: "otherUser", action: "delete", chatId: requireChat() }))

;(globalThis as { __demoLabActions?: unknown }).__demoLabActions = {
  /** Open a chat window (`chatId` as a decimal string). */
  select: (chatId: string) => selectChat(chatId),
  /** Send a message to the selected chat; resolves with the intent's first result. */
  send: (text: string) => sendText(text),
  older: () => windowSub?.ensure("older"),
  markRead,
  /** Any demo control command (see demo-protocol.ts); resolves with its result. */
  command: (input: DemoCommandInput) => demo.send(input),
}

render()
