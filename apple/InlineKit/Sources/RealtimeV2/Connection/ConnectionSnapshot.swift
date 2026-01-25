import Foundation

public struct ConnectionSnapshot: Sendable, Equatable {
  public var state: ConnectionState
  public var reason: ConnectionReason
  public var attempt: UInt32
  public var since: Date
  public var sessionID: UInt64
  public var constraints: ConnectionConstraints
  public var lastErrorDescription: String?

  public init(
    state: ConnectionState,
    reason: ConnectionReason,
    attempt: UInt32,
    since: Date,
    sessionID: UInt64,
    constraints: ConnectionConstraints,
    lastErrorDescription: String?
  ) {
    self.state = state
    self.reason = reason
    self.attempt = attempt
    self.since = since
    self.sessionID = sessionID
    self.constraints = constraints
    self.lastErrorDescription = lastErrorDescription
  }
}
