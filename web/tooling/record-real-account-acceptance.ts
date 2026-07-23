import { mkdir } from "node:fs/promises"
import { dirname, resolve } from "node:path"
import {
  ClientMessage,
  ConnectionError_Reason,
  Method,
  ServerProtocolMessage,
} from "@inline-chat/protocol/core"
import { CdpConnection } from "./browser/CdpConnection"

type JsonRecord = Record<string, unknown>

type TargetInfo = {
  targetId: string
  type: string
  url: string
}

type TargetSession = {
  sessionId: string
  targetId: string
  type: string
}

type FrameEvidence = {
  frames: number
  routes: Record<string, number>
  coveredFrames: number
  incompleteExposedChatFrames: number
  emptyMeasuredChatFrames: number
  maximumVisibleRows: number
}

type PageEvidence = {
  route: string
  visibility: string
  focused: boolean
  chatMounted: boolean
  chatPrepared: boolean
  messageCount: number
  visibleRows: number
  intersectingRows: number
  viewportScrollTop: number
  viewportScrollHeight: number
  viewportClientHeight: number
  physicalBottom: boolean
  logicalBottom: boolean
  firstLayoutState: string
  coverCount: number
  coverInsideChat: boolean
  alertVisible: boolean
  openingInline: boolean
  loadingChat: boolean
  routePlaceholder: boolean
  routePlaceholderCategory: string
  bodyElementCount: number
  authRecordCount: number
  authLogoutPending: boolean
  matchFailures: Array<{
    routeId: string
    status: string
    errorType: string
    errorName: string
  }>
}

type WorkerEvidence = {
  responsive: boolean
  heldLocks: number
  pendingLocks: number
  accountLocks: number
  pendingAccountLocks: number
}

type ExerciseEvidence = {
  switches: number
  maximumSwitchMs: number
  covered: boolean
  prepared: boolean
  messageCount: number
  visibleRows: number
  firstLayoutState: string
  atBottom: boolean
  completed: boolean
  coverCount: number
  offlineCycle: boolean
  error?: string
}

const isRecord = (value: unknown): value is JsonRecord =>
  typeof value === "object" && value != null

const stringValue = (record: JsonRecord | undefined, key: string) => {
  const value = record?.[key]
  return typeof value === "string" ? value : undefined
}

const numberValue = (record: JsonRecord | undefined, key: string) => {
  const value = record?.[key]
  return typeof value === "number" ? value : undefined
}

const option = (name: string, fallback: string) => {
  const prefix = `--${name}=`
  return process.argv.find((value) => value.startsWith(prefix))?.slice(
    prefix.length,
  ) ?? fallback
}

const debuggerOrigin = option("debugger", "http://127.0.0.1:9223")
const appOrigin = new URL(option("app", "http://localhost:8001")).origin
const durationSeconds = Number(option("duration", "180"))
const switchCount = Number(option("switches", "0"))
const offlineMs = Number(option("offline-ms", "0"))
const terminateOwner = option("terminate-owner", "false") === "true"
const foregroundPage = option("foreground", "false") === "true"
const reloadPage = option("reload", "false") === "true"
const retryRoute = option("retry", "false") === "true"
const debugExceptions = option("debug-exceptions", "false") === "true"
const outputPath = resolve(
  option("output", ".artifacts/acceptance/real-account-latest.json"),
)

if (!Number.isFinite(durationSeconds) || durationSeconds <= 0) {
  throw new TypeError("--duration must be a positive number of seconds")
}
if (!Number.isInteger(switchCount) || switchCount < 0) {
  throw new TypeError("--switches must be a non-negative integer")
}
if (!Number.isFinite(offlineMs) || offlineMs < 0) {
  throw new TypeError("--offline-ms must be a non-negative number")
}

const endpoint = (value: string) => {
  try {
    const url = new URL(value)
    if (!["http:", "https:", "ws:", "wss:"].includes(url.protocol)) {
      return "non-network-url"
    }
    return `${url.origin}${url.pathname}`
  } catch {
    return "invalid-url"
  }
}

const sameAppOrigin = (value: string) => {
  try {
    return new URL(value).origin === appOrigin
  } catch {
    return false
  }
}

const increment = (counts: Map<string, number>, key: string) => {
  counts.set(key, (counts.get(key) ?? 0) + 1)
}

const binaryFrame = (params: JsonRecord | undefined) => {
  const response = params?.response
  if (!isRecord(response) || response.opcode !== 2) return undefined
  const payload = stringValue(response, "payloadData")
  return payload
    ? new Uint8Array(Buffer.from(payload, "base64"))
    : undefined
}

const errorCategory = (value: string) => {
  const normalized = value.toLowerCase()
  if (normalized.includes("failed to send transaction")) {
    return "failed-to-send-transaction"
  }
  if (normalized.includes("websocket connection error")) {
    return "websocket-connection-error"
  }
  if (normalized.includes("failed to fetch")) return "failed-to-fetch"
  if (normalized.includes("inline couldn’t continue")) return "core-terminal"
  if (normalized.includes("flushsync")) return "react-flush-sync"
  if (normalized.includes("serialize a bigint")) {
    return "react-bigint-serialization"
  }
  if (normalized.includes("should not already be working")) {
    return "react-reentrant-work"
  }
  if (normalized.includes("maximum update depth")) return "react-update-loop"
  if (normalized.includes("cannot update a component")) {
    return "react-render-update"
  }
  if (normalized.includes("aborterror") || normalized.includes("aborted")) {
    return "aborted-operation"
  }
  if (normalized.includes("inline core")) return "inline-core"
  return "other"
}

const sanitizedDiagnostic = (value: string) =>
  value
    .trim()
    .split(/\r?\n/, 1)[0]!
    .replace(/https?:\/\/\S+/g, "<url>")
    .replace(/\b\d{4,}\b/g, "<number>")
    .slice(0, 240)

const remoteObjectText = (value: unknown) => {
  if (!isRecord(value)) return undefined
  return stringValue(value, "value") ?? stringValue(value, "description")
}

