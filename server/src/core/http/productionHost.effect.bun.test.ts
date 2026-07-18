import {
  describe,
  expect,
  it,
} from "bun:test"
import {
  Context,
  Effect,
  Stream,
} from "effect"
import {
  HttpRouter,
  HttpServerResponse,
} from "effect/unstable/http"
import {
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
