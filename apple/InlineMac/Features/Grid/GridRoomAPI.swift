import InlineKit
import InlineProtocol
import RealtimeV2

struct GridRoomMutationResult: Sendable {
  let grids: [InlineProtocol.Grid]
  let credentials: GridConnectionCredentials?
}

/// The typed server boundary for Grid rooms.
///
/// Product state and optimistic UI never inspect RPC oneofs directly. Keeping
/// validation here makes every room operation return one predictable shape.
@MainActor
final class GridRoomAPI {
  private let realtime: RealtimeV2

  init(realtime: RealtimeV2) {
    self.realtime = realtime
  }

  func settings(spaceID: Int64) async throws -> SpaceSettings {
    let result = try await realtime.send(.getSpaceSettings(spaceID: spaceID))
    guard case let .getSpaceSettings(response)? = result, response.hasSettings else {
      throw GridRoomAPIError.invalidResponse
    }
    return response.settings
  }

  func setEnabled(_ enabled: Bool, spaceID: Int64) async throws -> SpaceSettings {
    let result = try await realtime.send(.toggleSpaceGrid(spaceID: spaceID, enabled: enabled))
    guard case let .toggleSpaceGrid(response)? = result, response.hasSettings else {
      throw GridRoomAPIError.invalidResponse
    }
    return response.settings
  }

  func grid(spaceID: Int64) async throws -> InlineProtocol.Grid {
    let result = try await realtime.send(.getGrid(spaceID: spaceID))
    guard case let .getGrid(response)? = result, response.hasGrid else {
      throw GridRoomAPIError.invalidResponse
    }
    return response.grid
  }

  func home() async throws -> [GridHomeSpace] {
    let result = try await realtime.send(.getGridHome())
    guard case let .getGridHome(response)? = result else {
      throw GridRoomAPIError.invalidResponse
    }
    return response.spaces
  }

  func createRoom(spaceID: Int64) async throws -> GridRoomMutationResult {
    let result = try await realtime.send(.createGridRoom(spaceID: spaceID))
    guard case let .createGridRoom(response)? = result else {
      throw GridRoomAPIError.invalidResponse
    }
    return GridRoomMutationResult(
      grids: response.grids,
      credentials: response.hasConnection ? response.connection : nil
    )
  }

  func joinRoom(roomID: Int64) async throws -> GridRoomMutationResult {
    let result = try await realtime.send(.joinGridRoom(roomID: roomID))
    guard case let .joinGridRoom(response)? = result else {
      throw GridRoomAPIError.invalidResponse
    }
    return GridRoomMutationResult(
      grids: response.grids,
      credentials: response.hasConnection ? response.connection : nil
    )
  }

  func leaveRoom(roomID: Int64) async throws -> [InlineProtocol.Grid] {
    let result = try await realtime.send(.leaveGridRoom(roomID: roomID))
    guard case let .leaveGridRoom(response)? = result else {
      throw GridRoomAPIError.invalidResponse
    }
    return response.grids
  }

  func setLocked(_ locked: Bool, roomID: Int64) async throws -> InlineProtocol.Grid {
    let result = try await realtime.send(.setGridRoomLocked(roomID: roomID, locked: locked))
    guard case let .setGridRoomLocked(response)? = result, response.hasGrid else {
      throw GridRoomAPIError.invalidResponse
    }
    return response.grid
  }

  func setTitle(_ title: String, roomID: Int64) async throws -> InlineProtocol.Grid {
    let result = try await realtime.send(.setGridRoomTitle(roomID: roomID, title: title))
    guard case let .setGridRoomTitle(response)? = result, response.hasGrid else {
      throw GridRoomAPIError.invalidResponse
    }
    return response.grid
  }

  func deleteRoom(roomID: Int64) async throws -> InlineProtocol.Grid {
    let result = try await realtime.send(.deleteGridRoom(roomID: roomID))
    guard case let .deleteGridRoom(response)? = result, response.hasGrid else {
      throw GridRoomAPIError.invalidResponse
    }
    return response.grid
  }

  func prepareConnection(roomID: Int64, generation: Int32) async throws -> GridConnectionCredentials? {
    let result = try await realtime.send(
      .prepareGridConnection(roomID: roomID, generation: generation)
    )
    guard case let .prepareGridConnection(response)? = result else {
      throw GridRoomAPIError.invalidResponse
    }
    return response.hasConnection ? response.connection : nil
  }

  func setMicrophoneEnabled(_ enabled: Bool, roomID: Int64) async throws {
    let result = try await realtime.send(
      .setGridAvatarMicrophoneEnabled(roomID: roomID, enabled: enabled)
    )
    guard case .setGridAvatarMicrophoneEnabled? = result else {
      throw GridRoomAPIError.invalidResponse
    }
  }
}

enum GridRoomAPIError: Error {
  case invalidResponse
}