const captureRemoteObjectMessage = (
  value: unknown,
  sessionId: string | undefined,
) => {
  if (!sessionId || !isRecord(value) || diagnostics.length >= 5) return
  const objectId = stringValue(value, "objectId")
  if (!objectId) return
  void connection.call(
    "Runtime.getProperties",
    { objectId, ownProperties: true },
    sessionId,
  ).then((properties) => {
    const raw = properties.result
    if (!Array.isArray(raw)) return
    const messageProperty = raw.find(
      (property) =>
        isRecord(property) && property.name === "message",
    )
    const diagnostic = isRecord(messageProperty)
      ? sanitizedDiagnostic(
          remoteObjectText(messageProperty.value) ?? "",
        )
      : ""
    if (diagnostic && diagnostics.length < 5) diagnostics.push(diagnostic)
  }).catch(() => undefined)
}

const networkFailureCategory = (params: JsonRecord | undefined) => {
  const cors = params?.corsErrorStatus
  if (isRecord(cors)) {
    return `cors:${stringValue(cors, "corsError") ?? "blocked"}`
  }
  const blocked = stringValue(params, "blockedReason")
  if (blocked) return `blocked:${blocked}`
  const error = stringValue(params, "errorText") ?? "unknown"
  if (error.includes("ERR_ABORTED")) return "aborted"
  if (error.includes("ERR_FAILED")) return "failed"
  if (error.includes("ERR_INTERNET_DISCONNECTED")) return "offline"
  if (error.includes("ERR_CONNECTION")) return "connection"
  return "other"
}

const frameRecorderRunId = `acceptance-${Date.now()}-${crypto.randomUUID()}`

const frameRecorderSource = String.raw`(() => {
  const key = "__inlineAlpha1FrameEvidence"
  const runId = ${JSON.stringify(frameRecorderRunId)}
  const current = globalThis[key]
  if (current?.runId === runId) return true
  current?.stop?.()
  const evidence = {
    frames: 0,
    routes: {},
    coveredFrames: 0,
    incompleteExposedChatFrames: 0,
    emptyMeasuredChatFrames: 0,
    maximumVisibleRows: 0,
    runtimeFailures: [],
    matchFailures: [],
  }
  const runtimeFailureText = (value, fallback) => {
    if (value && typeof value === "object") {
      if (typeof value.stack === "string") return value.stack
      if (typeof value.message === "string") return value.message
    }
    return typeof fallback === "string" ? fallback : String(value || "")
  }
  const recordRuntimeFailure = (value, fallback) => {
    if (evidence.runtimeFailures.length >= 5) return
    const text = runtimeFailureText(value, fallback)
    if (text) evidence.runtimeFailures.push(text)
  }
  const handleError = (event) => recordRuntimeFailure(event.error, event.message)
  const handleRejection = (event) => recordRuntimeFailure(event.reason)
  addEventListener("error", handleError)
  addEventListener("unhandledrejection", handleRejection)
  const observedMatchStores = new Map()
  const recordInvalidMatch = (match) => {
    if (!match || typeof match !== "object") return
    const pending = match._nonReactive || {}
    const issue = match._displayPending && !pending.displayPendingPromise
      ? "display-pending-without-promise"
      : match._forcePending && !pending.minPendingPromise
        ? "forced-pending-without-promise"
        : match.status === "pending" && !pending.loadPromise
          ? "pending-without-load-promise"
          : match.status === "redirected" && !pending.loadPromise
            ? "redirected-without-load-promise"
            : match.status === "error" && match.error == null
              ? "error-without-value"
              : match.status === "error"
                ? "error"
                : undefined
    if (!issue) return
    const failure = {
      routeId: typeof match.routeId === "string" ? match.routeId : "unknown",
      issue,
      errorType: typeof match.error,
      errorName:
        match.error && typeof match.error === "object" &&
        typeof match.error.name === "string"
          ? match.error.name
          : "none",
    }
    const key = JSON.stringify(failure)
    if (!evidence.matchFailures.some((entry) => JSON.stringify(entry) === key)) {
      evidence.matchFailures.push(failure)
    }
  }
  const observeStore = (store) => {
    if (!store || observedMatchStores.has(store)) return
    const unsubscribe = store.subscribe?.(() => recordInvalidMatch(store.get?.()))
    observedMatchStores.set(store, typeof unsubscribe === "function" ? unsubscribe : () => {})
    recordInvalidMatch(store.get?.())
  }
  const inspectMatches = () => {
    const router = globalThis.__inlineRouter
    const activeMatches = router?.stores?.matches?.get?.()
    const pooledMatches = router?.stores?.matchStores instanceof Map
      ? [...router.stores.matchStores.values()].map((store) => store.get?.())
      : []
    const matches = [
      ...(Array.isArray(activeMatches) ? activeMatches : []),
      ...pooledMatches,
    ]
    for (const storeMap of [
      router?.stores?.matchStores,
      router?.stores?.pendingMatchStores,
      router?.stores?.cachedMatchStores,
    ]) {
      if (!(storeMap instanceof Map)) continue
      for (const store of storeMap.values()) observeStore(store)
    }
    for (const match of matches) {
      recordInvalidMatch(match)
    }
  }
  const stopMatchObservation =
    globalThis.__inlineRouter?.stores?.matches?.subscribe?.(inspectMatches)
  inspectMatches()
  let active = true
  const route = () => {
    const path = location.pathname
    if (path.startsWith("/chat/")) {
      const parts = path.split("/")
      return "/chat/" + (parts[2] || "peer") + "/:peer"
    }
    return path
  }
  const sample = () => {
    if (!active) return
    inspectMatches()
    evidence.frames += 1
    const currentRoute = route()
    evidence.routes[currentRoute] = (evidence.routes[currentRoute] || 0) + 1
    const cover = document.querySelector("[data-inline-route-presentation]")
    if (cover) evidence.coveredFrames += 1
    const chat = document.querySelector("[data-inline-chat-prepared]")
    if (currentRoute.startsWith("/chat/") && !cover) {
      const viewport = document.querySelector('[data-inline-message-list="viewport"]')
      const compose = document.querySelector("[data-inline-compose-editor]")
      const messageCount = Number(chat?.getAttribute("data-inline-chat-message-count") || 0)
      const visibleRows = viewport?.querySelectorAll("[data-message-id]").length || 0
      evidence.maximumVisibleRows = Math.max(evidence.maximumVisibleRows, visibleRows)
      if (
        !chat ||
        !viewport ||
        !compose ||
        viewport.dataset.inlineFirstLayout !== "reported"
      ) {
        evidence.incompleteExposedChatFrames += 1
      }
      if (messageCount > 0 && visibleRows === 0) {
        evidence.emptyMeasuredChatFrames += 1
      }
    }
    requestAnimationFrame(sample)
  }
  globalThis[key] = {
    runId,
    read: () => ({
      ...evidence,
      routes: { ...evidence.routes },
      runtimeFailures: [...evidence.runtimeFailures],
      matchFailures: [...evidence.matchFailures],
    }),
    stop: () => {
      active = false
      removeEventListener("error", handleError)
      removeEventListener("unhandledrejection", handleRejection)
      stopMatchObservation?.()
      for (const unsubscribe of observedMatchStores.values()) unsubscribe()
    },
  }
  requestAnimationFrame(sample)
  return true
})()`

