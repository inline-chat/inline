import {
  describe,
  expect,
  it,
  spyOn,
} from "bun:test"
import {
  Cause,
  Context,
  Effect,
  Layer,
  Stream,
} from "effect"
import {
  HttpRouter,
  HttpServerResponse,
} from "effect/unstable/http"
import {
  CoreProductionStartupError,
  coreProductionStartupErrorDetails,
  isBotLongPollRequest,
  makeCoreHttpDrain,
  startCoreProductionServer,
  shutdownWithDeadline,
  waitForCoreHttpNetworkDrain,
} from "./productionHost"
import {
  makeCoreHttpRequestHandler,
} from "./bunRequestHandler"
import {
  makeHttpKernelMiddlewareLayer,
} from "./middleware"
import { connectionBackgroundWork } from "../../ws/backgroundWork"
import { connectionManager } from "../../ws/connections"
import { applicationBackgroundWork } from "../../lifecycle/backgroundWork"

const deferred = <A>() => {
  let resolve:
    | ((value: A) => void)
    | undefined
  let reject:
    | ((cause: unknown) => void)
    | undefined
  const promise =
    new Promise<A>(
      (resolvePromise, rejectPromise) => {
        resolve = resolvePromise
        reject = rejectPromise
      },
    )
  return {
    promise,
    reject: (cause: unknown) =>
      reject?.(cause),
    resolve: (value: A) =>
      resolve?.(value),
  }
}

describe("production startup diagnostics", () => {
  it("keeps the original startup failure available to the process boundary", () => {
    const error = new CoreProductionStartupError({
      cause: Cause.die(new Error("Failed to bind port 8000")),
    })

    expect(coreProductionStartupErrorDetails(error)).toContain(
      "Failed to bind port 8000",
    )
  })

  it("recognizes only the two Bot API long-poll GET paths", () => {
    expect(isBotLongPollRequest(new Request("http://inline.test/bot/getUpdates?timeout=25"))).toBe(true)
    expect(isBotLongPollRequest(new Request("http://inline.test/botTOKEN/getUpdates"))).toBe(true)
    expect(isBotLongPollRequest(new Request("http://inline.test/bot/getMe"))).toBe(false)
    expect(isBotLongPollRequest(new Request("http://inline.test/bot/getUpdates", { method: "POST" }))).toBe(false)
  })
})

const instrumentAbortListeners = (
  request: Request,
) => {
  const signal = request.signal
  const addEventListener =
    signal.addEventListener.bind(signal)
  const removeEventListener =
    signal.removeEventListener.bind(
      signal,
    )
  let added = 0
  let removed = 0
  const trackedAddEventListener:
    typeof signal.addEventListener = (
    type: string,
    listener:
      EventListenerOrEventListenerObject,
    options?:
      | AddEventListenerOptions
      | boolean,
  ) => {
    if (type === "abort") added += 1
    addEventListener(
      type,
      listener,
      options,
    )
  }
  const trackedRemoveEventListener:
    typeof signal.removeEventListener = (
    type: string,
    listener:
      EventListenerOrEventListenerObject,
    options?:
      | EventListenerOptions
      | boolean,
  ) => {
    if (type === "abort") removed += 1
    removeEventListener(
      type,
      listener,
      options,
    )
  }
  signal.addEventListener =
    trackedAddEventListener
  signal.removeEventListener =
    trackedRemoveEventListener
  return {
    added: () => added,
    removed: () => removed,
  }
}

