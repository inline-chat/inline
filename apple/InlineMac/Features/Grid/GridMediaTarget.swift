import Foundation
import InlineRTC

/// Grid's product identity for its current media session.
///
/// Space, room, and generation remain app-owned. InlineRTC receives only the
/// stable opaque identity produced below and never interprets these fields.
struct GridMediaTarget: Equatable, Hashable, Sendable {
  let spaceID: Int64
  let roomID: Int64
  let generation: Int32

  var rtcSessionID: InlineRTCSessionID {
    InlineRTCSessionID("grid:\(spaceID):\(roomID):\(generation)")
  }
}