const frameEvidenceSource = String.raw`(() => {
  const recorder = globalThis.__inlineAlpha1FrameEvidence
  return recorder?.runId === ${JSON.stringify(frameRecorderRunId)}
    ? recorder.read()
    : null
})()`

const stopFrameRecorderSource = String.raw`(() => {
  const key = "__inlineAlpha1FrameEvidence"
  const recorder = globalThis[key]
  if (recorder?.runId !== ${JSON.stringify(frameRecorderRunId)}) return false
  recorder.stop()
  delete globalThis[key]
  return true
})()`

const pageEvidenceSource = String.raw`(() => {
  const chat = document.querySelector("[data-inline-chat-prepared]")
  const viewport = document.querySelector('[data-inline-message-list="viewport"]')
  const path = location.pathname
  const route = path.startsWith("/chat/")
    ? "/chat/" + (path.split("/")[2] || "peer") + "/:peer"
    : path
  const placeholder = document.querySelector("[data-inline-route-placeholder]")
  const placeholderText = placeholder?.querySelector("h1")?.textContent?.toLowerCase() || ""
  const routePlaceholderCategory = placeholderText.includes("handshake")
    ? "core-handshake"
    : placeholderText.includes("owner")
      ? "core-owner"
      : placeholderText.includes("cache")
        ? "core-cache"
        : placeholderText.includes("open this chat")
          ? "chat-open"
          : placeholderText ? "other" : "none"
  const matches = globalThis.__inlineRouter?.state?.matches
  const viewportRect = viewport?.getBoundingClientRect()
  const messageRows = viewport
    ? [...viewport.querySelectorAll("[data-message-id]")]
    : []
  const intersectingRows = viewportRect
    ? messageRows.filter((row) => {
        const rect = row.getBoundingClientRect()
        return rect.height > 0 &&
          rect.bottom > viewportRect.top &&
          rect.top < viewportRect.bottom
      }).length
    : 0
  const physicalBottom = viewport
    ? viewport.scrollHeight - viewport.scrollTop - viewport.clientHeight <= 1
    : false
  const matchFailures = Array.isArray(matches)
    ? matches.flatMap((match) => {
        if (!match || match.status !== "error") return []
        const error = match.error
        return [{
          routeId: typeof match.routeId === "string" ? match.routeId : "unknown",
          status: match.status,
          errorType: typeof error,
          errorName:
            error && typeof error === "object" && typeof error.name === "string"
              ? error.name
              : "none",
        }]
      })
    : []
  return {
    route,
    visibility: document.visibilityState,
    focused: document.hasFocus(),
    chatMounted: Boolean(chat),
    chatPrepared: chat?.getAttribute("data-inline-chat-prepared") === "true",
    messageCount: Number(chat?.getAttribute("data-inline-chat-message-count") || 0),
    visibleRows: messageRows.length,
    intersectingRows,
    viewportScrollTop: viewport?.scrollTop || 0,
    viewportScrollHeight: viewport?.scrollHeight || 0,
    viewportClientHeight: viewport?.clientHeight || 0,
    physicalBottom,
    logicalBottom: viewport?.dataset.inlineLogicalBottom === "true",
    firstLayoutState: viewport?.dataset.inlineFirstLayout || "missing",
    coverCount: document.querySelectorAll("[data-inline-route-presentation]").length,
    coverInsideChat: Boolean(chat?.querySelector("[data-inline-route-presentation]")),
    alertVisible: Boolean(document.querySelector('[role="alert"]')),
    openingInline: Boolean(document.querySelector('[aria-label="Opening Inline"]')),
    loadingChat: Boolean(document.querySelector('[aria-label="Loading chat"]')),
    routePlaceholder: Boolean(placeholder),
    routePlaceholderCategory,
    bodyElementCount: document.body.querySelectorAll("*").length,
    matchFailures,
  }
})()`

const authPersistenceEvidenceSource = String.raw`(async () => {
  const logoutPending = (() => {
    try {
      return localStorage.getItem("inline-web-session:logout-pending") === "1"
    } catch {
      return false
    }
  })()
  try {
    const databases = typeof indexedDB.databases === "function"
      ? await indexedDB.databases()
      : []
    if (databases.length > 0 && !databases.some(
      (database) => database.name === "inline-auth-session",
    )) {
      return { recordCount: 0, logoutPending }
    }
    const database = await new Promise((resolve, reject) => {
      const request = indexedDB.open("inline-auth-session", 1)
      request.onsuccess = () => resolve(request.result)
      request.onerror = () => reject(request.error)
      request.onblocked = () => reject(new Error("auth database blocked"))
    })
    if (!database.objectStoreNames.contains("sessions")) {
      database.close()
      return { recordCount: 0, logoutPending }
    }
    const recordCount = await new Promise((resolve, reject) => {
      const transaction = database.transaction("sessions", "readonly")
      const request = transaction.objectStore("sessions").count()
      request.onsuccess = () => resolve(request.result)
      request.onerror = () => reject(request.error)
      transaction.onabort = () => reject(transaction.error)
    })
    database.close()
    return { recordCount, logoutPending }
  } catch {
    return { recordCount: -1, logoutPending }
  }
})()`

