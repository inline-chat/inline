import {
  ClientMessage,
  type ClientMessage as ClientMessageType,
} from "@inline-chat/protocol/core"
import {
  describe,
  expect,
  it,
} from "@effect/vitest"
import {
  Effect,
  ErrorReporter,
  Layer,
} from "effect"
import {
  ErrorReporter as InlineErrorReporter,
} from "../core/errors/errorReporter"
import {
  ErrorReportJournal,
  RecordingErrorReporter,
} from "../core/testing/errorReporter"
import {
  RealtimeHostOpenFailure,
  RealtimeSessionFailure,
  RealtimeSessions,
  makeRealtimeHostConnection,
  type RealtimeProtocolSession,
  type RealtimeSessionsShape,
  type RealtimeTransportPeer,
} from "./host.effect"

const ping: ClientMessageType = {
  id: 77n,
  seq: 3,
  body: {
    oneofKind: "ping",
    ping: { nonce: 42n },
  },
}

const makePeer = () => {
  const closes: Array<void> = []
  const sent: Array<{
    bytes: Uint8Array
    compress: boolean
  }> = []
  const peer: RealtimeTransportPeer = {
    id: "peer-1",
    close: () => {
      closes.push(undefined)
    },
    sendBinary: (bytes, compress) => {
      sent.push({
        bytes: bytes.slice(),
        compress,
      })
      return bytes.byteLength
    },
  }
  return { closes, peer, sent }
}

const makeSessionsLayer = (
  sessions: RealtimeSessionsShape,
) =>
  Layer.succeed(RealtimeSessions)(sessions)

const makeSession = (
  options: {
    readonly close?: Effect.Effect<
      void,
      RealtimeSessionFailure
    >
    readonly handle?: (
      message: ClientMessageType,
    ) => Effect.Effect<
      void,
      RealtimeSessionFailure
    >
  } = {},
): RealtimeProtocolSession => ({
  connectionId: "connection-1",
  close: options.close ?? Effect.void,
  handle:
    options.handle ??
    (() => Effect.void),
})

