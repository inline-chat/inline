import InlineProtocol

/// Pure optimistic room transformations. No RPC, media, persistence, logging,
/// or actor ownership is hidden inside these operations.
public enum GridOptimisticState {
  public enum RoomField: Hashable, Sendable {
    case locked
    case title
  }

  public struct RoomChange: Sendable {
    public let roomID: Int64
    public let spaceID: Int64
    public let previousRoom: GridRoom
    public let optimisticRoom: GridRoom
    public let fields: Set<RoomField>
    public let nextGrid: InlineProtocol.Grid

    public init(
      roomID: Int64,
      spaceID: Int64,
      previousRoom: GridRoom,
      optimisticRoom: GridRoom,
      fields: Set<RoomField>,
      nextGrid: InlineProtocol.Grid
    ) {
      self.roomID = roomID
      self.spaceID = spaceID
      self.previousRoom = previousRoom
      self.optimisticRoom = optimisticRoom
      self.fields = fields
      self.nextGrid = nextGrid
    }
  }

  public struct MembershipChange: Sendable {
    public let roomID: Int64
    public let spaceID: Int64
    public let previousGrids: [Int64: InlineProtocol.Grid]
    public let nextGrids: [Int64: InlineProtocol.Grid]

    public init(
      roomID: Int64,
      spaceID: Int64,
      previousGrids: [Int64: InlineProtocol.Grid],
      nextGrids: [Int64: InlineProtocol.Grid]
    ) {
      self.roomID = roomID
      self.spaceID = spaceID
      self.previousGrids = previousGrids
      self.nextGrids = nextGrids
    }
  }

  /// The last server-confirmed membership position for a chain of optimistic
  /// joins/leaves. Beginning a newer intent never replaces an active baseline
  /// with another optimistic projection.
  public struct MembershipRollbackBaseline: Sendable {
    public private(set) var grids: [Int64: InlineProtocol.Grid]?

    public init() {}

    public mutating func beginIfNeeded(with confirmedGrids: [Int64: InlineProtocol.Grid]) {
      if grids == nil { grids = confirmedGrids }
    }

    public mutating func mergeConfirmed(_ snapshots: [InlineProtocol.Grid]) {
      guard var grids else { return }
      for snapshot in snapshots { grids[snapshot.spaceID] = snapshot }
      self.grids = grids
    }

    public mutating func remove(spaceID: Int64) {
      grids?.removeValue(forKey: spaceID)
    }

    public mutating func clear() {
      grids = nil
    }
  }

  public static func updatingRoom(
    in grids: [Int64: InlineProtocol.Grid],
    roomID: Int64,
    update: (inout GridRoom) -> Void
  ) -> RoomChange? {
    guard let entry = grids.first(where: { _, grid in
      grid.rooms.contains(where: { $0.id == roomID })
    }) else { return nil }
    let previousGrid = entry.value
    guard let roomIndex = previousGrid.rooms.firstIndex(where: { $0.id == roomID }) else {
      return nil
    }
    var nextGrid = previousGrid
    update(&nextGrid.rooms[roomIndex])
    let previousRoom = previousGrid.rooms[roomIndex]
    let optimisticRoom = nextGrid.rooms[roomIndex]
    var fields = Set<RoomField>()
    if previousRoom.locked != optimisticRoom.locked { fields.insert(.locked) }
    if title(of: previousRoom) != title(of: optimisticRoom) { fields.insert(.title) }
    guard !fields.isEmpty else { return nil }
    return RoomChange(
      roomID: roomID,
      spaceID: entry.key,
      previousRoom: previousRoom,
      optimisticRoom: optimisticRoom,
      fields: fields,
      nextGrid: nextGrid
    )
  }

  public static func applyingRoomIntent(
    _ change: RoomChange,
    to grid: InlineProtocol.Grid
  ) -> InlineProtocol.Grid {
    guard grid.spaceID == change.spaceID,
          let roomIndex = grid.rooms.firstIndex(where: { $0.id == change.roomID })
    else { return grid }
    var grid = grid
    applyRoomFields(from: change.optimisticRoom, fields: change.fields, to: &grid.rooms[roomIndex])
    return grid
  }

  public static func rollingBackRoomIntent(
    _ change: RoomChange,
    in grid: InlineProtocol.Grid
  ) -> InlineProtocol.Grid {
    guard grid.spaceID == change.spaceID,
          let roomIndex = grid.rooms.firstIndex(where: { $0.id == change.roomID })
    else { return grid }
    var grid = grid
    var room = grid.rooms[roomIndex]
    if change.fields.contains(.locked), room.locked == change.optimisticRoom.locked {
      room.locked = change.previousRoom.locked
    }
    if change.fields.contains(.title), title(of: room) == title(of: change.optimisticRoom) {
      setTitle(title(of: change.previousRoom), on: &room)
    }
    grid.rooms[roomIndex] = room
    return grid
  }