const workerEvidenceSource = String.raw`(async () => {
  let heldLocks = 0
  let pendingLocks = 0
  let accountLocks = 0
  let pendingAccountLocks = 0
  try {
    const state = await navigator.locks.query()
    heldLocks = state.held.length
    pendingLocks = state.pending.length
    accountLocks = state.held.filter((lock) =>
      typeof lock.name === "string" &&
      lock.name.startsWith("inline-core-account-")
    ).length
    pendingAccountLocks = state.pending.filter((lock) =>
      typeof lock.name === "string" &&
      lock.name.startsWith("inline-core-account-")
    ).length
  } catch {}
  const responsive = await new Promise((resolve) => setTimeout(() => resolve(true), 0))
  return {
    responsive,
    heldLocks,
    pendingLocks,
    accountLocks,
    pendingAccountLocks,
  }
})()`

const switchExerciseSource = (count: number) => String.raw`(async (count) => {
  const waitFor = (test, timeout = 20000) => new Promise((resolve) => {
    const started = performance.now()
    const poll = () => {
      if (test()) return resolve(true)
      if (performance.now() - started > timeout) {
        return resolve(false)
      }
      requestAnimationFrame(poll)
    }
    poll()
  })
  await waitFor(() => document.querySelectorAll('a[href^="/chat/"]').length >= 2)
  const hrefs = [...new Set(
    [...document.querySelectorAll('a[href^="/chat/"]')]
      .filter((element) => element.getClientRects().length > 0)
      .map((element) => element.getAttribute("href"))
      .filter(Boolean),
  )]
  if (hrefs.length < 2) throw new Error("two visible chat links are required")
  const durations = []
  let completed = true
  for (let index = 0; index < count; index += 1) {
    const started = performance.now()
    const href = hrefs[index % 2]
    const targetPath = new URL(href, location.href).pathname
    document.querySelector('a[href="' + href + '"]').click()
    const ready = await waitFor(() => {
      const chat = document.querySelector("[data-inline-chat-prepared]")
      const viewport = document.querySelector('[data-inline-message-list="viewport"]')
      return location.pathname === targetPath &&
        Boolean(chat) &&
        !document.querySelector("[data-inline-route-presentation]") &&
        viewport?.dataset.inlineFirstLayout === "reported"
    })
    if (!ready) {
      completed = false
      break
    }
    durations.push(performance.now() - started)
  }
  const chat = document.querySelector("[data-inline-chat-prepared]")
  const viewport = document.querySelector('[data-inline-message-list="viewport"]')
  return {
    switches: durations.length,
    maximumSwitchMs: Math.round(Math.max(0, ...durations)),
    covered: Boolean(document.querySelector("[data-inline-route-presentation]")),
    prepared: chat?.getAttribute("data-inline-chat-prepared") === "true",
    messageCount: Number(chat?.getAttribute("data-inline-chat-message-count") || 0),
    visibleRows: viewport?.querySelectorAll("[data-message-id]").length || 0,
    firstLayoutState: viewport?.dataset.inlineFirstLayout || "missing",
    atBottom: chat?.getAttribute("data-inline-chat-at-bottom") === "true",
    completed,
    coverCount: document.querySelectorAll("[data-inline-route-presentation]").length,
  }
})(${count})`

const connection = await CdpConnection.open(debuggerOrigin)
const sessions = new Map<string, TargetSession>()
const attachedTargets = new Set<string>()
const requestEndpoints = new Map<string, string>()
const requests = new Map<string, number>()
const failedRequests = new Map<string, number>()
const requestStatuses = new Map<string, number>()
const requestFailureReasons = new Map<string, number>()
const sockets = new Map<string, number>()
const socketEndpoints = new Map<string, string>()
const socketFramesReceived = new Map<string, number>()
const socketFramesSent = new Map<string, number>()
const receivedEnvelopeTypes = new Map<string, number>()
const sentEnvelopeTypes = new Map<string, number>()
const targetCounts = new Map<string, number>()
const errorCategories = new Map<string, number>()
let socketCloses = 0
let socketErrors = 0
let exceptions = 0
let consoleErrors = 0
let consoleWarnings = 0
let logErrors = 0
let logWarnings = 0
const diagnostics: string[] = []

const relevantTarget = (target: TargetInfo) =>
  ["page", "shared_worker", "worker"].includes(target.type) &&
  sameAppOrigin(target.url)

const targets = async () => {
  const result = await connection.call("Target.getTargets")
  const rawTargets = result.targetInfos
  if (!Array.isArray(rawTargets)) return []
  return rawTargets.flatMap((value): TargetInfo[] => {
    if (!isRecord(value)) return []
    const targetId = stringValue(value, "targetId")
    const type = stringValue(value, "type")
    const url = stringValue(value, "url")
    return targetId && type && url ? [{ targetId, type, url }] : []
  })
}

const attach = async (target: TargetInfo) => {
  if (attachedTargets.has(target.targetId) || !relevantTarget(target)) return
  attachedTargets.add(target.targetId)
  const result = await connection.call("Target.attachToTarget", {
    targetId: target.targetId,
    flatten: true,
  })
  const sessionId = stringValue(result, "sessionId")
  if (!sessionId) throw new Error("Chrome did not create a target session")
  sessions.set(sessionId, {
    sessionId,
    targetId: target.targetId,
    type: target.type,
  })
  increment(targetCounts, target.type)
  await Promise.allSettled([
    connection.call("Network.enable", {}, sessionId),
    connection.call("Runtime.enable", {}, sessionId),
    connection.call("Log.enable", {}, sessionId),
    ...(target.type === "page"
      ? [
          connection.call("Page.enable", {}, sessionId),
          connection.call(
            "Runtime.evaluate",
            { expression: frameRecorderSource },
            sessionId,
          ),
        ]
      : []),
  ])
  if (target.type === "page" && debugExceptions) {
    await connection.call("Debugger.enable", {}, sessionId)
    await connection.call(
      "Debugger.setPauseOnExceptions",
      { state: "all" },
      sessionId,
    )
  }
}