describe("realtime Effect host boundary", () => {
  it.layer(RecordingErrorReporter)(
    "successful binary session",
    (it) => {
      it.effect(
        "decodes exact protobuf bytes and removes the session once",
        () =>
          Effect.gen(function* () {
            const { closes, peer } =
              makePeer()
            const handled: Array<ClientMessageType> =
              []
            let sessionCloses = 0
            const connection =
              yield* makeRealtimeHostConnection(
                peer,
                {
                  ip: "127.0.0.1",
                  userAgent: "Inline Test",
                },
              ).pipe(
                Effect.provide(
                  makeSessionsLayer({
                    open: (_peer, metadata) =>
                      Effect.sync(() => {
                        expect(metadata).toEqual({
                          ip: "127.0.0.1",
                          userAgent:
                            "Inline Test",
                        })
                        return makeSession({
                          handle: (message) =>
                            Effect.sync(() => {
                              handled.push(
                                message,
                              )
                            }),
                          close: Effect.sync(
                            () => {
                              sessionCloses += 1
                            },
                          ),
                        })
                      }),
                  }),
                ),
              )

            yield* connection.receive(
              ClientMessage.toBinary(ping),
            )
            yield* connection.close
            yield* connection.close

            expect(handled).toEqual([ping])
            expect(sessionCloses).toBe(1)
            expect(closes).toHaveLength(1)
            const journal =
              yield* ErrorReportJournal
            expect(
              yield* journal.entries,
            ).toEqual([])
          }),
      )
    },
  )

  it.layer(RecordingErrorReporter)(
    "protocol rejection",
    (it) => {
      it.effect(
        "reports and closes a text frame without invoking the handler",
        () =>
          Effect.gen(function* () {
            const journal =
              yield* ErrorReportJournal
            yield* journal.clear
            const { closes, peer } =
              makePeer()
            let handled = 0
            let sessionCloses = 0
            const connection =
              yield* makeRealtimeHostConnection(
                peer,
                {
                  host: "api.inline.chat",
                  ip: "127.0.0.1",
                  origin: "https://inline.chat",
                  userAgent: "Inline Test",
                },
              ).pipe(
                Effect.provide(
                  makeSessionsLayer({
                    open: () =>
                      Effect.succeed(
                        makeSession({
                          handle: () =>
                            Effect.sync(() => {
                              handled += 1
                            }),
                          close: Effect.sync(
                            () => {
                              sessionCloses += 1
                            },
                          ),
                        }),
                      ),
                  }),
                ),
              )

            yield* connection.receive("hello")
            yield* connection.receive("again")
            yield* connection.close

            expect(handled).toBe(0)
            expect(closes).toHaveLength(1)
            expect(sessionCloses).toBe(1)
            const reports =
              yield* journal.entries
            expect(reports).toHaveLength(1)
            expect(
              reports[0]?.context.operation,
            ).toBe("realtime.text_frame")
            expect(reports[0]?.context).toEqual({
              operation: "realtime.text_frame",
              connectionId: "peer-1",
              clientIp: "127.0.0.1",
              userAgent: "Inline Test",
              origin: "https://inline.chat",
              host: "api.inline.chat",
            })
          }),
      )

      it.effect(
        "reports malformed protobuf without retaining the raw frame",
        () =>
          Effect.gen(function* () {
            const journal =
              yield* ErrorReportJournal
            yield* journal.clear
            const { closes, peer } =
              makePeer()
            let sessionCloses = 0
            const connection =
              yield* makeRealtimeHostConnection(
                peer,
              ).pipe(
                Effect.provide(
                  makeSessionsLayer({
                    open: () =>
                      Effect.succeed(
                        makeSession({
                          close: Effect.sync(
                            () => {
                              sessionCloses += 1
                            },
                          ),
                        }),
                      ),
                  }),
                ),
              )

            yield* connection.receive(
              new Uint8Array([9, 9, 9]),
            )
            yield* connection.close

            expect(closes).toHaveLength(1)
            expect(sessionCloses).toBe(1)
            const reports =
              yield* journal.entries
            expect(reports).toHaveLength(1)
            expect(
              reports[0]?.context.operation,
            ).toBe("realtime.decode")
          }),
      )
    },
  )

  it.layer(RecordingErrorReporter)(
    "operation failures",
    (it) => {
      it.effect(
        "reports an escaped handler failure and closes the transport",
        () =>
          Effect.gen(function* () {
            const journal =
              yield* ErrorReportJournal
            yield* journal.clear
            const { closes, peer } =
              makePeer()
            let sessionCloses = 0
            const connection =
              yield* makeRealtimeHostConnection(
                peer,
              ).pipe(
                Effect.provide(
                  makeSessionsLayer({
                    open: () =>
                      Effect.succeed(
                        makeSession({
                          handle: () =>
                            Effect.fail(
                              new RealtimeSessionFailure(
                                {
                                  cause:
                                    new Error(
                                      "private handler failure",
                                    ),
                                  connectionId:
                                    "connection-1",
                                  phase:
                                    "message",
                                },
                              ),
                            ),
                          close: Effect.sync(
                            () => {
                              sessionCloses += 1
                            },
                          ),
                        }),
                      ),
                  }),
                ),
              )

            yield* connection.receive(
              ClientMessage.toBinary(ping),
            )
            yield* connection.close

            expect(closes).toHaveLength(1)
            expect(sessionCloses).toBe(1)
            const reports =
              yield* journal.entries
            expect(reports).toHaveLength(1)
            expect(
              reports[0]?.context.operation,
            ).toBe("realtime.message")
          }),
      )

      it.effect(
        "reports open failure, closes the peer, and keeps a typed result",
        () =>
          Effect.gen(function* () {
            const journal =
              yield* ErrorReportJournal
            yield* journal.clear
            const { closes, peer } =
              makePeer()
            const failure = yield* Effect.flip(
              makeRealtimeHostConnection(
                peer,
              ).pipe(
                Effect.provide(
                  makeSessionsLayer({
                    open: () =>
                      Effect.fail(
                        new RealtimeSessionFailure(
                          {
                            cause:
                              new Error(
                                "private open failure",
                              ),
                            phase: "open",
                          },
                        ),
                      ),
                  }),
                ),
              ),
            )

            expect(failure).toBeInstanceOf(
              RealtimeHostOpenFailure,
            )
            expect(
              ErrorReporter.isIgnored(failure),
            ).toBe(true)
            expect(closes).toHaveLength(1)
            const reports =
              yield* journal.entries
            expect(reports).toHaveLength(1)
            expect(
              reports[0]?.context.operation,
            ).toBe("realtime.open")
          }),
      )
    },
  )

  it.layer(RecordingErrorReporter)(
    "idempotent termination",
    (it) => {
      it.effect(
        "runs one cleanup for concurrent terminal receives and a later close",
        () =>
          Effect.gen(function* () {
            const journal =
              yield* ErrorReportJournal
            const { closes, peer } =
              makePeer()
            let sessionCloses = 0
            const connection =
              yield* makeRealtimeHostConnection(
                peer,
              ).pipe(
                Effect.provide(
                  makeSessionsLayer({
                    open: () =>
                      Effect.succeed(
                        makeSession({
                          handle: () =>
                            Effect.fail(
                              new RealtimeSessionFailure(
                                {
                                  cause:
                                    new Error(
                                      "concurrent failure",
                                    ),
                                  connectionId:
                                    "connection-1",
                                  phase:
                                    "message",
                                },
                              ),
                            ),
                          close: Effect.sync(
                            () => {
                              sessionCloses += 1
                            },
                          ),
                        }),
                      ),
                  }),
                ),
              )

            yield* Effect.all(
              [
                connection.receive("text"),
                connection.receive(
                  new Uint8Array([9, 9, 9]),
                ),
                connection.receive(
                  ClientMessage.toBinary(ping),
                ),
              ],
              {
                concurrency: "unbounded",
                discard: true,
              },
            )
            yield* connection.close

            expect(closes).toHaveLength(1)
            expect(sessionCloses).toBe(1)
            expect(
              yield* journal.entries,
            ).toHaveLength(1)
          }),
      )

      it.effect(
        "reports transport and session cleanup failures without skipping either cleanup",
        () =>
          Effect.gen(function* () {
            const journal =
              yield* ErrorReportJournal
            yield* journal.clear
            let transportCloses = 0
            let sessionCloses = 0
            const peer: RealtimeTransportPeer =
              {
                id: "peer-cleanup-failure",
                close: () => {
                  transportCloses += 1
                  throw new Error(
                    "private transport close failure",
                  )
                },
                sendBinary: (bytes) =>
                  bytes.byteLength,
              }
            const connection =
              yield* makeRealtimeHostConnection(
                peer,
              ).pipe(
                Effect.provide(
                  makeSessionsLayer({
                    open: () =>
                      Effect.succeed(
                        makeSession({
                          close: Effect.suspend(
                            () => {
                              sessionCloses += 1
                              return Effect.fail(
                                new RealtimeSessionFailure(
                                  {
                                    cause:
                                      new Error(
                                        "private session close failure",
                                      ),
                                    connectionId:
                                      "connection-1",
                                    phase: "close",
                                  },
                                ),
                              )
                            },
                          ),
                        }),
                      ),
                  }),
                ),
              )

            yield* connection.receive("text")
            yield* connection.close

            expect(transportCloses).toBe(1)
            expect(sessionCloses).toBe(1)
            expect(
              (yield* journal.entries).map(
                (entry) =>
                  entry.context.operation,
              ),
            ).toEqual([
              "realtime.text_frame",
              "realtime.text_frame.transport_close",
              "realtime.close",
            ])
          }),
      )
    },
  )

  it.effect(
    "absorbs reporter defects while still attempting every cleanup once",
    () =>
      Effect.gen(function* () {
        const reportAttempts: Array<string> = []
        let transportCloses = 0
        let sessionCloses = 0
        const reporter =
          Layer.succeed(InlineErrorReporter)({
            report: ({ context }) =>
              Effect.sync(() => {
                reportAttempts.push(
                  context.operation,
                )
              }).pipe(
                Effect.andThen(
                  Effect.die(
                    new Error(
                      "private reporter failure",
                    ),
                  ),
                ),
              ),
          })
        const peer: RealtimeTransportPeer = {
          id: "peer-reporter-failure",
          close: () => {
            transportCloses += 1
            throw new Error(
              "private transport close failure",
            )
          },
          sendBinary: (bytes) =>
            bytes.byteLength,
        }
        const connection =
          yield* makeRealtimeHostConnection(
            peer,
          ).pipe(
            Effect.provide(reporter),
            Effect.provide(
              makeSessionsLayer({
                open: () =>
                  Effect.succeed(
                    makeSession({
                      close: Effect.suspend(
                        () => {
                          sessionCloses += 1
                          return Effect.fail(
                            new RealtimeSessionFailure(
                              {
                                cause:
                                  new Error(
                                    "private session close failure",
                                  ),
                                connectionId:
                                  "connection-1",
                                phase: "close",
                              },
                            ),
                          )
                        },
                      ),
                    }),
                  ),
              }),
            ),
          )

        yield* connection.receive("text")
        yield* connection.close

        expect(transportCloses).toBe(1)
        expect(sessionCloses).toBe(1)
        expect(reportAttempts).toEqual([
          "realtime.text_frame",
          "realtime.text_frame.transport_close",
          "realtime.close",
        ])
      }),
  )
})
