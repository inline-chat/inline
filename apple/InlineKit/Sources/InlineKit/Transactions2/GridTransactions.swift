import Foundation
import InlineProtocol
import RealtimeV2

public struct GetSpaceSettingsTransaction: Transaction2 {
  public var method: InlineProtocol.Method = .getSpaceSettings
  public var context: Context
  public var type: TransactionKindType = .query()

  public struct Context: Sendable, Codable { let spaceID: Int64 }
  enum CodingKeys: String, CodingKey { case context }
  public init(spaceID: Int64) {
    context = Context(spaceID: spaceID)
  }

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
  public var type: TransactionKindType = .mutation(.init(transient: true))

  public struct Context: Sendable, Codable { let spaceID: Int64
    let enabled: Bool
  }

  enum CodingKeys: String, CodingKey { case context }
  public init(spaceID: Int64, enabled: Bool) {
    context = Context(spaceID: spaceID, enabled: enabled)
  }

  public func input(from context: Context) -> RpcCall.OneOf_Input? {
    .toggleSpaceGrid(.with { $0.spaceID = context.spaceID
      $0.enabled = context.enabled
    })
  }

  public func apply(_ result: RpcResult.OneOf_Result?) async throws(TransactionExecutionError) {
    guard case .toggleSpaceGrid = result else { throw .invalid }
  }
}

public struct GetGridTransaction: Transaction2 {
  public var method: InlineProtocol.Method = .getGrid
  public var context: Context
  public var type: TransactionKindType = .ephemeral()
  public var ephemeralCoalescingKey: String? {
    "space:\(context.spaceID):request:\(context.requestID)"
  }

  public struct Context: Sendable, Codable { let spaceID: Int64
    let expectedMembershipID: String?
    let requestID: UUID
  }

  enum CodingKeys: String, CodingKey { case context }
  public init(spaceID: Int64, expectedMembershipID: String? = nil) {
    context = Context(spaceID: spaceID, expectedMembershipID: expectedMembershipID, requestID: UUID())
  }

  public func input(from context: Context) -> RpcCall.OneOf_Input? {
    .getGrid(.with {
      $0.spaceID = context.spaceID
      if let membershipID = context.expectedMembershipID {
        $0.expectedMembershipID = membershipID
      }
    })
  }

  public func apply(_ result: RpcResult.OneOf_Result?) async throws(TransactionExecutionError) {
    guard case .getGrid = result else { throw .invalid }
  }
}

public struct GetGridHomeTransaction: Transaction2 {
  public var method: InlineProtocol.Method = .getGridHome
  public var context = Context(requestID: UUID())
  public var type: TransactionKindType = .ephemeral()
  public var ephemeralCoalescingKey: String? {
    "home:\(context.requestID)"
  }

  public struct Context: Sendable, Codable { let requestID: UUID }
  enum CodingKeys: String, CodingKey { case context }
  public init() {}
  public func input(from _: Context) -> RpcCall.OneOf_Input? {
    .getGridHome(.init())
  }

  public func apply(_ result: RpcResult.OneOf_Result?) async throws(TransactionExecutionError) {
    guard case .getGridHome = result else { throw .invalid }
  }
}

public struct CreateGridRoomTransaction: Transaction2 {
  public var method: InlineProtocol.Method = .createGridRoom
  public var context: Context
  public var type: TransactionKindType = .mutation(.init(transient: true))

  public struct Context: Sendable, Codable { let spaceID: Int64
    let microphoneEnabled: Bool
    let expectedMembershipID: String?
  }

  enum CodingKeys: String, CodingKey { case context }
  public init(spaceID: Int64, microphoneEnabled: Bool, expectedMembershipID: String? = nil) {
    context = Context(
      spaceID: spaceID,
      microphoneEnabled: microphoneEnabled,
      expectedMembershipID: expectedMembershipID
    )
  }

  public func input(from context: Context) -> RpcCall.OneOf_Input? {
    .createGridRoom(.with {
      $0.spaceID = context.spaceID
      $0.microphoneEnabled = context.microphoneEnabled
      if let membershipID = context.expectedMembershipID {
        $0.expectedMembershipID = membershipID
      }
    })
  }

  public func apply(_ result: RpcResult.OneOf_Result?) async throws(TransactionExecutionError) {
    guard case .createGridRoom = result else { throw .invalid }
  }
}

public struct JoinGridRoomTransaction: Transaction2 {
  public var method: InlineProtocol.Method = .joinGridRoom
  public var context: Context
  public var type: TransactionKindType = .mutation(.init(transient: true))

