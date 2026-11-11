import Auth
import Combine
import Foundation
import Intents
import Logger
import RealtimeV2
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// Reports this device's Focus state while the user shares it with anyone.
///
/// Apple only exposes whether a Focus is on. Without an Intents extension the
/// app learns about changes when it becomes active, reconnects, and (on macOS,
/// where the app usually stays running) on a short poll.
@MainActor
public final class FocusStatusReporter: ObservableObject {
  public static let shared = FocusStatusReporter()

  @Published public private(set) var authorization: INFocusStatusAuthorizationStatus

  private let log = Log.scoped("FocusStatus")
  private var lastSent: (focused: Bool, at: Date)?
  private var cancellables = Set<AnyCancellable>()
  private var pollTimer: Timer?
  private var started = false

  /// Unchanged values are re-sent this often so viewers stay inside the stale window.
  private static let resendInterval: TimeInterval = 60 * 60
  #if os(macOS)
  private static let pollInterval: TimeInterval = 30
  #endif

  private init() {
    authorization = INFocusStatusCenter.default.authorizationStatus
  }

  public func start() {
    guard !started else { return }
    started = true

    #if os(iOS)
    NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)
      .sink { [weak self] _ in self?.refresh() }
      .store(in: &cancellables)
    #elseif os(macOS)
    NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
      .sink { [weak self] _ in self?.refresh() }
      .store(in: &cancellables)
    pollTimer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
      Task { @MainActor in self?.refresh() }
    }
    pollTimer?.tolerance = 10
    #endif

    Api.realtime.stateObject.connectionStatePublisher
      .receive(on: DispatchQueue.main)
      .sink { [weak self] state in
        guard case .connected = state else { return }
        // A reconnect may follow a server restart or a long sleep; report afresh.
        self?.lastSent = nil
        self?.refresh()
      }
      .store(in: &cancellables)

    INUserSettings.current.privacy.$focusStatusRule
      .dropFirst()
      .receive(on: DispatchQueue.main)
      .sink { [weak self] _ in
        self?.lastSent = nil
        self?.refresh()
      }
      .store(in: &cancellables)

    refresh()
  }

  /// Shows Apple's prompt. Called from the settings row, never at launch.
  public func requestAuthorization() async {
    let status = await withCheckedContinuation { continuation in
      INFocusStatusCenter.default.requestAuthorization { continuation.resume(returning: $0) }
    }
    authorization = status
    refresh()
  }

  public func refresh() {
    authorization = INFocusStatusCenter.default.authorizationStatus
    guard authorization == .authorized,
          Auth.shared.getCurrentUserId() != nil,
          INUserSettings.current.privacy.sharesFocusStatus,
          // Nil when the current Focus does not share its status.
          let focused = INFocusStatusCenter.default.focusStatus.isFocused
    else { return }

    if let lastSent, lastSent.focused == focused, Date().timeIntervalSince(lastSent.at) < Self.resendInterval {
      return
    }
    lastSent = (focused, Date())

    Task { [weak self] in
      do {
        _ = try await Api.realtime.send(.setFocusStatus(focused: focused))
      } catch {
        self?.log.warning("Failed to report Focus status: \(error)")
        if self?.lastSent?.focused == focused { self?.lastSent = nil }
      }
    }
  }
}
