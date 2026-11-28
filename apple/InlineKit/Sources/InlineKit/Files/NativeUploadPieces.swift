import Foundation
import os

/// How a part is split into pieces when the server takes parts in pieces
/// (`CreateUploadResult.piece_granularity`). The server replies to each piece as soon as it holds
/// it, so progress moves per piece instead of per 512 KiB part.
enum NativeUploadPieces {
  /// Telegram's default part size, and the size of every piece after the first part.
  static let pieceSize = 131_072
  /// The first part of an upload starts small and doubles, like Telegram's 16 KB parts, so the
  /// first progress shows after 16 KiB and a round trip instead of a whole part.
  static let rampUp = [16_384, 16_384, 32_768, 65_536, 131_072, 262_144]
  /// A file whose upload should take less than this goes whole inside its create (one round trip,
  /// no progress needed); a longer one goes in pieces so progress starts at once.
  static let inlineBudgetSeconds = 0.7
  /// Without a measured link speed, only files this small go inline.
  static let inlineBytesWithoutEstimate: Int64 = 131_072

  /// Byte ranges of one part. Nil when the granularity is unusable (then the part goes whole).
  static func ranges(partLength: Int, granularity: Int, rampUp: Bool) -> [Range<Int>]? {
    guard partLength > 0, granularity > 0, granularity <= pieceSize, pieceSize % granularity == 0 else {
      return nil
    }
    var ranges: [Range<Int>] = []
    var offset = 0
    var step = 0
    while offset < partLength {
      let wanted = rampUp && step < Self.rampUp.count ? Self.rampUp[step] : pieceSize
      let size = max(granularity, (wanted + granularity - 1) / granularity * granularity)
      let end = min(offset + size, partLength)
      ranges.append(offset ..< end)
      offset = end
      step += 1
    }
    return ranges
  }

  /// Whether a file of `byteCount` should go inline with its create. `bytesPerSecond` is the
  /// recently measured upload speed, if any.
  static func sendsInline(byteCount: Int64, partSize: Int64, bytesPerSecond: Double?) -> Bool {
    guard byteCount <= partSize else { return false }
    guard let bytesPerSecond, bytesPerSecond > 0 else { return byteCount <= inlineBytesWithoutEstimate }
    return Double(byteCount) / bytesPerSecond <= inlineBudgetSeconds
  }
}

/// Reports upload progress as accepted parts plus acknowledged pieces of parts still in flight,
/// never going backwards (a part the server lost and the client resends doesn't rewind the bar).
final class NativeUploadProgressMeter: Sendable {
  private struct State {
    var total: Int64
    var accepted: Int64 = 0
    var pieces: [UInt32: Int64] = [:]
    var reported: Int64 = -1
  }

  private let report: @Sendable (Int64, Int64) -> Void
  private let state: OSAllocatedUnfairLock<State>

  init(total: Int64, report: @escaping @Sendable (Int64, Int64) -> Void) {
    self.report = report
    state = OSAllocatedUnfairLock(initialState: State(total: total))
  }

  /// The file's size, once known: a video uploaded while it encodes learns it at the end.
  func setTotal(_ total: Int64) {
    publish { state in state.total = total }
  }

  /// Bytes of whole parts the server accepted (or holds); clears their piece counts.
  func accepted(_ bytes: Int64, parts: some Sequence<UInt32> = []) {
    publish { state in
      state.accepted = bytes
      for part in parts { state.pieces.removeValue(forKey: part) }
    }
  }

  func pieceAcknowledged(part: UInt32, bytes: Int64) {
    publish { state in state.pieces[part, default: 0] += bytes }
  }

  /// A part attempt that failed: its pieces will be sent again.
  func partReset(_ part: UInt32) {
    state.withLock { state in _ = state.pieces.removeValue(forKey: part) }
  }

  func complete() {
    publish { state in
      state.accepted = state.total
      state.pieces.removeAll()
    }
  }

  private func publish(_ change: (inout State) -> Void) {
    // The change runs synchronously under the lock and never escapes it.
    let value: (Int64, Int64)? = state.withLockUnchecked { state in
      change(&state)
      let current = min(state.total, state.accepted + state.pieces.values.reduce(0, +))
      guard current > state.reported else { return nil }
      state.reported = current
      return (current, state.total)
    }
    if let (current, total) = value { report(current, total) }
  }
}

/// Upload speed measured over recent uploads, for choosing between inline and pieces.
struct NativeUploadThroughput {
  private(set) var bytesPerSecond: Double?

  /// Records one upload's transfer: bytes acknowledged over the time from first send to last reply.
  mutating func record(bytes: Int64, seconds: Double) {
    // Small transfers mostly measure round trips, not the link.
    guard bytes >= 65_536, seconds > 0.05 else { return }
    let sample = Double(bytes) / seconds
    bytesPerSecond = bytesPerSecond.map { $0 * 0.5 + sample * 0.5 } ?? sample
  }
}