const refreshTargets = async () => {
  for (const target of await targets()) await attach(target)
  for (const session of sessions.values()) {
    if (session.type !== "page") continue
    await connection
      .call(
        "Runtime.evaluate",
        { expression: frameRecorderSource },
        session.sessionId,
      )
      .catch(() => undefined)
  }
}

connection.onMessage((message) => {
  const params = message.params
  if (!message.sessionId || !sessions.has(message.sessionId)) return
  switch (message.method) {
    case "Network.requestWillBeSent": {
      const requestId = stringValue(params, "requestId")
      const request = params?.request
      if (!requestId || !isRecord(request)) return
      const url = stringValue(request, "url")
      const method = stringValue(request, "method") ?? "GET"
      if (!url || sameAppOrigin(url)) return
      const safeEndpoint = endpoint(url)
      requestEndpoints.set(requestId, `${method} ${safeEndpoint}`)
      increment(requests, `${method} ${safeEndpoint}`)
      return
    }
    case "Network.loadingFinished": {
      const requestId = stringValue(params, "requestId")
      if (requestId) requestEndpoints.delete(requestId)
      return
    }
    case "Network.responseReceived": {
      const requestId = stringValue(params, "requestId")
      const safeEndpoint = requestId
        ? requestEndpoints.get(requestId)
        : undefined
      const response = params?.response
      const status = isRecord(response)
        ? numberValue(response, "status")
        : undefined
      if (safeEndpoint && status != null) {
        increment(requestStatuses, `${safeEndpoint} ${status}`)
      }
      return
    }
    case "Network.loadingFailed": {
      const requestId = stringValue(params, "requestId")
      if (!requestId) return
      const safeEndpoint = requestEndpoints.get(requestId)
      if (safeEndpoint) {
        increment(failedRequests, safeEndpoint)
        increment(
          requestFailureReasons,
          `${safeEndpoint} ${networkFailureCategory(params)}`,
        )
      }
      requestEndpoints.delete(requestId)
      return
    }
    case "Network.webSocketCreated": {
      const requestId = stringValue(params, "requestId")
      const url = stringValue(params, "url")
      if (url) {
        const safeEndpoint = endpoint(url)
        increment(sockets, safeEndpoint)
        if (requestId) socketEndpoints.set(requestId, safeEndpoint)
      }
      return
    }
    case "Network.webSocketFrameReceived": {
      const requestId = stringValue(params, "requestId")
      const safeEndpoint = requestId
        ? socketEndpoints.get(requestId)
        : undefined
      increment(
        socketFramesReceived,
        safeEndpoint ?? "existing-websocket",
      )
      const bytes = binaryFrame(params)
      if (bytes) {
        try {
          const message = ServerProtocolMessage.fromBinary(bytes)
          const body = message.body
          const kind = body.oneofKind ?? "empty"
          let detail: string | undefined
          if (body.oneofKind === "rpcResult") {
            detail = body.rpcResult.result.oneofKind ?? "empty"
          } else if (body.oneofKind === "message") {
            detail = body.message.payload.oneofKind ?? "empty"
          } else if (body.oneofKind === "connectionError") {
            detail =
              ConnectionError_Reason[
                body.connectionError.reason
              ] ?? `reason-${body.connectionError.reason}`
          }
          increment(
            receivedEnvelopeTypes,
            detail ? `${kind}:${detail}` : kind,
          )
        } catch {
          increment(receivedEnvelopeTypes, "invalid-binary")
        }
      }
      return
    }
    case "Network.webSocketFrameSent": {
      const requestId = stringValue(params, "requestId")
      const safeEndpoint = requestId
        ? socketEndpoints.get(requestId)
        : undefined
      increment(socketFramesSent, safeEndpoint ?? "existing-websocket")
      const bytes = binaryFrame(params)
      if (bytes) {
        try {
          const message = ClientMessage.fromBinary(bytes)
          const body = message.body
          const kind = body.oneofKind ?? "empty"
          const detail = body.oneofKind === "rpcCall"
            ? Method[body.rpcCall.method] ?? `method-${body.rpcCall.method}`
            : undefined
          increment(
            sentEnvelopeTypes,
            detail ? `${kind}:${detail}` : kind,
          )
        } catch {
          increment(sentEnvelopeTypes, "invalid-binary")
        }
      }
      return
    }
    case "Network.webSocketClosed":
      socketCloses += 1
      return
    case "Network.webSocketFrameError":
      socketErrors += 1
      return
    case "Runtime.exceptionThrown":
      exceptions += 1
      {
        const details = params?.exceptionDetails
        const exception = isRecord(details) ? details.exception : undefined
        const description = remoteObjectText(exception)
        const text = isRecord(details)
          ? stringValue(details, "text")
          : undefined
        increment(
          errorCategories,
          errorCategory(description ?? text ?? ""),
        )
        const diagnostic = sanitizedDiagnostic(description ?? text ?? "")
        if (diagnostic && diagnostics.length < 5) {
          diagnostics.push(diagnostic)
        }
        const stackTrace = isRecord(details) ? details.stackTrace : undefined
        const callFrames = isRecord(stackTrace) ? stackTrace.callFrames : undefined
        if (Array.isArray(callFrames) && diagnostics.length < 8) {
          for (const frame of callFrames.slice(0, 3)) {
            if (!isRecord(frame) || diagnostics.length >= 8) continue
            const functionName = stringValue(frame, "functionName") || "anonymous"
            const url = stringValue(frame, "url")
            const lineNumber = numberValue(frame, "lineNumber")
            const columnNumber = numberValue(frame, "columnNumber")
            const location = url
              ? `${endpoint(url)}:${(lineNumber ?? 0) + 1}:${(columnNumber ?? 0) + 1}`
              : "unknown"
            diagnostics.push(
              sanitizedDiagnostic(`${functionName} at ${location}`),
            )
          }
        }
        captureRemoteObjectMessage(exception, message.sessionId)
      }
      return
    case "Debugger.paused": {
      const thrown = params?.data
      const captureFrames =
        isRecord(thrown) && stringValue(thrown, "type") === "undefined"
      const callFrames = Array.isArray(params?.callFrames)
        ? params.callFrames
        : []
      for (const frame of captureFrames ? callFrames.slice(0, 8) : []) {
        if (!isRecord(frame) || diagnostics.length >= 12) continue
        const functionName = stringValue(frame, "functionName") || "anonymous"
        const location = frame.location
        const url = stringValue(frame, "url")
        const lineNumber = isRecord(location)
          ? numberValue(location, "lineNumber")
          : undefined
        const columnNumber = isRecord(location)
          ? numberValue(location, "columnNumber")
          : undefined
        diagnostics.push(
          sanitizedDiagnostic(
            `${functionName} at ${url ? endpoint(url) : "unknown"}:` +
              `${(lineNumber ?? 0) + 1}:${(columnNumber ?? 0) + 1}`,
          ),
        )
      }
      if (captureFrames) {
        captureRemoteObjectMessage(thrown, message.sessionId)
      }
      void connection
        .call("Debugger.resume", {}, message.sessionId)
        .catch(() => undefined)
      return
    }
    case "Runtime.consoleAPICalled": {
      const type = stringValue(params, "type")
      if (type === "error" || type === "assert") {
        consoleErrors += 1
        const args = Array.isArray(params?.args) ? params.args : []
        const categoryText = args.flatMap((argument): string[] =>
          isRecord(argument) && typeof argument.value === "string"
            ? [argument.value]
            : []
        ).join(" ")
        increment(errorCategories, errorCategory(categoryText))
      }
      if (type === "warning") consoleWarnings += 1
      if (
        (type === "error" || type === "assert" || type === "warning") &&
        diagnostics.length < 5
      ) {
        const args = Array.isArray(params?.args) ? params.args : []
        for (const argument of args) {
          const value = remoteObjectText(argument)
          const diagnostic = value && !/^%[a-z]/i.test(value)
            ? sanitizedDiagnostic(value)
            : ""
          if (diagnostic && diagnostics.length < 5) {
            diagnostics.push(diagnostic)
          }
          captureRemoteObjectMessage(argument, message.sessionId)
        }
      }
      return
    }
    case "Log.entryAdded": {
      const entry = params?.entry
      if (!isRecord(entry)) return
      const level = stringValue(entry, "level")
      if (level === "error") {
        logErrors += 1
        increment(
          errorCategories,
          errorCategory(stringValue(entry, "text") ?? ""),
        )
      }
      if (level === "warning") logWarnings += 1
      return
    }
  }
})

