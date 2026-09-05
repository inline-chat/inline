import Auth
import Combine
import Foundation
import InlineKit
import Logger

/// Global state for translations
public final class TranslationState: @unchecked Sendable {
  public static let shared = TranslationState()

  @MainActor
  public let subject = PassthroughSubject<(Peer, Bool), Never>()

  private var preferenceSubscription: AnyCancellable?

  private init() {
    preferenceSubscription = AppDatabase.shared.translationPreferences.changes
      .receive(on: DispatchQueue.main)
      .sink { [weak self] peer, _ in
        MainActor.assumeIsolated {
          guard let self else { return }
          self.publish(self.isTranslationEnabled(for: peer), for: peer)
        }
      }
  }

  public func isTranslationEnabled(for peerId: Peer) -> Bool {
    AppDatabase.shared.translationPreferences.isEnabled(for: peerId)
  }

  @MainActor
  public func setTranslationEnabled(_ enabled: Bool, for peerId: Peer) {
    let account: AuthAccountMutationToken
    do {
      account = try Auth.shared.handle.beginAccountMutation()
    } catch {
      Log.shared.error("Cannot change translation preference during account transition", error: error)
      return
    }
    let preferences = AppDatabase.shared.translationPreferences
    let intent = UUID()
    preferences.begin(enabled, for: peerId, intent: intent)
    Task {
      do {
        _ = try await Api.realtime.send(UpdateDialogTranslationTransaction(
          peer: peerId,
          enabled: enabled,
          intent: intent
        ), expectedAccount: account)
      } catch {
        preferences.finish(for: peerId, intent: intent)
        Log.shared.error("Failed to save translation preference", error: error)
      }
    }
  }

  @MainActor
  public func toggleTranslation(for peerId: Peer) {
    setTranslationEnabled(!isTranslationEnabled(for: peerId), for: peerId)
  }

  /// Restart local translation work after a language change without changing
  /// the account's translation preference on other devices.
  @MainActor
  public func restartTranslation(for peerId: Peer) {
    subject.send((peerId, false))
    publish(isTranslationEnabled(for: peerId), for: peerId)
  }

  @MainActor
  private func publish(_ enabled: Bool, for peer: Peer) {
    MessagesPublisher.shared.messagesReload(peer: peer, animated: true)
    subject.send((peer, enabled))
  }

  // MARK: - Subscriptions

  @MainActor private var cancellables: [String: AnyCancellable] = [:]

  // Subscribe to translation state changes
  @MainActor public func subscribe(peerId: Peer, key: String, completion: @escaping (Bool) -> Void) {
    let key = peerId.toString() + "_" + key
    let cancellable = subject
      .filter { output in
        output.0 == peerId
      }
      .sink { output in
        completion(output.1)
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
