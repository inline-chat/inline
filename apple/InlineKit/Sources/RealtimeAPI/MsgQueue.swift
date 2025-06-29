import Auth
import Foundation
import InlineProtocol
import Logger

package final actor MsgQueue: Sendable {
  private let log = Log.scoped("Realtime_MsgQueue")
  private var _queue: [ClientMessage] = []
  private var _inFlight: [UInt64: ClientMessage] = [:]

  public func push(message: ClientMessage) {
    _queue.append(message)
    log.debug("Pushed message \(message.id), queue size: \(_queue.count)")
  }

  public func next() -> ClientMessage? {
    guard !_queue.isEmpty else { return nil }
    let message = _queue.removeFirst()
    _inFlight[message.id] = message
    log.debug("Next message \(message.id), queue size: \(_queue.count)")
    return message
  }

  public func requeue(_ message: ClientMessage) {
    _queue.insert(message, at: 0)
    _inFlight.removeValue(forKey: message.id)
  }

  // Add to MsgQueue:
  public func requeueAllInFlight() {
    _queue = Array(_inFlight.values) + _queue
    _inFlight.removeAll()
  }

  public func remove(msgId: UInt64) {
    _inFlight.removeValue(forKey: msgId)
  }

  public var isEmpty: Bool {
    _queue.isEmpty
  }

  public func removeAll() {
    _queue.removeAll()
    _inFlight.removeAll()
  }
}