describe("Bun request abort lifetime", () => {
  it("removes the abort listener after a normal response", async () => {
    const gate = deferred<void>()
    const router =
      Effect.runSync(HttpRouter.make)
    Effect.runSync(
      router.add(
        "GET",
        "/complete",
        Effect.promise(
          () => gate.promise,
        ).pipe(
          Effect.as(
            HttpServerResponse.text(
              "complete",
            ),
          ),
        ),
      ),
    )
    const handler =
      makeCoreHttpRequestHandler(
        Context.make(
          HttpRouter.HttpRouter,
          router,
        ),
      )
    const request = new Request(
      "http://inline.test/complete",
    )
    const listeners =
      instrumentAbortListeners(request)
    const responsePromise = handler(request)

    expect(listeners.added()).toBe(1)
    expect(listeners.removed()).toBe(0)
    gate.resolve()
    const response = await responsePromise
    expect(await response.text()).toBe(
      "complete",
    )
    expect(listeners.removed()).toBe(1)
  })

  it("keeps the abort listener until a response stream closes", async () => {
    const gate = deferred<void>()
    const router =
      Effect.runSync(HttpRouter.make)
    Effect.runSync(
      router.add(
        "GET",
        "/listener-stream",
        HttpServerResponse.stream(
          Stream.concat(
            Stream.make("first"),
            Stream.fromEffect(
              Effect.promise(
                () => gate.promise,
              ),
            ).pipe(
              Stream.map(
                () => "second",
              ),
            ),
          ).pipe(Stream.encodeText),
        ),
      ),
    )
    const handler =
      makeCoreHttpRequestHandler(
        Context.make(
          HttpRouter.HttpRouter,
          router,
        ),
      )
    const request = new Request(
      "http://inline.test/listener-stream",
    )
    const listeners =
      instrumentAbortListeners(request)
    const response = await handler(request)
    const reader =
      response.body!.getReader()

    expect(listeners.added()).toBe(1)
    expect(listeners.removed()).toBe(0)
    expect(
      new TextDecoder().decode(
        (await reader.read()).value,
      ),
    ).toBe("first")
    expect(listeners.removed()).toBe(0)

    gate.resolve()
    expect(
      new TextDecoder().decode(
        (await reader.read()).value,
      ),
    ).toBe("second")
    expect(
      (await reader.read()).done,
    ).toBe(true)
    expect(listeners.removed()).toBe(1)
  })

  it("still interrupts and finalizes an aborted request", async () => {
    const controller =
      new AbortController()
    const request = new Request(
      "http://inline.test/abort",
      { signal: controller.signal },
    )
    const listeners =
      instrumentAbortListeners(request)
    const finalized = deferred<void>()
    const interrupted = deferred<void>()
    const router =
      Effect.runSync(HttpRouter.make)
    Effect.runSync(
      router.add(
        "GET",
        "/abort",
        Effect.never.pipe(
          Effect.onInterrupt(
            () =>
              Effect.sync(() => {
                interrupted.resolve()
              }),
          ),
        ),
      ),
    )
    const handler =
      makeCoreHttpRequestHandler(
        Context.make(
          HttpRouter.HttpRouter,
          router,
        ),
      )
    void handler(
      request,
      undefined,
      () => {
        finalized.resolve()
      },
    )

    expect(listeners.added()).toBe(1)
    controller.abort()
    await Promise.all([
      interrupted.promise,
      finalized.promise,
    ])
    expect(listeners.removed()).toBe(1)
  })
})

describe("production shutdown ownership", () => {
  it("reports a manual deadline without disposing dependencies beneath active work", async () => {
    const release = deferred<void>()
    const finalized = deferred<void>()
    let disposed = false
    const application = Layer.effectDiscard(HttpRouter.HttpRouter.use(() =>
      Effect.acquireRelease(Effect.void, () => Effect.sync(() => {
        disposed = true
        finalized.resolve()
      })),
    )).pipe(Layer.provideMerge(makeHttpKernelMiddlewareLayer({ isProduction: false })))
    const handle = await startCoreProductionServer({
      application,
      hostname: "127.0.0.1",
      inlineProtocolConfiguration: { enabled: false },
      markShuttingDown: () => {},
      startClusterServices: false,
      gracefulShutdownMillis: 20,
    })
    applicationBackgroundWork.track(release.promise)
    try {
      await expect(handle.shutdown()).rejects.toThrow()
      expect(disposed).toBe(false)
      release.resolve()
      await finalized.promise
      expect(disposed).toBe(true)
    } finally {
      release.resolve()
      await applicationBackgroundWork.waitForIdle()
      await finalized.promise
    }
  })

  it("drains V3 client-type hydration before disposing the runtime", async () => {
    await connectionManager.shutdown()
    await connectionBackgroundWork.waitForIdle()

    const lookupStarted = deferred<void>()
    const releaseLookup = deferred<void>()
    const connectionShutdownEntered = deferred<void>()
    let runtimeFinalized = false
    const application = Layer.effectDiscard(
      HttpRouter.HttpRouter.use(() =>
        Effect.acquireRelease(
          Effect.void,
          () => Effect.sync(() => {
            runtimeFinalized = true
          }),
        ),
      ),
    ).pipe(
      Layer.provideMerge(
        makeHttpKernelMiddlewareLayer({ isProduction: false }),
      ),
    )
    const shutdownConnections = connectionManager.shutdown.bind(connectionManager)
    const shutdownSpy = spyOn(connectionManager, "shutdown").mockImplementation(async () => {
      connectionShutdownEntered.resolve()
      await shutdownConnections()
    })
    let handle: Awaited<ReturnType<typeof startCoreProductionServer>> | undefined
    let shutdown: Promise<void> | undefined

    try {
      handle = await startCoreProductionServer({
        application,
        hostname: "127.0.0.1",
        inlineProtocolConfiguration: { enabled: false },
        markShuttingDown: () => {},
        startClusterServices: false,
      })
      connectionManager.hydrateAuthenticatedClientType(991, 1991, async () => {
        lookupStarted.resolve()
        await releaseLookup.promise
        return "macos"
      })
      await lookupStarted.promise

      shutdown = handle.shutdown()
      await connectionShutdownEntered.promise
      expect(runtimeFinalized).toBe(false)

      releaseLookup.resolve()
      await shutdown
      expect(runtimeFinalized).toBe(true)
    } finally {
      releaseLookup.resolve()
      await shutdown?.catch(() => {})
      if (handle && shutdown === undefined) await handle.shutdown().catch(() => {})
      shutdownSpy.mockRestore()
      await connectionManager.shutdown()
      await connectionBackgroundWork.waitForIdle()
    }
  })
})

