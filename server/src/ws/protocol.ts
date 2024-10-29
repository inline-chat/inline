import { t, type Static } from "elysia"

// Methods
import { Input as GetMeInput } from "@in/server/methods/getMe"
import { nanoid } from "nanoid/non-secure"

const Methods = t.Union([
  t.Object({
    /** Method name */
    m: t.Literal("getMe"),
    /** Args */
    a: GetMeInput,
  }),
])

export const enum ServerMessageKind {
  Message = 1,
  // Replies
  Response = 2,
  Error = 3,
  // Acknowledgments
  Ack = 4,
  ConnectionAck = 5,
  Pong = 6,
}

// basic protocol
export const ServerMessage = t.Union([
  t.Object({
    /** ID, used to ack the message */
    i: t.String(),
    /** UNIX Timestamp */
    t: t.Integer(),
    /** Kind */
    k: t.Literal(ServerMessageKind.Message),
    /** Payload */
    p: t.Any(),
  }),

  // Response
  t.Object({
    /** ID, matches the client message id triggering the response */
    i: t.String(),
    /** UNIX Timestamp */
    t: t.Integer(),
    /** Kind */
    k: t.Literal(ServerMessageKind.Response),
    /** Payload */
    p: t.Any(),
  }),

  // Error
  t.Object({
    /** ID, matches the client message id triggering the error */
    i: t.String(),
    /** UNIX Timestamp */
    t: t.Integer(),
    /** Kind */
    k: t.Literal(ServerMessageKind.Error),
    /** Payload */
    p: t.Object({
      description: t.String(),
      errorCode: t.Integer(),
    }),
  }),

  // Acknowledgment (empty payload) for a message
  t.Object({
    i: t.String(),
    /** UNIX Timestamp */
    t: t.Integer(),
    /** Kind */
    k: t.Literal(ServerMessageKind.Ack),
  }),

  // Connection Acknowledgment
  t.Object({
    i: t.String(),
    /** UNIX Timestamp */
    t: t.Integer(),
    /** Kind */
    k: t.Literal(ServerMessageKind.ConnectionAck),
    /** Payload, contains information about the session */
    p: t.Any(),
  }),

  // Ping
  t.Object({
    i: t.String(),
    /** UNIX Timestamp */
    t: t.Integer(),
    /** Kind */
    k: t.Literal(ServerMessageKind.Pong),
  }),
])

export type ServerMessageType = Static<typeof ServerMessage>

export const enum ClientMessageKind {
  ConnectionInit = 1, // used for connection initialization with auth
  Message = 2, // used for method calls
  Ack = 3, // used for server "message" type
  Ping = 4, // used for ping pong
}

// method?: JQLMethodNames
// payload?: any
export const ClientMessage = t.Union([
  // Connection initialization
  t.Object({
    /** ID */
    i: t.String(),
    /** UNIX Timestamp */
    t: t.Integer(),
    /** Kind */
    k: t.Literal(ClientMessageKind.ConnectionInit),
    /** Payload */
    p: t.Object({
      token: t.String(),
      userId: t.Integer(),
    }),
  }),

  // Message
  t.Object({
    i: t.String(),
    t: t.Integer(),
    k: t.Literal(ClientMessageKind.Message),
    p: Methods,
  }),

  // Ping
  t.Object({
    i: t.String(),
    t: t.Integer(),
    k: t.Literal(ClientMessageKind.Ping),
  }),

  // Ack
  t.Object({
    i: t.String(),
    t: t.Integer(),
    k: t.Literal(ClientMessageKind.Ack),
  }),
])

// Convenience function
export const createMessage = (
  data:
    | {
        kind: ServerMessageKind.Ack
        id: string
      }
    | {
        kind: ServerMessageKind.Pong
        id: string
      }
    | {
        kind: ServerMessageKind.Error
        id: string
        errorCode: number
        description: string
      }
    | {
        kind: ServerMessageKind.Response
        id: string
        p: any
      }
    | {
        kind: ServerMessageKind.Message
        id: string
        p: any
      }
    | {
        kind: ServerMessageKind.ConnectionAck
        id: string
        p: {
          //...
          _?: string
        }
      },
): ServerMessageType => {
  const t = Date.now()
  switch (data.kind) {
    case ServerMessageKind.Ack:
      return {
        i: data.id,
        t,
        k: data.kind,
      }

    case ServerMessageKind.Pong:
      return {
        i: data.id,
        t,
        k: data.kind,
      }

    case ServerMessageKind.Error:
      return {
        i: data.id,
        t,
        k: data.kind,
        p: {
          description: data.description,
          errorCode: data.errorCode,
        },
      }

    case ServerMessageKind.Response:
      return {
        i: data.id,
        t,
        k: data.kind,
        p: data.p,
      }

    case ServerMessageKind.Message:
      return {
        i: data.id,
        t,
        k: data.kind,
        p: data.p,
      }

    case ServerMessageKind.ConnectionAck:
      return {
        i: data.id,
        t,
        k: data.kind,
        p: data.p,
      }
  }
}
