import Auth
import InlineKit
import InlineProtocol
import RealtimeV2

struct GridRoomMutationResult: Sendable {
  let grids: [InlineProtocol.Grid]
  let credentials: GridConnectionCredentials?
  let currentCall: GridCurrentCall?
  var moved = true
}

struct GridReadResult {
  let grid: InlineProtocol.Grid
  let currentCall: GridCurrentCall?
}

struct GridHomeResult {
  let spaces: [GridHomeSpace]
  let currentCall: GridCurrentCall?
  let callTransferEnabled: Bool
}

/// The typed server boundary for Grid rooms.
///
/// Product state and optimistic UI never inspect RPC oneofs directly. Keeping
/// validation here makes every room operation return one predictable shape.
@MainActor
final class GridRoomAPI {
  typealias Send = @MainActor @Sendable (any Transaction2, AuthAccountMutationToken) async throws -> RpcResult
    .OneOf_Result?
  private let sendTransaction: Send
  private let auth: AuthHandle

  init(realtime: RealtimeV2, auth: AuthHandle, send: Send? = nil) {
    sendTransaction = send ?? { transaction, token in
      try await realtime.send(transaction, expectedAccount: token)
    }
    self.auth = auth
  }

  func settings(spaceID: Int64) async throws -> SpaceSettings {
    let result = try await send(.getSpaceSettings(spaceID: spaceID))
    guard case let .getSpaceSettings(response)? = result, response.hasSettings else {
      throw GridRoomAPIError.invalidResponse
    }
    return response.settings
  }

  func setEnabled(_ enabled: Bool, spaceID: Int64) async throws -> SpaceSettings {
    let result = try await send(.toggleSpaceGrid(spaceID: spaceID, enabled: enabled))
    guard case let .toggleSpaceGrid(response)? = result, response.hasSettings else {
      throw GridRoomAPIError.invalidResponse
    }
    return response.settings
  }

  func grid(
    spaceID: Int64,
    expectedMembershipID: String? = nil,
    accountToken: AuthAccountMutationToken
  ) async throws -> GridReadResult {
    let result = try await send(
      .getGrid(spaceID: spaceID, expectedMembershipID: expectedMembershipID),
      accountToken: accountToken
    )
    guard case let .getGrid(response)? = result, response.hasGrid else {
      throw GridRoomAPIError.invalidResponse
    }
    return GridReadResult(grid: response.grid, currentCall: response.hasCurrentCall ? response.currentCall : nil)
  }

  func home(accountToken: AuthAccountMutationToken) async throws -> GridHomeResult {
    let result = try await send(.getGridHome(), accountToken: accountToken)
    guard case let .getGridHome(response)? = result else {
      throw GridRoomAPIError.invalidResponse
    }
    return GridHomeResult(
      spaces: response.spaces,
      currentCall: response.hasCurrentCall ? response.currentCall : nil,
      callTransferEnabled: response.callTransferEnabled
    )
  }

  func openRoomThread(roomID: Int64, membershipID: String) async throws -> Int64 {
    let result = try await send(.openGridThread(roomID: roomID, membershipID: membershipID))
    guard case let .openGridThread(response)? = result, response.chatID > 0 else {
      throw GridRoomAPIError.invalidResponse
    }
    return response.chatID
  }

  func setTranscription(request: GridTranscriptionRequest) async throws -> InlineProtocol.Grid {
    let result = try await send(.setGridTranscription(request: request))
    guard case let .setGridTranscription(response)? = result, response.hasGrid else {
      throw GridRoomAPIError.invalidResponse
    }
    return response.grid
  }

  func listTranscripts(roomID: Int64) async throws -> [GridTranscriptDestinationInfo] {
    let result = try await send(.listGridTranscripts(roomID: roomID))
    guard case let .listGridTranscripts(response)? = result else {
      throw GridRoomAPIError.invalidResponse
    }
    return Array(response.transcripts.prefix(20))
  }

  func createRoom(
    spaceID: Int64,
    microphoneEnabled: Bool,
    expectedMembershipID: String,
    accountToken: AuthAccountMutationToken
  ) async throws -> GridRoomMutationResult {
    let result = try await send(
      .createGridRoom(
        spaceID: spaceID,
        microphoneEnabled: microphoneEnabled,
        expectedMembershipID: expectedMembershipID
      ),
      accountToken: accountToken
    )
    guard case let .createGridRoom(response)? = result else {
      throw GridRoomAPIError.invalidResponse
    }
    return GridRoomMutationResult(
      grids: response.grids,
      credentials: response.hasConnection ? response.connection : nil,
      currentCall: response.hasCurrentCall ? response.currentCall : nil
    )
  }

