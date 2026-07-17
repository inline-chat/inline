import type {
  ClientMessage as ClientMessageType,
} from "@inline-chat/protocol/core"
import {
  ClientMessage,
} from "@inline-chat/protocol/core"
import {
  Cause,
  Context,
  Data,
  Effect,
  ErrorReporter as EffectErrorReporter,
} from "effect"
import {
  ErrorReporter,
  type UnexpectedErrorContext,
} from "../core/errors/errorReporter"
import {
  toDiagnosticText,
} from "../core/schema/diagnostics"
import type {
  RealtimeRequestMetadata,
} from "./types"

export interface RealtimeTransportPeer {
  /** Stable only for this process lifetime; never exposed to clients. */
  readonly id: string
  readonly close: () => void
  readonly sendBinary: (
    bytes: Uint8Array,
    compress: boolean,
  ) => number
}

export type RealtimeSessionPhase =
  | "open"
  | "message"
  | "close"

export class RealtimeSessionFailure extends Data.TaggedError(
  "RealtimeSessionFailure",
)<{
  readonly cause: unknown
  readonly connectionId?: string | undefined
  readonly phase: RealtimeSessionPhase
}> {}

export interface RealtimeProtocolSession {
  readonly connectionId: string
  readonly close: Effect.Effect<
    void,
    RealtimeSessionFailure
  >
  readonly handle: (
    message: ClientMessageType,
  ) => Effect.Effect<
    void,
    RealtimeSessionFailure
  >
}

export interface RealtimeSessionsShape {
  readonly open: (
    peer: RealtimeTransportPeer,
    metadata?: RealtimeRequestMetadata,
  ) => Effect.Effect<
    RealtimeProtocolSession,
    RealtimeSessionFailure
  >
}

export class RealtimeSessions extends Context.Service<
  RealtimeSessions,
  RealtimeSessionsShape
>()("@inline/server/realtime/RealtimeSessions") {}

export class RealtimeFrameDecodeFailure extends Data.TaggedError(
  "RealtimeFrameDecodeFailure",
)<{
  readonly cause: unknown
  readonly connectionId: string
}> {}

export class RealtimeTextFrameRejected extends Data.TaggedError(
  "RealtimeTextFrameRejected",
)<{
  readonly connectionId: string
}> {}

export class RealtimeTransportCloseFailure extends Data.TaggedError(
  "RealtimeTransportCloseFailure",
)<{
  readonly cause: unknown
  readonly connectionId: string
}> {}

export class RealtimeHostOpenFailure extends Data.TaggedError(
  "RealtimeHostOpenFailure",
)<{
  /** The opening failure has already been reported at this host boundary. */
  readonly cause: Cause.Cause<
    RealtimeSessionFailure
  >
}> {
  override readonly [EffectErrorReporter.ignore] =
    true
}

export interface RealtimeHostConnection {
  readonly connectionId: string
  readonly close: Effect.Effect<void>
  readonly receive: (
    frame: string | Uint8Array,
  ) => Effect.Effect<void>
}

const operationForFailure = (
  failure:
    | RealtimeFrameDecodeFailure
    | RealtimeSessionFailure,
): string =>
  failure instanceof RealtimeFrameDecodeFailure
    ? "realtime.decode"
    : "realtime.message"

const makeRealtimeErrorContext = (
  operation: string,
  connectionId: string,
  metadata?: RealtimeRequestMetadata,
): UnexpectedErrorContext => ({
  operation,
  connectionId: toDiagnosticText(
    connectionId,
  ),
  clientIp: toDiagnosticText(metadata?.ip),
  userAgent: toDiagnosticText(
    metadata?.userAgent,
  ),
  origin: toDiagnosticText(metadata?.origin),
  host: toDiagnosticText(metadata?.host),
})

/**
 * Opens one transport-neutral realtime connection.
 *
 * The integration root owns WebSocket upgrade/configuration and feeds frames
 * into this capability. This boundary owns protobuf decoding, safe reporting,
 * close-on-protocol/error behavior, and idempotent session removal.
 */
export const makeRealtimeHostConnection =
  (
    peer: RealtimeTransportPeer,
    metadata?: RealtimeRequestMetadata,
  ): Effect.Effect<
    RealtimeHostConnection,
    RealtimeHostOpenFailure,
    ErrorReporter | RealtimeSessions
  > =>
    Effect.gen(function* () {
      const reporter = yield* ErrorReporter
      const sessions = yield* RealtimeSessions
      const report = (
        operation: string,
        cause: Cause.Cause<unknown>,
      ): Effect.Effect<void> =>
        reporter
          .report({
            cause,
            context: makeRealtimeErrorContext(
              operation,
              peer.id,
              metadata,
            ),
          })
          .pipe(
            Effect.catchCause(() => Effect.void),
          )

      const closeTransport = (
        operation: string,
      ): Effect.Effect<void> =>
        Effect.try({
          try: peer.close,
          catch: (cause) =>
            new RealtimeTransportCloseFailure({
              cause,
              connectionId: peer.id,
            }),
        }).pipe(
          Effect.catch((failure) =>
            report(
              operation,
              Cause.fail(failure),
            ),
          ),
        )

      const session = yield* sessions
        .open(peer, metadata)
        .pipe(
          Effect.catch((failure) => {
            const cause = Cause.fail(failure)
            return report(
              "realtime.open",
              cause,
            ).pipe(
              Effect.andThen(
                closeTransport(
                  "realtime.open.transport_close",
                ),
              ),
              Effect.andThen(
                Effect.fail(
                  new RealtimeHostOpenFailure({
                    cause,
                  }),
                ),
              ),
            )
          }),
        )

      let closed = false

      const removeSession: Effect.Effect<void> =
        session.close.pipe(
          Effect.catch((failure) =>
            report(
              "realtime.close",
              Cause.fail(failure),
            ),
          ),
        )

      const terminate = (
        operation: string,
        cause?: Cause.Cause<unknown>,
      ): Effect.Effect<void> =>
        Effect.suspend(() => {
          if (closed) {
            return Effect.void
          }

          // This synchronous first-wins transition makes repeated and
          // concurrent terminal events share one cleanup execution.
          closed = true

          const reportFailure =
            cause === undefined
              ? Effect.void
              : report(operation, cause)

          return reportFailure.pipe(
            Effect.andThen(
              closeTransport(
                `${operation}.transport_close`,
              ),
            ),
            Effect.andThen(removeSession),
          )
        })

      const close = terminate("realtime.close")

      const receive = (
        frame: string | Uint8Array,
      ): Effect.Effect<void> =>
        Effect.suspend(() => {
          if (closed) {
            return Effect.void
          }

          if (typeof frame === "string") {
            return terminate(
              "realtime.text_frame",
              Cause.fail(
                new RealtimeTextFrameRejected({
                  connectionId:
                    session.connectionId,
                }),
              ),
            )
          }

          return Effect.try({
            try: () =>
              ClientMessage.fromBinary(frame),
            catch: (cause) =>
              new RealtimeFrameDecodeFailure({
                cause,
                connectionId:
                  session.connectionId,
              }),
          }).pipe(
            Effect.flatMap(session.handle),
            Effect.catch((failure) =>
              terminate(
                operationForFailure(failure),
                Cause.fail(failure),
              ),
            ),
          )
        })

      return {
        connectionId: session.connectionId,
        close,
        receive,
      }
    })
