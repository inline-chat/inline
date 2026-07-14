import Foundation
import InlineProtocol
import RealtimeV2

public struct GetSpaceSettingsTransaction: Transaction2 {
  public var method: InlineProtocol.Method = .getSpaceSettings
  public var context: Context
  public var type: TransactionKindType = .query()

  public struct Context: Sendable, Codable { let spaceID: Int64 }
  enum CodingKeys: String, CodingKey { case context }
  public init(spaceID: Int64) { context = Context(spaceID: spaceID) }
  public func input(from context: Context) -> RpcCall.OneOf_Input? {
    .getSpaceSettings(.with { $0.spaceID = context.spaceID })
  }
  public func apply(_ result: RpcResult.OneOf_Result?) async throws(TransactionExecutionError) {
    guard case .getSpaceSettings = result else { throw .invalid }
  }
}

public struct ToggleSpaceGridTransaction: Transaction2 {
  public var method: InlineProtocol.Method = .toggleSpaceGrid
  public var context: Context
  public var type: TransactionKindType = .mutation(.init(transient: true, retryAfterAck: false))

  public struct Context: Sendable, Codable { let spaceID: Int64; let enabled: Bool }
  enum CodingKeys: String, CodingKey { case context }
  public init(spaceID: Int64, enabled: Bool) { context = Context(spaceID: spaceID, enabled: enabled) }
  public func input(from context: Context) -> RpcCall.OneOf_Input? {
    .toggleSpaceGrid(.with { $0.spaceID = context.spaceID; $0.enabled = context.enabled })
  }
  public func apply(_ result: RpcResult.OneOf_Result?) async throws(TransactionExecutionError) {
    guard case .toggleSpaceGrid = result else { throw .invalid }
  }
}

public struct GetGridTransaction: Transaction2 {
  public var method: InlineProtocol.Method = .getGrid
  public var context: Context
  public var type: TransactionKindType = .query()

  public struct Context: Sendable, Codable { let spaceID: Int64 }
  enum CodingKeys: String, CodingKey { case context }
  public init(spaceID: Int64) { context = Context(spaceID: spaceID) }
  public func input(from context: Context) -> RpcCall.OneOf_Input? {
    .getGrid(.with { $0.spaceID = context.spaceID })
  }
  public func apply(_ result: RpcResult.OneOf_Result?) async throws(TransactionExecutionError) {
    guard case .getGrid = result else { throw .invalid }
  }
}

public struct GetGridHomeTransaction: Transaction2 {
  public var method: InlineProtocol.Method = .getGridHome
  public var context = Context()
  public var type: TransactionKindType = .query()

  public struct Context: Sendable, Codable {}
  enum CodingKeys: String, CodingKey { case context }
  public init() {}
  public func input(from _: Context) -> RpcCall.OneOf_Input? { .getGridHome(.init()) }
  public func apply(_ result: RpcResult.OneOf_Result?) async throws(TransactionExecutionError) {
    guard case .getGridHome = result else { throw .invalid }
  }
}

public struct CreateGridRoomTransaction: Transaction2 {
  public var method: InlineProtocol.Method = .createGridRoom
  public var context: Context
  public var type: TransactionKindType = .mutation(.init(transient: true, retryAfterAck: false))

  public struct Context: Sendable, Codable { let spaceID: Int64 }
  enum CodingKeys: String, CodingKey { case context }
  public init(spaceID: Int64) { context = Context(spaceID: spaceID) }
  public func input(from context: Context) -> RpcCall.OneOf_Input? {
    .createGridRoom(.with { $0.spaceID = context.spaceID })
  }
  public func apply(_ result: RpcResult.OneOf_Result?) async throws(TransactionExecutionError) {
    guard case .createGridRoom = result else { throw .invalid }
  }
}

public struct JoinGridRoomTransaction: Transaction2 {
  public var method: InlineProtocol.Method = .joinGridRoom
  public var context: Context
  public var type: TransactionKindType = .mutation(.init(transient: true, retryAfterAck: false))

