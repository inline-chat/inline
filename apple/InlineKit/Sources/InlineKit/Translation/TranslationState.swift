import Combine
import Foundation
import InlineProtocol

/// Global state for translations
public final class TranslationState: @unchecked Sendable {
  public static let shared = TranslationState()

  @MainActor
  public let subject = PassthroughSubject<(Peer, Bool), Never>()

  private var cache: [String: Bool] = [:]
  private let cacheLock = NSLock()
  private let translationEnabledKey = "translation_enabled_"

  private init() {}

  public func isTranslationEnabled(for peerId: Peer) -> Bool {
    let key = peerId.toString()

    // Check cache first
    let cached = cacheLock.withLock { cache[key] }
    if let cached {
      return cached
    }

    // If not in cache, get from UserDefaults and cache it
    let value = UserDefaults.standard.bool(forKey: translationEnabledKey + key)

    cacheLock.withLock {
      cache[key] = value
    }

    return value
  }

  public func setTranslationEnabled(_ enabled: Bool, for peerId: Peer) {
    let key = peerId.toString()

    cacheLock.withLock {
      cache[key] = enabled
    }
    UserDefaults.standard.set(enabled, forKey: translationEnabledKey + key)

    // Notify progressive view model with a reload
    Task { @MainActor in
      MessagesPublisher.shared.messagesReload(peer: peerId, animated: true)

      // Publish the change
      self.subject.send((peerId, enabled))
    }
  }

  public func toggleTranslation(for peerId: Peer) {
    let current = isTranslationEnabled(for: peerId)
    setTranslationEnabled(!current, for: peerId)
  }

  public func clearCache() {
    cacheLock.withLock {
      cache.removeAll()
    }
  }

  // MARK: - Subscriptions

  @MainActor private var cancellables: [String: AnyCancellable] = [:]

  // Subscribe to translation state changes
  @MainActor public func subscribe(peerId: Peer, key: String, completion: @escaping (Bool) -> Void) {
    let key = peerId.toString() + "_" + key
    let cancellable = subject.sink {
      completion($0.1)
    }
    cancellables[key]?.cancel()
    cancellables[key] = cancellable
  }

  @MainActor public func unsubscribe(peerId: Peer, key: String) {
    let key = peerId.toString() + "_" + key
    cancellables[key]?.cancel()
    cancellables[key] = nil
  }
}
