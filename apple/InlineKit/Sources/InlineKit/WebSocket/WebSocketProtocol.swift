import Foundation

// MARK: - Enums

enum ServerMessageKind: Int, Codable {
  case message = 1
  case response = 2
  case error = 3
  case ack = 4
  case connectionAck = 5
  case pong = 6
}

enum ClientMessageKind: Int, Codable {
  case connectionInit = 1
  case message = 2
  case ack = 3
  case ping = 4
}

// MARK: - Payloads

struct ErrorPayload: Codable {
  let description: String
  let errorCode: Int
}

struct ConnectionInitPayload: Codable {
  let token: String
  let userId: Int64
}

struct Method<Args: Codable & Sendable>: Codable & Sendable {
  let m: String
  let a: Args
}

// MARK: - Generic Messages

struct ServerMessage<Payload: Codable>: Codable {
  let i: String
  let t: Int
  let k: ServerMessageKind
  let p: Payload?
}

struct ClientMessage<Payload: Codable & Sendable>: Codable, Sendable {
  let i: String
  let t: Int
  let k: ClientMessageKind
  let p: Payload?
}

// MARK: - Type Aliases for Common Message Types

extension ServerMessage {
  typealias Error = ServerMessage<ErrorPayload>
  typealias Generic<T: Codable> = ServerMessage<T>
  typealias Empty = ServerMessage<EmptyPayload>
  typealias UpdateMessage = ServerMessage<ServerMessagePayload>
}

struct ServerMessagePayload: Codable {
  let updates: [Update]?
}

extension ClientMessage {
  typealias ConnectionInit = ClientMessage<ConnectionInitPayload>
}

// MARK: - Message Creation Helper

extension ServerMessage {
  static func createAck(id: String) -> ServerMessage {
    ServerMessage(
      i: id,
      t: Int(Date().timeIntervalSince1970),
      k: .ack,
      p: nil
    )
  }

  static func createPong(id: String) -> ServerMessage {
    ServerMessage(
      i: id,
      t: Int(Date().timeIntervalSince1970),
      k: .pong,
      p: nil
    )
  }

  static func createError(
    id: String,
    errorCode: Int,
    description: String
  ) -> ServerMessage<ErrorPayload> {
    ServerMessage<ErrorPayload>(
      i: id,
      t: Int(Date().timeIntervalSince1970),
      k: .error,
      p: ErrorPayload(description: description, errorCode: errorCode)
    )
  }

  static func createResponse<T: Codable>(
    id: String,
    payload: T
  ) -> ServerMessage<T> {
    ServerMessage<T>(
      i: id,
      t: Int(Date().timeIntervalSince1970),
      k: .response,
      p: payload
    )
  }

  static func createMessage<T: Codable>(
    id: String,
    payload: T
  ) -> ServerMessage<T> {
    ServerMessage<T>(
      i: id,
      t: Int(Date().timeIntervalSince1970),
      k: .message,
      p: payload
    )
  }

  static func createConnectionAck<T: Codable>(
    id: String,
    payload: T
  ) -> ServerMessage<T> {
    ServerMessage<T>(
      i: id,
      t: Int(Date().timeIntervalSince1970),
      k: .connectionAck,
      p: payload
    )
  }
}

// MARK: - Client Message Creation Helper

extension ClientMessage {
  static func connectionInit(
    token: String,
    userId: Int64
  ) -> ClientMessage<ConnectionInitPayload> {
    ClientMessage<ConnectionInitPayload>(
      i: UUID().uuidString,
      t: Int(Date().timeIntervalSince1970),
      k: .connectionInit,
      p: ConnectionInitPayload(token: token, userId: userId)
    )
  }

  static func createMessage<T: Codable & Sendable>(
    method: String,
    payload: T
  ) -> ClientMessage<Method<T>> {
    ClientMessage<Method<T>>(
      i: UUID().uuidString,
      t: Int(Date().timeIntervalSince1970),
      k: .message,
      p: Method(m: method, a: payload)
    )
  }

  static func createPing(id: String) -> ClientMessage {
    ClientMessage(
      i: UUID().uuidString,
      t: Int(Date().timeIntervalSince1970),
      k: .ping,
      p: nil
    )
  }

  static func createAck(id: String) -> ClientMessage {
    ClientMessage(
      i: id,
      t: Int(Date().timeIntervalSince1970),
      k: .ack,
      p: nil
    )
  }
}