await connection.call("Target.setDiscoverTargets", { discover: true })
await refreshTargets()
if (foregroundPage) {
  for (const session of sessions.values()) {
    if (session.type !== "page") continue
    await Promise.allSettled([
      connection.call("Page.bringToFront", {}, session.sessionId),
      connection.call(
        "Emulation.setFocusEmulationEnabled",
        { enabled: true },
        session.sessionId,
      ),
    ])
  }
}
if (reloadPage) {
  for (const session of sessions.values()) {
    if (session.type !== "page") continue
    await connection.call(
      "Runtime.evaluate",
      { expression: "location.reload(); true" },
      session.sessionId,
    )
  }
  await Bun.sleep(1_000)
  await refreshTargets()
}
// Runtime.enable replays the page's retained console buffer. Acceptance counts
// only errors produced after attachment, not historical failures from an
// earlier development session.
await Bun.sleep(100)
exceptions = 0
consoleErrors = 0
consoleWarnings = 0
logErrors = 0
logWarnings = 0
errorCategories.clear()
diagnostics.length = 0
if (retryRoute) {
  for (const session of sessions.values()) {
    if (session.type !== "page") continue
    await connection.call(
      "Runtime.evaluate",
      {
        expression:
          'document.querySelector("main button")?.click(); true',
      },
      session.sessionId,
    )
  }
}
let terminatedOwner = false
if (terminateOwner) {
  let owner: TargetSession | undefined
  const ownerDeadline = Date.now() + 10_000
  while (!owner && Date.now() < ownerDeadline) {
    await refreshTargets()
    const candidates = [...sessions.values()].filter(
      (session) => session.type === "shared_worker",
    )
    const observations = await Promise.all(
      candidates.map(async (session) => {
        const result = await Promise.race([
          connection.call(
            "Runtime.evaluate",
            {
              expression: workerEvidenceSource,
              awaitPromise: true,
              returnByValue: true,
            },
            session.sessionId,
          ).catch(() => undefined),
          Bun.sleep(500).then(() => undefined),
        ])
        return { session, runtime: result?.result }
      }),
    )
    owner = observations.find(({ runtime }) =>
      isRecord(runtime) &&
      isRecord(runtime.value) &&
      (numberValue(runtime.value, "accountLocks") ?? 0) > 0
    )?.session
    if (!owner) await Bun.sleep(250)
  }
  if (!owner) {
    throw new Error(
      "No lock-holding Inline SharedWorker owner is attached",
    )
  }
  const result = await connection.call("Target.closeTarget", {
    targetId: owner.targetId,
  })
  terminatedOwner = result.success === true
}
const exercisePromise = (async (): Promise<ExerciseEvidence | undefined> => {
  if (switchCount === 0 && offlineMs === 0) return undefined
  await Bun.sleep(500)
  const pageSession = [...sessions.values()].find(
    (session) => session.type === "page",
  )
  if (!pageSession) throw new Error("No Inline page target is attached")
  let switchEvidence: Omit<ExerciseEvidence, "offlineCycle"> = {
    switches: 0,
    maximumSwitchMs: 0,
    covered: false,
    prepared: false,
    messageCount: 0,
    visibleRows: 0,
    firstLayoutState: "missing",
    atBottom: false,
    completed: switchCount === 0,
    coverCount: 0,
  }
  if (switchCount > 0) {
    const result = await connection.call(
      "Runtime.evaluate",
      {
        expression: switchExerciseSource(switchCount),
        awaitPromise: true,
        returnByValue: true,
      },
      pageSession.sessionId,
    )
    if (isRecord(result.exceptionDetails)) {
      throw new Error("Chat-switch exercise failed in the page")
    }
    const runtime = result.result
    if (!isRecord(runtime) || !isRecord(runtime.value)) {
      throw new Error("Chat-switch exercise did not return evidence")
    }
    const value = runtime.value
    switchEvidence = {
      switches: numberValue(value, "switches") ?? 0,
      maximumSwitchMs: numberValue(value, "maximumSwitchMs") ?? 0,
      covered: value.covered === true,
      prepared: value.prepared === true,
      messageCount: numberValue(value, "messageCount") ?? 0,
      visibleRows: numberValue(value, "visibleRows") ?? 0,
      firstLayoutState:
        stringValue(value, "firstLayoutState") ?? "missing",
      atBottom: value.atBottom === true,
      completed: value.completed === true,
      coverCount: numberValue(value, "coverCount") ?? 0,
    }
  }
  if (offlineMs > 0) {
    await connection.call(
      "Network.emulateNetworkConditions",
      {
        offline: true,
        latency: 0,
        downloadThroughput: -1,
        uploadThroughput: -1,
      },
      pageSession.sessionId,
    )
    await Bun.sleep(offlineMs)
    await connection.call(
      "Network.emulateNetworkConditions",
      {
        offline: false,
        latency: 0,
        downloadThroughput: -1,
        uploadThroughput: -1,
      },
      pageSession.sessionId,
    )
  }
  return { ...switchEvidence, offlineCycle: offlineMs > 0 }
})().catch((error: unknown): ExerciseEvidence => ({
  switches: 0,
  maximumSwitchMs: 0,
  covered: false,
  prepared: false,
  messageCount: 0,
  visibleRows: 0,
  firstLayoutState: "missing",
  atBottom: false,
  completed: false,
  coverCount: 0,
  offlineCycle: false,
  error: error instanceof Error ? error.message : "Unknown acceptance error",
}))
let refreshing = false
const refreshTimer = setInterval(() => {
  if (refreshing) return
  refreshing = true
  void refreshTargets().finally(() => {
    refreshing = false
  })
}, 1_000)

