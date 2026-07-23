import { mkdir } from "node:fs/promises"
import { dirname, resolve } from "node:path"
import {
  CdpConnection,
  type JsonRecord,
} from "../browser/CdpConnection"

const isRecord = (value: unknown): value is JsonRecord =>
  typeof value === "object" && value != null

const option = (name: string, fallback?: string) => {
  const prefix = `--${name}=`
  return process.argv
    .find((value) => value.startsWith(prefix))
    ?.slice(prefix.length) ?? fallback
}

const debuggerOrigin = option(
  "debugger",
  "http://127.0.0.1:9223",
)!
const appOrigin = new URL(
  option("app", "http://localhost:8001")!,
).origin
const selfUserId = Number(option("self-user-id"))
const offlineMs = Number(option("offline-ms", "0"))
const outputPath = resolve(
  option(
    "output",
    ".artifacts/acceptance/real-account-transaction-latest.json",
  )!,
)

if (!Number.isSafeInteger(selfUserId) || selfUserId <= 0) {
  throw new TypeError(
    "--self-user-id must be the freshly discovered positive current-user ID",
  )
}
if (!Number.isFinite(offlineMs) || offlineMs < 0) {
  throw new TypeError("--offline-ms must be a non-negative number")
}

const connection = await CdpConnection.open(debuggerOrigin)
let networkSessionIds: string[] = []
let workerNetworkSessionId: string | undefined
let realtimeSocketCreated = false
let realtimeSocketClosed = false
let exceptions = 0
let consoleErrors = 0
let consoleWarnings = 0

const evaluate = async <Value>(
  sessionId: string,
  expression: string,
  awaitPromise = false,
) => {
  const response = await connection.call(
    "Runtime.evaluate",
    {
      expression,
      awaitPromise,
      returnByValue: true,
    },
    sessionId,
  )
  if (isRecord(response.exceptionDetails)) {
    throw new Error("Inline transaction page evaluation failed")
  }
  const result = response.result
  if (!isRecord(result)) return undefined
  return result.value as Value | undefined
}

const waitFor = async <Value>(
  operation: () => Promise<Value | undefined>,
  accept: (value: Value | undefined) => boolean,
  timeoutMs: number,
  label: string,
) => {
  const deadline = Date.now() + timeoutMs
  while (Date.now() < deadline) {
    const value = await operation()
    if (accept(value)) return value
    await Bun.sleep(50)
  }
  throw new Error(`Timed out waiting for ${label}`)
}