  public struct Context: Sendable, Codable { let roomID: Int64 }
  enum CodingKeys: String, CodingKey { case context }
  public init(roomID: Int64) { context = Context(roomID: roomID) }
  public func input(from context: Context) -> RpcCall.OneOf_Input? {
    .joinGridRoom(.with { $0.roomID = context.roomID })
  }
  public func apply(_ result: RpcResult.OneOf_Result?) async throws(TransactionExecutionError) {
    guard case .joinGridRoom = result else { throw .invalid }
  }
}

public struct LeaveGridRoomTransaction: Transaction2 {
  public var method: InlineProtocol.Method = .leaveGridRoom
  public var context: Context
  public var type: TransactionKindType = .mutation(.init(transient: true, retryAfterAck: false))

  public struct Context: Sendable, Codable { let roomID: Int64 }
  enum CodingKeys: String, CodingKey { case context }
  public init(roomID: Int64) { context = Context(roomID: roomID) }
  public func input(from context: Context) -> RpcCall.OneOf_Input? {
    .leaveGridRoom(.with { $0.expectedRoomID = context.roomID })
  }
  public func apply(_ result: RpcResult.OneOf_Result?) async throws(TransactionExecutionError) {
    guard case .leaveGridRoom = result else { throw .invalid }
  }
}

public struct SetGridRoomLockedTransaction: Transaction2 {
  public var method: InlineProtocol.Method = .setGridRoomLocked
  public var context: Context
  public var type: TransactionKindType = .mutation(.init(transient: true, retryAfterAck: false))

  public struct Context: Sendable, Codable { let roomID: Int64; let locked: Bool }
  enum CodingKeys: String, CodingKey { case context }
  public init(roomID: Int64, locked: Bool) { context = Context(roomID: roomID, locked: locked) }
  public func input(from context: Context) -> RpcCall.OneOf_Input? {
    .setGridRoomLocked(.with { $0.roomID = context.roomID; $0.locked = context.locked })
  }
  public func apply(_ result: RpcResult.OneOf_Result?) async throws(TransactionExecutionError) {
    guard case .setGridRoomLocked = result else { throw .invalid }
  }
}

public struct SetGridRoomTitleTransaction: Transaction2 {
  public var method: InlineProtocol.Method = .setGridRoomTitle
  public var context: Context
  public var type: TransactionKindType = .mutation(.init(transient: true, retryAfterAck: false))

  public struct Context: Sendable, Codable { let roomID: Int64; let title: String }
  enum CodingKeys: String, CodingKey { case context }
  public init(roomID: Int64, title: String) { context = Context(roomID: roomID, title: title) }
  public func input(from context: Context) -> RpcCall.OneOf_Input? {
    .setGridRoomTitle(.with { $0.roomID = context.roomID; $0.title = context.title })
  }
  public func apply(_ result: RpcResult.OneOf_Result?) async throws(TransactionExecutionError) {
    guard case .setGridRoomTitle = result else { throw .invalid }
  }
}

public struct DeleteGridRoomTransaction: Transaction2 {
  public var method: InlineProtocol.Method = .deleteGridRoom
  public var context: Context
  public var type: TransactionKindType = .mutation(.init(transient: true, retryAfterAck: false))

  public struct Context: Sendable, Codable { let roomID: Int64 }
  enum CodingKeys: String, CodingKey { case context }
  public init(roomID: Int64) { context = Context(roomID: roomID) }
  public func input(from context: Context) -> RpcCall.OneOf_Input? {
    .deleteGridRoom(.with { $0.roomID = context.roomID })
  }
  public func apply(_ result: RpcResult.OneOf_Result?) async throws(TransactionExecutionError) {
    guard case .deleteGridRoom = result else { throw .invalid }
  }
}