const startedAt = new Date()
console.log(
  `Recording sanitized Inline Web acceptance for ${durationSeconds}s; no headers, credentials, raw payloads, message text, query strings, or WebSocket frames are persisted.`,
)

let finishEarly!: () => void
const interrupted = new Promise<void>((resolveInterrupt) => {
  finishEarly = resolveInterrupt
})
const interrupt = () => finishEarly()
process.once("SIGINT", interrupt)
process.once("SIGTERM", interrupt)
await Promise.race([Bun.sleep(durationSeconds * 1_000), interrupted])
const exercise = await exercisePromise

clearInterval(refreshTimer)
process.off("SIGINT", interrupt)
process.off("SIGTERM", interrupt)

const frameEvidence: FrameEvidence[] = []
const pageEvidence: PageEvidence[] = []
for (const session of sessions.values()) {
  if (session.type !== "page") continue
  const [pageResult, authPersistenceResult] = await Promise.all([
    connection
      .call(
        "Runtime.evaluate",
        { expression: pageEvidenceSource, returnByValue: true },
        session.sessionId,
      )
      .catch(() => undefined),
    connection
      .call(
        "Runtime.evaluate",
        {
          expression: authPersistenceEvidenceSource,
          awaitPromise: true,
          returnByValue: true,
        },
        session.sessionId,
      )
      .catch(() => undefined),
  ])
  const pageRuntime = pageResult?.result
  const pageValue = isRecord(pageRuntime) && isRecord(pageRuntime.value)
    ? pageRuntime.value
    : undefined
  const authPersistenceRuntime = authPersistenceResult?.result
  const authPersistenceValue =
    isRecord(authPersistenceRuntime) &&
    isRecord(authPersistenceRuntime.value)
      ? authPersistenceRuntime.value
      : undefined
  if (pageValue) {
    pageEvidence.push({
      route: stringValue(pageValue, "route") ?? "unknown",
      visibility: stringValue(pageValue, "visibility") ?? "unknown",
      focused: pageValue.focused === true,
      chatMounted: pageValue.chatMounted === true,
      chatPrepared: pageValue.chatPrepared === true,
      messageCount: numberValue(pageValue, "messageCount") ?? 0,
      visibleRows: numberValue(pageValue, "visibleRows") ?? 0,
      intersectingRows: numberValue(pageValue, "intersectingRows") ?? 0,
      viewportScrollTop: numberValue(pageValue, "viewportScrollTop") ?? 0,
      viewportScrollHeight:
        numberValue(pageValue, "viewportScrollHeight") ?? 0,
      viewportClientHeight:
        numberValue(pageValue, "viewportClientHeight") ?? 0,
      physicalBottom: pageValue.physicalBottom === true,
      logicalBottom: pageValue.logicalBottom === true,
      firstLayoutState:
        stringValue(pageValue, "firstLayoutState") ?? "missing",
      coverCount: numberValue(pageValue, "coverCount") ?? 0,
      coverInsideChat: pageValue.coverInsideChat === true,
      alertVisible: pageValue.alertVisible === true,
      openingInline: pageValue.openingInline === true,
      loadingChat: pageValue.loadingChat === true,
      routePlaceholder: pageValue.routePlaceholder === true,
      routePlaceholderCategory:
        stringValue(pageValue, "routePlaceholderCategory") ?? "unknown",
      bodyElementCount: numberValue(pageValue, "bodyElementCount") ?? 0,
      authRecordCount:
        numberValue(authPersistenceValue, "recordCount") ?? -1,
      authLogoutPending:
        authPersistenceValue?.logoutPending === true,
      matchFailures: Array.isArray(pageValue.matchFailures)
        ? pageValue.matchFailures.flatMap((failure) => {
            if (!isRecord(failure)) return []
            return [{
              routeId: stringValue(failure, "routeId") ?? "unknown",
              status: stringValue(failure, "status") ?? "unknown",
              errorType: stringValue(failure, "errorType") ?? "unknown",
              errorName: stringValue(failure, "errorName") ?? "unknown",
            }]
          })
        : [],
    })
  }
  const result = await connection
    .call(
      "Runtime.evaluate",
      { expression: frameEvidenceSource, returnByValue: true },
      session.sessionId,
    )
    .catch(() => undefined)
  const runtime = result?.result
  if (!isRecord(runtime) || !isRecord(runtime.value)) continue
  const value = runtime.value
  if (Array.isArray(value.runtimeFailures)) {
    for (const failure of value.runtimeFailures) {
      if (typeof failure !== "string" || diagnostics.length >= 5) continue
      const diagnostic = sanitizedDiagnostic(failure)
      if (diagnostic) diagnostics.push(diagnostic)
    }
  }
  if (Array.isArray(value.matchFailures)) {
    for (const failure of value.matchFailures) {
      if (!isRecord(failure) || diagnostics.length >= 12) continue
      diagnostics.push(
        sanitizedDiagnostic(
          `route match ${stringValue(failure, "routeId") ?? "unknown"} ` +
            `${stringValue(failure, "issue") ?? "failed"} with ` +
            `${stringValue(failure, "errorType") ?? "unknown"} ` +
            `${stringValue(failure, "errorName") ?? "unknown"}`,
        ),
      )
    }
  }
  const routes = isRecord(value.routes)
    ? Object.fromEntries(
        Object.entries(value.routes).filter(
          (entry): entry is [string, number] =>
            typeof entry[1] === "number",
        ),
      )
    : {}
  frameEvidence.push({
    frames: numberValue(value, "frames") ?? 0,
    routes,
    coveredFrames: numberValue(value, "coveredFrames") ?? 0,
    incompleteExposedChatFrames:
      numberValue(value, "incompleteExposedChatFrames") ?? 0,
    emptyMeasuredChatFrames:
      numberValue(value, "emptyMeasuredChatFrames") ?? 0,
    maximumVisibleRows: numberValue(value, "maximumVisibleRows") ?? 0,
  })
  await connection
    .call(
      "Runtime.evaluate",
      { expression: stopFrameRecorderSource },
      session.sessionId,
    )
    .catch(() => undefined)
}