  public static func joining(
    roomID: Int64,
    in grids: [Int64: InlineProtocol.Grid],
    avatar: GridAvatar?,
    microphoneEnabled: Bool,
    joinedAt: Int64
  ) -> MembershipChange? {
    guard let entry = grids.sorted(by: { $0.key < $1.key }).first(where: { _, grid in
      grid.rooms.contains(where: { $0.id == roomID })
    }) else { return nil }
    let previousOwnedAvatar = grids.sorted(by: { $0.key < $1.key })
      .lazy
      .flatMap { $0.value.rooms }
      .flatMap(\.avatars)
      .first(where: \.ownedByCurrentSession)
    let avatar = previousOwnedAvatar ?? avatar
    var relevantSpaceIDs = Set([entry.key])
    for (spaceID, grid) in grids where grid.hasCurrentRoomID
      || grid.rooms.contains(where: { $0.avatars.contains(where: \.ownedByCurrentSession) }) {
      relevantSpaceIDs.insert(spaceID)
    }
    let previousGrids = grids.filter { relevantSpaceIDs.contains($0.key) }
    var nextGrids = grids

    for spaceID in Array(nextGrids.keys) {
      guard var grid = nextGrids[spaceID] else { continue }
      for index in grid.rooms.indices {
        grid.rooms[index].avatars.removeAll(where: \.ownedByCurrentSession)
        if grid.rooms[index].avatars.isEmpty {
          grid.rooms[index].locked = false
        }
      }
      grid.rooms.removeAll { room in
        room.avatars.isEmpty && !room.hasTitle && room.id != roomID
      }
      if grid.hasCurrentRoomID { grid.clearCurrentRoomID() }
      nextGrids[spaceID] = grid
    }

    guard var destinationGrid = nextGrids[entry.key],
          let roomIndex = destinationGrid.rooms.firstIndex(where: { $0.id == roomID })
    else {
      return nil
    }
    if var avatar {
      avatar.joinedAt = joinedAt
      avatar.ownedByCurrentSession = true
      avatar.microphoneEnabled = microphoneEnabled
      destinationGrid.rooms[roomIndex].avatars.removeAll { $0.user.id == avatar.user.id }
      destinationGrid.rooms[roomIndex].avatars.append(avatar)
    }
    destinationGrid.currentRoomID = roomID
    nextGrids[entry.key] = destinationGrid
    return MembershipChange(
      roomID: roomID,
      spaceID: entry.key,
      previousGrids: previousGrids,
      nextGrids: nextGrids.filter { relevantSpaceIDs.contains($0.key) }
    )
  }

  public static func leaving(
    spaceID: Int64,
    in grids: [Int64: InlineProtocol.Grid]
  ) -> MembershipChange? {
    guard let previousGrid = grids[spaceID], previousGrid.hasCurrentRoomID,
          let currentRoom = previousGrid.rooms.first(where: { $0.id == previousGrid.currentRoomID }),
          currentRoom.avatars.contains(where: \.ownedByCurrentSession)
    else { return nil }

    let roomID = previousGrid.currentRoomID
    var nextGrid = previousGrid
    if let roomIndex = nextGrid.rooms.firstIndex(where: { $0.id == roomID }) {
      nextGrid.rooms[roomIndex].avatars.removeAll(where: \.ownedByCurrentSession)
      if nextGrid.rooms[roomIndex].avatars.isEmpty {
        if nextGrid.rooms[roomIndex].hasTitle {
          nextGrid.rooms[roomIndex].locked = false
        } else {
          nextGrid.rooms.remove(at: roomIndex)
        }
      }
    }
    nextGrid.clearCurrentRoomID()
    return MembershipChange(
      roomID: roomID,
      spaceID: spaceID,
      previousGrids: [spaceID: previousGrid],
      nextGrids: [spaceID: nextGrid]
    )
  }

  public static func rollingBackMembershipIntent(
    _ change: MembershipChange,
    in grids: [Int64: InlineProtocol.Grid]
  ) -> [Int64: InlineProtocol.Grid] {
    var grids = grids

    // Remove only the local avatar projection. Remote avatars, room metadata,
    // connection generations, and rooms received while the RPC was pending
    // remain untouched.
    for spaceID in Array(grids.keys) {
      guard var grid = grids[spaceID] else { continue }
      for index in grid.rooms.indices {
        grid.rooms[index].avatars.removeAll(where: \.ownedByCurrentSession)
        if grid.rooms[index].avatars.isEmpty {
          grid.rooms[index].locked = false
        }
      }
      grid.rooms.removeAll { $0.avatars.isEmpty && !$0.hasTitle }
      if grid.hasCurrentRoomID { grid.clearCurrentRoomID() }
      grids[spaceID] = grid
    }

    for (spaceID, previousGrid) in change.previousGrids {
      guard previousGrid.hasCurrentRoomID,
            let previousRoom = previousGrid.rooms.first(where: { $0.id == previousGrid.currentRoomID }),
            let previousAvatar = previousRoom.avatars.first(where: \.ownedByCurrentSession)
      else { continue }

      var grid = grids[spaceID] ?? .with {
        $0.spaceID = spaceID
        $0.enabled = previousGrid.enabled
      }
      if let roomIndex = grid.rooms.firstIndex(where: { $0.id == previousRoom.id }) {
        grid.rooms[roomIndex].avatars.removeAll {
          $0.ownedByCurrentSession || $0.user.id == previousAvatar.user.id
        }
        grid.rooms[roomIndex].avatars.append(previousAvatar)
      } else {
        grid.rooms.append(previousRoom)
      }
      grid.currentRoomID = previousRoom.id
      grids[spaceID] = grid
    }
    return grids
  }

  private static func applyRoomFields(
    from source: GridRoom,
    fields: Set<RoomField>,
    to destination: inout GridRoom
  ) {
    if fields.contains(.locked) { destination.locked = source.locked }
    if fields.contains(.title) { setTitle(title(of: source), on: &destination) }
  }

  private static func title(of room: GridRoom) -> String? {
    room.hasTitle ? room.title : nil
  }

  private static func setTitle(_ title: String?, on room: inout GridRoom) {
    if let title {
      room.title = title
    } else {
      room.clearTitle()
    }
  }
}