try {
  const targetResult = await connection.call("Target.getTargets")
  const targetInfos = Array.isArray(targetResult.targetInfos)
    ? targetResult.targetInfos
    : []
  const pageTarget = targetInfos.find(
    (value) =>
      isRecord(value) &&
      value.type === "page" &&
      typeof value.url === "string" &&
      new URL(value.url).origin === appOrigin,
  )
  if (!isRecord(pageTarget) || typeof pageTarget.targetId !== "string") {
    throw new Error("No authenticated Inline acceptance page is open")
  }
  const attached = await connection.call("Target.attachToTarget", {
    targetId: pageTarget.targetId,
    flatten: true,
  })
  if (typeof attached.sessionId !== "string") {
    throw new Error("Chrome did not create an Inline page session")
  }
  const sessionId = attached.sessionId
  await Promise.all([
    connection.call("Runtime.enable", {}, sessionId),
    connection.call("Page.enable", {}, sessionId),
    connection.call("Network.enable", {}, sessionId),
    connection.call("Page.bringToFront", {}, sessionId),
    connection.call(
      "Emulation.setFocusEmulationEnabled",
      { enabled: true },
      sessionId,
    ),
  ])
  networkSessionIds = [sessionId]
  for (const value of targetInfos) {
    if (
      !isRecord(value) ||
      value.type !== "shared_worker" ||
      typeof value.targetId !== "string" ||
      typeof value.url !== "string" ||
      new URL(value.url).origin !== appOrigin
    ) {
      continue
    }
    const workerAttached = await connection.call(
      "Target.attachToTarget",
      { targetId: value.targetId, flatten: true },
    )
    if (typeof workerAttached.sessionId !== "string") continue
    const workerSessionId = workerAttached.sessionId
    const workerReady = await Promise.race([
      connection
        .call("Runtime.enable", {}, workerSessionId)
        .then(() =>
          evaluate<{ holdsAccountLock: boolean }>(
            workerSessionId,
            `navigator.locks.query().then((snapshot) => ({
              holdsAccountLock: snapshot.held.some(
                (lock) => lock.name === ${JSON.stringify(`inline-core-account-${selfUserId}`)},
              ),
            }))`,
            true,
          ),
        )
        .catch(() => undefined),
      Bun.sleep(500).then(() => undefined),
    ])
    if (workerReady?.holdsAccountLock !== true) continue
    await connection.call("Network.enable", {}, workerSessionId)
    networkSessionIds.push(workerSessionId)
    workerNetworkSessionId = workerSessionId
    break
  }
  if (networkSessionIds.length !== 2) {
    throw new Error(
      "Could not attach the lock-holding Inline SharedWorker",
    )
  }
  const setOffline = async (offline: boolean) => {
    await Promise.all(
      networkSessionIds.map((targetSessionId) =>
        connection.call(
          "Network.emulateNetworkConditions",
          {
            offline,
            latency: 0,
            downloadThroughput: -1,
            uploadThroughput: -1,
          },
          targetSessionId,
        ),
      ),
    )
    await evaluate(
      sessionId,
      `(() => {
        window.dispatchEvent(new Event(${JSON.stringify(offline ? "offline" : "online")}))
        return true
      })()`,
    )
  }
  connection.onMessage((message) => {
    if (
      message.sessionId === workerNetworkSessionId &&
      message.method === "Network.webSocketCreated"
    ) {
      realtimeSocketCreated = true
    }
    if (
      message.sessionId === workerNetworkSessionId &&
      message.method === "Network.webSocketClosed"
    ) {
      realtimeSocketClosed = true
    }
    if (message.sessionId !== sessionId) return
    if (message.method === "Runtime.exceptionThrown") {
      exceptions += 1
      return
    }
    if (message.method !== "Runtime.consoleAPICalled") return
    const type = message.params?.type
    if (type === "error" || type === "assert") consoleErrors += 1
    if (type === "warning") consoleWarnings += 1
  })

  const browserAccount = await evaluate<{
    matchingAccountLock: boolean
    accountLockCount: number
  }>(
    sessionId,
    `navigator.locks.query().then((snapshot) => ({
      matchingAccountLock: snapshot.held.some(
        (lock) => lock.name === ${JSON.stringify(`inline-core-account-${selfUserId}`)},
      ),
      accountLockCount: snapshot.held.filter(
        (lock) => lock.name?.startsWith("inline-core-account-"),
      ).length,
    }))`,
    true,
  )
  if (
    browserAccount?.matchingAccountLock !== true ||
    browserAccount.accountLockCount !== 1
  ) {
    throw new Error(
      "The requested self user does not match the browser account owner",
    )
  }

  await connection.call(
    "Page.navigate",
    { url: `${appOrigin}/chat/user/${selfUserId}` },
    sessionId,
  )
  await waitFor(
    () =>
      evaluate<boolean>(
        sessionId,
        `Boolean(
          document.querySelector("[data-inline-compose-editor]") &&
          !document.querySelector("[data-inline-route-placeholder]") &&
          !document.querySelector("[data-inline-chat-loading]")
        )`,
      ),
    Boolean,
    15_000,
    "the self-DM composer",
  )

  const payload = `Inline Web Alpha transaction verification ${crypto.randomUUID()}`
  const witnessKey = "__inlineRealTransactionWitness"
  await evaluate(
    sessionId,
    `(() => {
      const payload = ${JSON.stringify(payload)}
      const key = ${JSON.stringify(witnessKey)}
      globalThis[key]?.observer?.disconnect?.()
      const evidence = {
        temporaryObserved: false,
        optimisticObserved: false,
      }
      const inspect = () => {
        for (const row of document.querySelectorAll("[data-message-id]")) {
          if (!row.textContent?.includes(payload)) continue
          const messageId = row.getAttribute("data-message-id") || ""
          if (messageId.startsWith("-")) evidence.temporaryObserved = true
          if (row.querySelector('[data-inline-optimistic-send="true"]')) {
            evidence.optimisticObserved = true
          }
        }
      }
      const observer = new MutationObserver(inspect)
      observer.observe(document.documentElement, {
        childList: true,
        subtree: true,
        attributes: true,
        attributeFilter: ["data-message-id", "data-inline-optimistic-send"],
      })
      globalThis[key] = { evidence, observer, inspect }
      inspect()
      return true
    })()`,
  )

  await evaluate(
    sessionId,
    `(() => {
      const editor = document.querySelector("[data-inline-compose-editor]")
      if (!(editor instanceof HTMLElement)) throw new Error("Composer missing")
      editor.focus()
      return true
    })()`,
  )
  await connection.call(
    "Input.insertText",
    { text: payload },
    sessionId,
  )
  await waitFor(
    () =>
      evaluate<boolean>(
        sessionId,
        `document.querySelector('button[aria-label="Send"]')?.disabled === false`,
      ),
    Boolean,
    5_000,
    "the accepted compose value",
  )

  if (offlineMs > 0) {
    const coreConnectionState = () =>
      evaluate<string>(
        sessionId,
        `document.querySelector("[data-inline-core-connection-state]")
          ?.getAttribute("data-inline-core-connection-state") || undefined`,
      )
    // Network.enable cannot retrospectively identify the already-open
    // realtime socket. Cycle constraints once without mutating so the probe
    // owns an observed socket ID and can prove the second offline transition
    // actually closed it.
    realtimeSocketCreated = false
    realtimeSocketClosed = false
    await setOffline(true)
    await waitFor(
      coreConnectionState,
      (value) => value === "connecting",
      5_000,
      "the offline core connection state",
    )
    await setOffline(false)
    await waitFor(
      async () => realtimeSocketCreated,
      Boolean,
      10_000,
      "a tracked realtime socket",
    )
    await waitFor(
      coreConnectionState,
      (value) => value === "connected",
      10_000,
      "the reconnected core state",
    )
    realtimeSocketClosed = false
    await setOffline(true)
    await waitFor(
      coreConnectionState,
      (value) => value === "connecting",
      5_000,
      "the final offline core connection state",
    )
    await waitFor(
      async () => realtimeSocketClosed,
      Boolean,
      5_000,
      "the realtime socket to close",
    )
  }
  const startedAt = performance.now()
  await evaluate(
    sessionId,
    `(() => {
      const send = document.querySelector('button[aria-label="Send"]')
      if (!(send instanceof HTMLButtonElement)) throw new Error("Send missing")
      send.click()
      return true
    })()`,
  )

  let localAcceptanceMs: number | undefined
  if (offlineMs > 0) {
    await waitFor(
      () =>
        evaluate<{
          negativeCount: number
          temporaryObserved: boolean
          optimisticObserved: boolean
        }>(
          sessionId,
          `(() => {
            const payload = ${JSON.stringify(payload)}
            const witness = globalThis[${JSON.stringify(witnessKey)}]
            witness?.inspect?.()
            const matching = [...document.querySelectorAll("[data-message-id]")]
              .filter((row) => row.textContent?.includes(payload))
            return {
              negativeCount: matching.filter((row) =>
                (row.getAttribute("data-message-id") || "").startsWith("-")
              ).length,
              temporaryObserved: witness?.evidence?.temporaryObserved === true,
              optimisticObserved: witness?.evidence?.optimisticObserved === true,
            }
          })()`,
        ),
      (value) =>
        value?.negativeCount === 1 &&
        value.temporaryObserved &&
        value.optimisticObserved,
      10_000,
      "offline optimistic acceptance",
    )
    localAcceptanceMs = Math.round(performance.now() - startedAt)
    await Bun.sleep(offlineMs)
    await setOffline(false)
  }

  const final = await waitFor(
    () =>
      evaluate<{
        positiveIds: string[]
        negativeCount: number
        temporaryObserved: boolean
        optimisticObserved: boolean
      }>(
        sessionId,
        `(() => {
          const payload = ${JSON.stringify(payload)}
          const witness = globalThis[${JSON.stringify(witnessKey)}]
          witness?.inspect?.()
          const matching = [...document.querySelectorAll("[data-message-id]")]
            .filter((row) => row.textContent?.includes(payload))
          return {
            positiveIds: matching
              .map((row) => row.getAttribute("data-message-id") || "")
              .filter((id) => /^\\d+$/.test(id) && id !== "0"),
            negativeCount: matching.filter((row) =>
              (row.getAttribute("data-message-id") || "").startsWith("-")
            ).length,
            temporaryObserved: witness?.evidence?.temporaryObserved === true,
            optimisticObserved: witness?.evidence?.optimisticObserved === true,
          }
        })()`,
      ),
    (value) =>
      value?.positiveIds.length === 1 && value.negativeCount === 0,
    35_000,
    "server message replacement",
  )
  if (!final || final.positiveIds.length !== 1) {
    throw new Error("Inline did not expose one final server message")
  }
  const finalMessageId = final.positiveIds[0]!
  const acceptanceMs = Math.round(performance.now() - startedAt)

  await connection.call("Page.reload", {}, sessionId)
  const reload = await waitFor(
    () =>
      evaluate<{ positiveCount: number; negativeCount: number }>(
        sessionId,
        `(() => {
          const payload = ${JSON.stringify(payload)}
          const matching = [...document.querySelectorAll("[data-message-id]")]
            .filter((row) => row.textContent?.includes(payload))
          return {
            positiveCount: matching.filter((row) =>
              /^\\d+$/.test(row.getAttribute("data-message-id") || "")
            ).length,
            negativeCount: matching.filter((row) =>
              (row.getAttribute("data-message-id") || "").startsWith("-")
            ).length,
          }
        })()`,
      ),
    (value) => value?.positiveCount === 1 && value.negativeCount === 0,
    15_000,
    "exactly-once reload convergence",
  )

  const report = {
    schemaVersion: 1,
    finishedAt: new Date().toISOString(),
    privacy: {
      messageTextPersisted: false,
      credentialsPersisted: false,
      signedUrlsPersisted: false,
    },
    target: {
      kind: "self-dm",
      selfUserId,
    },
    transaction: {
      finalMessageId,
      temporaryObserved: final.temporaryObserved,
      optimisticObserved: final.optimisticObserved,
      localAcceptanceMs,
      acceptanceMs,
      offlineCycle: offlineMs > 0,
      serverReplacementObserved: true,
      finalCount: final.positiveIds.length,
      temporaryCount: final.negativeCount,
      reloadFinalCount: reload?.positiveCount ?? 0,
      reloadTemporaryCount: reload?.negativeCount ?? 0,
      residueRetained: true,
    },
    runtime: {
      exceptions,
      consoleErrors,
      consoleWarnings,
    },
  }
  await mkdir(dirname(outputPath), { recursive: true })
  await Bun.write(outputPath, `${JSON.stringify(report, null, 2)}\n`)
  console.log(
    JSON.stringify({
      outputPath,
      transaction: report.transaction,
      runtime: report.runtime,
    }),
  )

  if (
    (offlineMs > 0 &&
      (!final.temporaryObserved || !final.optimisticObserved)) ||
    (offlineMs === 0 &&
      !final.temporaryObserved &&
      acceptanceMs > 500) ||
    reload?.positiveCount !== 1 ||
    reload.negativeCount !== 0 ||
    exceptions !== 0 ||
    consoleErrors !== 0
  ) {
    process.exitCode = 1
  }
} finally {
  await Promise.allSettled(
    networkSessionIds.map((sessionId) =>
      connection.call(
        "Network.emulateNetworkConditions",
        {
          offline: false,
          latency: 0,
          downloadThroughput: -1,
          uploadThroughput: -1,
        },
        sessionId,
      ),
    ),
  )
  await connection.close()
}