describe("production HTTP drain", () => {
  it("keeps a long poll alive beyond Bun's default idle timeout", async () => {
    const application = Layer.effectDiscard(
      HttpRouter.HttpRouter.use((router) =>
        router.add(
          "GET",
          "/bot/getUpdates",
          Effect.promise(async () => {
            await Bun.sleep(11_000)
            return HttpServerResponse.jsonUnsafe({ ok: true, result: [] })
          }),
        ),
      ),
    ).pipe(
      Layer.provideMerge(makeHttpKernelMiddlewareLayer({ isProduction: false })),
    )
    const handle = await startCoreProductionServer({
      application,
      hostname: "127.0.0.1",
      inlineProtocolConfiguration: { enabled: false },
      markShuttingDown: () => {},
      startClusterServices: false,
    })

    try {
      const response = await fetch(`http://127.0.0.1:${handle.port}/bot/getUpdates?timeout=25`)
      expect(response.status).toBe(200)
      expect(await response.json()).toEqual({ ok: true, result: [] })
    } finally {
      await handle.shutdown()
    }
  }, 20_000)

  it("keeps an accepted production-host response alive through shutdown", async () => {
    const accepted = deferred<void>()
    const allowResponse = deferred<void>()
    const callbackComplete = deferred<void>()
    const application = Layer.effectDiscard(
      HttpRouter.HttpRouter.use((router) =>
        router.add(
          "GET",
          "/network-drain",
          Effect.promise(async () => {
            accepted.resolve()
            await allowResponse.promise
            callbackComplete.resolve()
            return HttpServerResponse.jsonUnsafe({ ok: true })
          }),
        ),
      ),
    ).pipe(
      Layer.provideMerge(
        makeHttpKernelMiddlewareLayer({
          isProduction: false,
        }),
      ),
    )
    const handle = await startCoreProductionServer({
      application,
      gracefulShutdownMillis: 1_000,
      hostname: "127.0.0.1",
      inlineProtocolConfiguration: { enabled: false },
      markShuttingDown: () => {},
      startClusterServices: false,
    }).catch((error) => {
      throw new Error(coreProductionStartupErrorDetails(error) ?? String(error))
    })
    const response = fetch(
      `http://127.0.0.1:${handle.port}/network-drain`,
    ).then(async (result) => ({
      body: await result.text(),
      status: result.status,
    }))

    try {
      await accepted.promise
      const shutdown = handle.shutdown()
      allowResponse.resolve()
      await callbackComplete.promise
      expect(await response).toEqual({
        body: '{"ok":true}',
        status: 200,
      })
      await shutdown
    } finally {
      await handle.shutdown()
    }
  })

  it("flushes an accepted Bun HTTP response before force-closing the listener", async () => {
    const accepted = deferred<void>()
    const allowResponse = deferred<void>()
    const callbackComplete = deferred<void>()
    const server = Bun.serve({
      hostname: "127.0.0.1",
      port: 0,
      async fetch() {
        accepted.resolve()
        await allowResponse.promise
        callbackComplete.resolve()
        return Response.json({ ok: true })
      },
    })
    const response = fetch(server.url).then(async (result) => ({
      body: await result.text(),
      status: result.status,
    }))

    try {
      await accepted.promise
      void server.stop(false)
      allowResponse.resolve()
      await callbackComplete.promise
      expect(server.pendingRequests).toBeGreaterThan(0)

      await waitForCoreHttpNetworkDrain(
        server,
        new AbortController().signal,
      )
      expect(server.pendingRequests).toBe(0)

      void server.stop(true)
      expect(await response).toEqual({
        body: '{"ok":true}',
        status: 200,
      })
    } finally {
      void server.stop(true)
      server.unref()
    }
  })

  it("waits for in-flight work and resolves every waiter", async () => {
    const drain = makeCoreHttpDrain()
    const operation = deferred<string>()
    const complete =
      drain.enter()

    drain.begin()
    expect(drain.isDraining()).toBe(
      true,
    )
    let firstResolved = false
    const firstWait =
      drain.wait().then(() => {
        firstResolved = true
      })
    const secondWait = drain.wait()
    await Promise.resolve()
    expect(firstResolved).toBe(false)

    operation.resolve("complete")
    await expect(
      operation.promise,
    ).resolves.toBe(
      "complete",
    )
    complete()
    await Promise.all([
      firstWait,
      secondWait,
    ])
    expect(firstResolved).toBe(true)
  })

  it("drains rejected work and keeps begin and wait idempotent", async () => {
    const drain = makeCoreHttpDrain()
    const operation = deferred<void>()
    const complete =
      drain.enter()

    drain.begin()
    drain.begin()
    const waiting = drain.wait()
    operation.reject(
      new Error("request failed"),
    )
    await expect(
      operation.promise,
    ).rejects.toThrow(
      "request failed",
    )
    complete()
    complete()
    await waiting
    await drain.wait()
  })

  it("keeps a request active until its streaming response scope closes", async () => {
    const gate = deferred<void>()
    const router =
      Effect.runSync(HttpRouter.make)
    Effect.runSync(
      router.add(
        "GET",
        "/stream",
        HttpServerResponse.stream(
          Stream.concat(
            Stream.make("first"),
            Stream.fromEffect(
              Effect.promise(
                () => gate.promise,
              ),
            ).pipe(
              Stream.map(
                () => "second",
              ),
            ),
          ).pipe(
            Stream.encodeText,
          ),
        ),
      ),
    )
    const handler =
      makeCoreHttpRequestHandler(
        Context.make(
          HttpRouter.HttpRouter,
          router,
        ),
      )
    const drain = makeCoreHttpDrain()
    const complete =
      drain.enter()
    const response =
      await handler(
        new Request(
          "http://inline.test/stream",
        ),
        undefined,
        complete,
      )

    drain.begin()
    let drained = false
    const waiting =
      drain.wait().then(() => {
        drained = true
      })
    const reader =
      response.body!.getReader()
    const first = await reader.read()
    expect(
      new TextDecoder().decode(
        first.value,
      ),
    ).toBe("first")
    await Promise.resolve()
    expect(drained).toBe(false)

    gate.resolve()
    const second = await reader.read()
    expect(
      new TextDecoder().decode(
        second.value,
      ),
    ).toBe("second")
    expect(
      (await reader.read()).done,
    ).toBe(true)
    await waiting
    expect(drained).toBe(true)
  })

  it("runs the force-close callback when the shutdown deadline expires", async () => {
    let forced = 0
    await expect(
      shutdownWithDeadline(
        () => new Promise<void>(() => {}),
        5,
        () => {
          forced += 1
        },
        () => "in-flight HTTP drain",
      ),
    ).rejects.toThrow(
      "in-flight HTTP drain",
    )
    expect(forced).toBe(1)
  })

  it("aborts the network-flush poll at the shared shutdown deadline", async () => {
    let forced = 0
    let sawAbort = false
    await expect(
      shutdownWithDeadline(
        async (signal) => {
          await waitForCoreHttpNetworkDrain(
            { pendingRequests: 1 },
            signal,
          )
          sawAbort = signal.aborted
        },
        5,
        () => {
          forced += 1
        },
        () => "HTTP network response flush",
      ),
    ).rejects.toThrow(
      "HTTP network response flush",
    )
    expect(forced).toBe(1)
    expect(sawAbort).toBe(true)
  })
})