  public struct Context: Sendable, Codable { let roomID: Int64
    let microphoneEnabled: Bool
    let expectedMembershipID: String?
  }

  enum CodingKeys: String, CodingKey { case context }
  public init(roomID: Int64, microphoneEnabled: Bool, expectedMembershipID: String? = nil) {
    context = Context(roomID: roomID, microphoneEnabled: microphoneEnabled, expectedMembershipID: expectedMembershipID)
  }

  public func input(from context: Context) -> RpcCall.OneOf_Input? {
    .joinGridRoom(.with {
      $0.roomID = context.roomID
      $0.microphoneEnabled = context.microphoneEnabled
      if let membershipID = context.expectedMembershipID {
        $0.expectedMembershipID = membershipID
      }
    })
  }

  public func apply(_ result: RpcResult.OneOf_Result?) async throws(TransactionExecutionError) {
    guard case .joinGridRoom = result else { throw .invalid }
  }
}

public struct LeaveGridRoomTransaction: Transaction2 {
  public var method: InlineProtocol.Method = .leaveGridRoom
  public var context: Context
  public var type: TransactionKindType = .mutation(.init(transient: true))

  public struct Context: Sendable, Codable { let roomID: Int64
    let expectedMembershipID: String?
  }

  enum CodingKeys: String, CodingKey { case context }
  public init(roomID: Int64, expectedMembershipID: String? = nil) {
    context = Context(roomID: roomID, expectedMembershipID: expectedMembershipID)
  }

  public func input(from context: Context) -> RpcCall.OneOf_Input? {
    .leaveGridRoom(.with {
      $0.expectedRoomID = context.roomID
      if let membershipID = context.expectedMembershipID {
        $0.expectedMembershipID = membershipID
      }
    })
  }

  public func apply(_ result: RpcResult.OneOf_Result?) async throws(TransactionExecutionError) {
    guard case .leaveGridRoom = result else { throw .invalid }
  }
}

public struct SetGridRoomLockedTransaction: Transaction2 {
  public var method: InlineProtocol.Method = .setGridRoomLocked
  public var context: Context
  public var type: TransactionKindType = .mutation(.init(transient: true))

  public struct Context: Sendable, Codable { let roomID: Int64
    let locked: Bool
  }

  enum CodingKeys: String, CodingKey { case context }
  public init(roomID: Int64, locked: Bool) {
    context = Context(roomID: roomID, locked: locked)
  }

  public func input(from context: Context) -> RpcCall.OneOf_Input? {
    .setGridRoomLocked(.with { $0.roomID = context.roomID
      $0.locked = context.locked
    })
  }

  public func apply(_ result: RpcResult.OneOf_Result?) async throws(TransactionExecutionError) {
    guard case .setGridRoomLocked = result else { throw .invalid }
  }
}

public struct SetGridRoomTitleTransaction: Transaction2 {
  public var method: InlineProtocol.Method = .setGridRoomTitle
  public var context: Context
  public var type: TransactionKindType = .mutation(.init(transient: true))

  public struct Context: Sendable, Codable { let roomID: Int64
    let title: String
  }

  enum CodingKeys: String, CodingKey { case context }
  public init(roomID: Int64, title: String) {
    context = Context(roomID: roomID, title: title)
  }

  public func input(from context: Context) -> RpcCall.OneOf_Input? {
    .setGridRoomTitle(.with { $0.roomID = context.roomID
      $0.title = context.title
    })
  }

  public func apply(_ result: RpcResult.OneOf_Result?) async throws(TransactionExecutionError) {
    guard case .setGridRoomTitle = result else { throw .invalid }
  }
}

public struct DeleteGridRoomTransaction: Transaction2 {
  public var method: InlineProtocol.Method = .deleteGridRoom
  public var context: Context
  public var type: TransactionKindType = .mutation(.init(transient: true))

  public struct Context: Sendable, Codable { let roomID: Int64 }
  enum CodingKeys: String, CodingKey { case context }
  public init(roomID: Int64) {
    context = Context(roomID: roomID)
  }

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
  public var type: TransactionKindType = .ephemeral()
  public var ephemeralCoalescingKey: String? {
    "room:\(context.roomID):generation:\(context.generation):membership:\(context.expectedMembershipID ?? "legacy")"
  }

  public struct Context: Sendable, Codable { let roomID: Int64
    let generation: Int32
    let expectedMembershipID: String?
  }

  enum CodingKeys: String, CodingKey { case context }
  public init(roomID: Int64, generation: Int32, expectedMembershipID: String? = nil) {
    context = Context(roomID: roomID, generation: generation, expectedMembershipID: expectedMembershipID)
  }