public struct PrepareGridConnectionTransaction: Transaction2 {
  public var method: InlineProtocol.Method = .prepareGridConnection
  public var context: Context
  public var type: TransactionKindType = .query()

  public struct Context: Sendable, Codable { let roomID: Int64; let generation: Int32 }
  enum CodingKeys: String, CodingKey { case context }
  public init(roomID: Int64, generation: Int32) {
    context = Context(roomID: roomID, generation: generation)
  }
  public func input(from context: Context) -> RpcCall.OneOf_Input? {
    .prepareGridConnection(.with { $0.roomID = context.roomID; $0.generation = context.generation })
  }
  public func apply(_ result: RpcResult.OneOf_Result?) async throws(TransactionExecutionError) {
    guard case .prepareGridConnection = result else { throw .invalid }
  }
}

public struct SetGridAvatarMicTransaction: Transaction2 {
  public var method: InlineProtocol.Method = .setGridAvatarMicrophoneEnabled
  public var context: Context
  public var type: TransactionKindType = .mutation(.init(transient: true, retryAfterAck: false))

  public struct Context: Sendable, Codable { let roomID: Int64; let enabled: Bool }
  enum CodingKeys: String, CodingKey { case context }
  public init(roomID: Int64, enabled: Bool) { context = Context(roomID: roomID, enabled: enabled) }
  public func input(from context: Context) -> RpcCall.OneOf_Input? {
    .setGridAvatarMicrophoneEnabled(.with {
      $0.expectedRoomID = context.roomID
      $0.enabled = context.enabled
    })
  }
  public func apply(_ result: RpcResult.OneOf_Result?) async throws(TransactionExecutionError) {
    guard case .setGridAvatarMicrophoneEnabled = result else { throw .invalid }
  }
}

public extension Transaction2 where Self == GetSpaceSettingsTransaction {
  static func getSpaceSettings(spaceID: Int64) -> Self { .init(spaceID: spaceID) }
}

public extension Transaction2 where Self == ToggleSpaceGridTransaction {
  static func toggleSpaceGrid(spaceID: Int64, enabled: Bool) -> Self { .init(spaceID: spaceID, enabled: enabled) }
}

public extension Transaction2 where Self == GetGridTransaction {
  static func getGrid(spaceID: Int64) -> Self { .init(spaceID: spaceID) }
}

public extension Transaction2 where Self == GetGridHomeTransaction {
  static func getGridHome() -> Self { .init() }
}

public extension Transaction2 where Self == CreateGridRoomTransaction {
  static func createGridRoom(spaceID: Int64) -> Self { .init(spaceID: spaceID) }
}

public extension Transaction2 where Self == JoinGridRoomTransaction {
  static func joinGridRoom(roomID: Int64) -> Self { .init(roomID: roomID) }
}

public extension Transaction2 where Self == LeaveGridRoomTransaction {
  static func leaveGridRoom(roomID: Int64) -> Self { .init(roomID: roomID) }
}

public extension Transaction2 where Self == SetGridRoomLockedTransaction {
  static func setGridRoomLocked(roomID: Int64, locked: Bool) -> Self { .init(roomID: roomID, locked: locked) }
}

public extension Transaction2 where Self == SetGridRoomTitleTransaction {
  static func setGridRoomTitle(roomID: Int64, title: String) -> Self { .init(roomID: roomID, title: title) }
}

public extension Transaction2 where Self == DeleteGridRoomTransaction {
  static func deleteGridRoom(roomID: Int64) -> Self { .init(roomID: roomID) }
}

public extension Transaction2 where Self == PrepareGridConnectionTransaction {
  static func prepareGridConnection(roomID: Int64, generation: Int32) -> Self {
    .init(roomID: roomID, generation: generation)
  }
}

public extension Transaction2 where Self == SetGridAvatarMicTransaction {
  static func setGridAvatarMicrophoneEnabled(roomID: Int64, enabled: Bool) -> Self {
    .init(roomID: roomID, enabled: enabled)
  }
}
