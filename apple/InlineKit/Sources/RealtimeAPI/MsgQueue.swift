import Auth
import Foundation
import InlineProtocol
import Logger

package final class MsgQueue: @unchecked Sendable {
  private let log = Log.scoped("Realtime_MsgQueue")
  private let lock = NSLock()
  private var _queue: [ClientMessage] = []
  private var _inFlight: [UInt64: ClientMessage] = [:]

  public func push(message: ClientMessage) {
    lock.withLock {
      _queue.append(message)
      log.debug("Pushed message \(message.id), queue size: \(_queue.count)")
    }
  }

  public func next() -> ClientMessage? {
    lock.withLock {
      guard !_queue.isEmpty else { return nil }
      let message = _queue.removeFirst()
      _inFlight[message.id] = message
      log.debug("Next message \(message.id), queue size: \(_queue.count)")
      return message
    }
  }

  public func requeue(_ message: ClientMessage) {
    lock.withLock {
      _queue.insert(message, at: 0)
      _inFlight.removeValue(forKey: message.id)
    }
  }

  // Add to MsgQueue:
  public func requeueAllInFlight() {
    lock.withLock {
      _queue = _inFlight.values + _queue
      _inFlight.removeAll()
    }
  }

  public func remove(msgId: UInt64) {
    lock.withLock {
      _inFlight.removeValue(forKey: msgId)
    }
  }

  public var isEmpty: Bool {
    lock.withLock { _queue.isEmpty }
  }
  
  public func removeAll() {
    lock.withLock {
      _queue.removeAll()
      _inFlight.removeAll()
    }
  }
}