  public func input(from context: Context) -> RpcCall.OneOf_Input? {
    .prepareGridConnection(.with {
      $0.roomID = context.roomID
      $0.generation = context.generation
      if let membershipID = context.expectedMembershipID {
        $0.expectedMembershipID = membershipID
      }
    })
  }

  public func apply(_ result: RpcResult.OneOf_Result?) async throws(TransactionExecutionError) {
    guard case .prepareGridConnection = result else { throw .invalid }
  }
}

public struct SetGridAvatarMicTransaction: Transaction2 {
  public var method: InlineProtocol.Method = .setGridAvatarMicrophoneEnabled
  public var context: Context
  public var type: TransactionKindType = .mutation(.init(transient: true))

  public struct Context: Sendable, Codable { let roomID: Int64
    let enabled: Bool
    let expectedMembershipID: String?
  }

  enum CodingKeys: String, CodingKey { case context }
  public init(roomID: Int64, enabled: Bool, expectedMembershipID: String? = nil) {
    context = Context(roomID: roomID, enabled: enabled, expectedMembershipID: expectedMembershipID)
  }

  public func input(from context: Context) -> RpcCall.OneOf_Input? {
    .setGridAvatarMicrophoneEnabled(.with {
      $0.expectedRoomID = context.roomID
      $0.enabled = context.enabled
      if let membershipID = context.expectedMembershipID {
        $0.expectedMembershipID = membershipID
      }
    })
  }

  public func apply(_ result: RpcResult.OneOf_Result?) async throws(TransactionExecutionError) {
    guard case .setGridAvatarMicrophoneEnabled = result else { throw .invalid }
  }
}

public extension Transaction2 where Self == GetSpaceSettingsTransaction {
  static func getSpaceSettings(spaceID: Int64) -> Self {
    .init(spaceID: spaceID)
  }
}

public extension Transaction2 where Self == ToggleSpaceGridTransaction {
  static func toggleSpaceGrid(spaceID: Int64, enabled: Bool) -> Self {
    .init(spaceID: spaceID, enabled: enabled)
  }
}

public extension Transaction2 where Self == GetGridTransaction {
  static func getGrid(spaceID: Int64, expectedMembershipID: String? = nil) -> Self {
    .init(spaceID: spaceID, expectedMembershipID: expectedMembershipID)
  }
}

public extension Transaction2 where Self == GetGridHomeTransaction {
  static func getGridHome() -> Self {
    .init()
  }
}

public extension Transaction2 where Self == CreateGridRoomTransaction {
  static func createGridRoom(spaceID: Int64, microphoneEnabled: Bool, expectedMembershipID: String? = nil) -> Self {
    .init(spaceID: spaceID, microphoneEnabled: microphoneEnabled, expectedMembershipID: expectedMembershipID)
  }
}

public extension Transaction2 where Self == JoinGridRoomTransaction {
  static func joinGridRoom(roomID: Int64, microphoneEnabled: Bool, expectedMembershipID: String? = nil) -> Self {
    .init(roomID: roomID, microphoneEnabled: microphoneEnabled, expectedMembershipID: expectedMembershipID)
  }
}

public extension Transaction2 where Self == LeaveGridRoomTransaction {
  static func leaveGridRoom(roomID: Int64, expectedMembershipID: String? = nil) -> Self {
    .init(roomID: roomID, expectedMembershipID: expectedMembershipID)
  }
}

public extension Transaction2 where Self == SetGridRoomLockedTransaction {
  static func setGridRoomLocked(roomID: Int64, locked: Bool) -> Self {
    .init(roomID: roomID, locked: locked)
  }
}

public extension Transaction2 where Self == SetGridRoomTitleTransaction {
  static func setGridRoomTitle(roomID: Int64, title: String) -> Self {
    .init(roomID: roomID, title: title)
  }
}

public extension Transaction2 where Self == DeleteGridRoomTransaction {
  static func deleteGridRoom(roomID: Int64) -> Self {
    .init(roomID: roomID)
  }
}

public extension Transaction2 where Self == PrepareGridConnectionTransaction {
  static func prepareGridConnection(roomID: Int64, generation: Int32, expectedMembershipID: String? = nil) -> Self {
    .init(roomID: roomID, generation: generation, expectedMembershipID: expectedMembershipID)
  }
}

public extension Transaction2 where Self == SetGridAvatarMicTransaction {
  static func setGridAvatarMicrophoneEnabled(
    roomID: Int64,
    enabled: Bool,
    expectedMembershipID: String? = nil
  ) -> Self {
    .init(roomID: roomID, enabled: enabled, expectedMembershipID: expectedMembershipID)
  }
}