const workerEvidence: WorkerEvidence[] = []
for (const session of sessions.values()) {
  if (session.type !== "shared_worker") continue
  const result = await Promise.race([
    connection.call(
      "Runtime.evaluate",
      {
        expression: workerEvidenceSource,
        awaitPromise: true,
        returnByValue: true,
      },
      session.sessionId,
    ).catch(() => undefined),
    Bun.sleep(500).then(() => undefined),
  ])
  const runtime = result?.result
  if (!isRecord(runtime) || !isRecord(runtime.value)) {
    workerEvidence.push({
      responsive: false,
      heldLocks: 0,
      pendingLocks: 0,
      accountLocks: 0,
      pendingAccountLocks: 0,
    })
    continue
  }
  workerEvidence.push({
    responsive: runtime.value.responsive === true,
    heldLocks: numberValue(runtime.value, "heldLocks") ?? 0,
    pendingLocks: numberValue(runtime.value, "pendingLocks") ?? 0,
    accountLocks: numberValue(runtime.value, "accountLocks") ?? 0,
    pendingAccountLocks:
      numberValue(runtime.value, "pendingAccountLocks") ?? 0,
  })
}

await connection.close()
const accountLockHolders = workerEvidence.reduce(
  (count, worker) => count + worker.accountLocks,
  0,
)
const pendingAccountLocks = workerEvidence.reduce(
  (count, worker) => count + worker.pendingAccountLocks,
  0,
)
const report = {
  schemaVersion: 1,
  startedAt: startedAt.toISOString(),
  finishedAt: new Date().toISOString(),
  durationMs: Date.now() - startedAt.getTime(),
  appOrigin,
  targets: Object.fromEntries(targetCounts),
  ownerRecovery: {
    requested: terminateOwner,
    terminated: terminatedOwner,
    replacementObserved:
      (targetCounts.get("shared_worker") ?? 0) > 1,
    foregroundRequested: foregroundPage,
    reloadRequested: reloadPage,
    retryRequested: retryRoute,
  },
  network: {
    externalRequests: Object.fromEntries(requests),
    failedExternalRequests: Object.fromEntries(failedRequests),
    externalResponseStatuses: Object.fromEntries(requestStatuses),
    externalFailureReasons: Object.fromEntries(requestFailureReasons),
    webSocketAttempts: Object.fromEntries(sockets),
    webSocketFramesReceived: Object.fromEntries(socketFramesReceived),
    webSocketFramesSent: Object.fromEntries(socketFramesSent),
    receivedEnvelopeTypes: Object.fromEntries(receivedEnvelopeTypes),
    sentEnvelopeTypes: Object.fromEntries(sentEnvelopeTypes),
    webSocketCloses: socketCloses,
    webSocketFrameErrors: socketErrors,
  },
  runtime: {
    exceptions,
    consoleErrors,
    consoleWarnings,
    logErrors,
    logWarnings,
    errorCategories: Object.fromEntries(errorCategories),
    diagnostics,
  },
  exercise,
  frames: frameEvidence,
  pages: pageEvidence,
  workers: workerEvidence,
  coreOwnership: {
    accountLockHolders,
    pendingAccountLocks,
    singular: accountLockHolders === 1 && pendingAccountLocks === 0,
  },
  privacy: {
    captured:
      "target types, normalized routes, DOM readiness counters, auth record and tombstone counts, sanitized origins/pathnames, aggregate errors, sanitized first-line exception diagnostics, and protobuf envelope type counts including connection error enums",
    excluded:
      "headers, cookies, credentials, tokens, request or response fields, query strings, raw WebSocket frame payloads, message text, names, and peer identifiers",
  },
}

await mkdir(dirname(outputPath), { recursive: true })
await Bun.write(outputPath, `${JSON.stringify(report, null, 2)}\n`)
console.log(
  JSON.stringify({
    outputPath,
    targets: report.targets,
    websocketAttempts: Object.values(report.network.webSocketAttempts).reduce(
      (sum, value) => sum + value,
      0,
    ),
    failedRequests: Object.values(report.network.failedExternalRequests).reduce(
      (sum, value) => sum + value,
      0,
    ),
    runtimeErrors:
      exceptions + consoleErrors + logErrors + socketErrors,
  }),
)
// Bun's WebSocket implementation can retain the closed CDP handle after the
// report has been durably written. This is a bounded CLI, not a reusable
// library process, so make successful completion explicit and deterministic.
process.exit(0)