  func joinRoom(
    roomID: Int64,
    microphoneEnabled: Bool,
    expectedMembershipID: String,
    accountToken: AuthAccountMutationToken
  ) async throws -> GridRoomMutationResult {
    let result = try await send(
      .joinGridRoom(roomID: roomID, microphoneEnabled: microphoneEnabled, expectedMembershipID: expectedMembershipID),
      accountToken: accountToken
    )
    guard case let .joinGridRoom(response)? = result else {
      throw GridRoomAPIError.invalidResponse
    }
    return GridRoomMutationResult(
      grids: response.grids,
      credentials: response.hasConnection ? response.connection : nil,
      currentCall: response.hasCurrentCall ? response.currentCall : nil
    )
  }

  func leaveRoom(
    roomID: Int64,
    expectedMembershipID: String,
    accountToken: AuthAccountMutationToken
  ) async throws -> GridRoomMutationResult {
    let result = try await send(
      .leaveGridRoom(roomID: roomID, expectedMembershipID: expectedMembershipID),
      accountToken: accountToken
    )
    guard case let .leaveGridRoom(response)? = result else {
      throw GridRoomAPIError.invalidResponse
    }
    return GridRoomMutationResult(
      grids: response.grids,
      credentials: nil,
      currentCall: response.hasCurrentCall ? response.currentCall : nil
    )
  }

  func moveCallHere(
    callID: String,
    expectedMembershipID: String,
    accountToken: AuthAccountMutationToken
  ) async throws -> GridRoomMutationResult {
    let result = try await send(
      .moveGridCallHere(callID: callID, expectedMembershipID: expectedMembershipID),
      accountToken: accountToken
    )
    guard case let .moveGridCallHere(response)? = result else { throw GridRoomAPIError.invalidResponse }
    return GridRoomMutationResult(
      grids: response.grids,
      credentials: response.hasConnection ? response.connection : nil,
      currentCall: response.hasCurrentCall ? response.currentCall : nil,
      moved: response.moved
    )
  }

  func setLocked(_ locked: Bool, roomID: Int64) async throws -> InlineProtocol.Grid {
    let result = try await send(.setGridRoomLocked(roomID: roomID, locked: locked))
    guard case let .setGridRoomLocked(response)? = result, response.hasGrid else {
      throw GridRoomAPIError.invalidResponse
    }
    return response.grid
  }

  func setTitle(_ title: String, roomID: Int64) async throws -> InlineProtocol.Grid {
    let result = try await send(.setGridRoomTitle(roomID: roomID, title: title))
    guard case let .setGridRoomTitle(response)? = result, response.hasGrid else {
      throw GridRoomAPIError.invalidResponse
    }
    return response.grid
  }

  func deleteRoom(roomID: Int64) async throws -> InlineProtocol.Grid {
    let result = try await send(.deleteGridRoom(roomID: roomID))
    guard case let .deleteGridRoom(response)? = result, response.hasGrid else {
      throw GridRoomAPIError.invalidResponse
    }
    return response.grid
  }

  func prepareConnection(
    roomID: Int64,
    generation: Int32,
    expectedMembershipID: String,
    accountToken: AuthAccountMutationToken
  ) async throws -> GridConnectionCredentials? {
    let result = try await send(
      .prepareGridConnection(roomID: roomID, generation: generation, expectedMembershipID: expectedMembershipID),
      accountToken: accountToken
    )
    guard case let .prepareGridConnection(response)? = result else {
      throw GridRoomAPIError.invalidResponse
    }
    return response.hasConnection ? response.connection : nil
  }

  func setMicrophoneEnabled(
    _ enabled: Bool,
    roomID: Int64,
    expectedMembershipID: String,
    accountToken: AuthAccountMutationToken
  ) async throws {
    let result = try await send(
      .setGridAvatarMicrophoneEnabled(roomID: roomID, enabled: enabled, expectedMembershipID: expectedMembershipID),
      accountToken: accountToken
    )
    guard case .setGridAvatarMicrophoneEnabled? = result else {
      throw GridRoomAPIError.invalidResponse
    }
  }

  private func send(
    _ transaction: any Transaction2,
    accountToken: AuthAccountMutationToken? = nil
  ) async throws -> RpcResult.OneOf_Result? {
    let token = try accountToken ?? auth.beginAccountMutation()
    return try await sendTransaction(transaction, token)
  }
}

enum GridRoomAPIError: Error {
  case invalidResponse
}