/// Explicit ownership claim. A retry must reuse the caller-observed fence;
/// a newer self snapshot is display evidence, never permission to retry a claim.
public struct MoveGridCallHereTransaction: Transaction2 {
  public var method: InlineProtocol.Method = .moveGridCallHere
  public var context: Context
  public var type: TransactionKindType = .mutation(.init(transient: true))

  public struct Context: Sendable, Codable {
    let callID: String
    let expectedMembershipID: String
  }

  enum CodingKeys: String, CodingKey { case context }
  public init(callID: String, expectedMembershipID: String) {
    context = Context(callID: callID, expectedMembershipID: expectedMembershipID)
  }

  public func input(from context: Context) -> RpcCall.OneOf_Input? {
    .moveGridCallHere(.with {
      $0.callID = context.callID
      $0.expectedMembershipID = context.expectedMembershipID
    })
  }

  public func apply(_ result: RpcResult.OneOf_Result?) async throws(TransactionExecutionError) {
    guard case .moveGridCallHere = result else { throw .invalid }
  }
}

public extension Transaction2 where Self == MoveGridCallHereTransaction {
  static func moveGridCallHere(callID: String, expectedMembershipID: String) -> Self {
    .init(callID: callID, expectedMembershipID: expectedMembershipID)
  }
}

public struct OpenGridThreadTransaction: Transaction2 {
  public var method: InlineProtocol.Method = .openGridThread
  public var context: Context
  public var type: TransactionKindType = .mutation(.init(transient: true))
  public var reconnectReplayPolicy: TransactionReconnectPolicy? {
    .neverReplay
  }

  public struct Context: Sendable, Codable {
    let roomID: Int64
    let membershipID: String
  }

  enum CodingKeys: String, CodingKey { case context }
  public init(roomID: Int64, membershipID: String) {
    context = Context(roomID: roomID, membershipID: membershipID)
  }

  public func input(from context: Context) -> RpcCall.OneOf_Input? {
    .openGridThread(.with {
      $0.roomID = context.roomID
      $0.expectedMembershipID = context.membershipID
    })
  }

  public func apply(_ result: RpcResult.OneOf_Result?) async throws(TransactionExecutionError) {
    guard case let .openGridThread(response) = result else { throw .invalid }
    await Api.realtime.applyUpdatesAndWait(response.updates)
  }
}

public struct SetGridTranscriptionTransaction: Transaction2 {
  public var method: InlineProtocol.Method = .setGridTranscription
  public var context: GridTranscriptionRequest
  public var type: TransactionKindType = .mutation(.init(transient: true))
  public var reconnectReplayPolicy: TransactionReconnectPolicy? {
    .neverReplay
  }

  enum CodingKeys: String, CodingKey { case context }
  public init(request: GridTranscriptionRequest) {
    context = request
  }

  public func input(from context: GridTranscriptionRequest) -> RpcCall.OneOf_Input? {
    .setGridTranscription(context.input)
  }

  public func apply(_ result: RpcResult.OneOf_Result?) async throws(TransactionExecutionError) {
    guard case let .setGridTranscription(response) = result else { throw .invalid }
    await Api.realtime.applyUpdatesAndWait(response.updates)
  }
}

public struct ListGridTranscriptsTransaction: Transaction2 {
  public var method: InlineProtocol.Method = .listGridTranscripts
  public var context: Context
  public var type: TransactionKindType = .ephemeral()
  public var ephemeralCoalescingKey: String? {
    "room:\(context.roomID)"
  }

  public struct Context: Sendable, Codable { let roomID: Int64 }
  enum CodingKeys: String, CodingKey { case context }
  public init(roomID: Int64) {
    context = Context(roomID: roomID)
  }

  public func input(from context: Context) -> RpcCall.OneOf_Input? {
    .listGridTranscripts(.with { $0.roomID = context.roomID })
  }

  public func apply(_ result: RpcResult.OneOf_Result?) async throws(TransactionExecutionError) {
    guard case .listGridTranscripts = result else { throw .invalid }
  }
}

public extension Transaction2 where Self == OpenGridThreadTransaction {
  static func openGridThread(roomID: Int64, membershipID: String) -> Self {
    .init(
      roomID: roomID,
      membershipID: membershipID
    )
  }
}

public extension Transaction2 where Self == SetGridTranscriptionTransaction {
  static func setGridTranscription(request: GridTranscriptionRequest) -> Self {
    .init(request: request)
  }
}

public extension Transaction2 where Self == ListGridTranscriptsTransaction {
  static func listGridTranscripts(roomID: Int64) -> Self {
    .init(roomID: roomID)
  }
}
