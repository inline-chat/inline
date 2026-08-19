import {
  describe,
  expect,
  it,
} from "bun:test"
import {
  Cause,
  Context,
  Effect,
  Stream,
} from "effect"
import {
  HttpRouter,
  HttpServerResponse,
} from "effect/unstable/http"
import {
  CoreProductionStartupError,
  coreProductionStartupErrorDetails,
  makeCoreHttpDrain,
  shutdownWithDeadline,
} from "./productionHost"
import {
  makeCoreHttpRequestHandler,
} from "./bunRequestHandler"

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

describe("production HTTP drain", () => {
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
})
