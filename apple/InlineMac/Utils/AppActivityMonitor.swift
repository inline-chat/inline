import AppKit

final class AppActivityMonitor {
  static let shared = AppActivityMonitor()

  enum State: Equatable {
    case active
    case inactive
  }

  private(set) var state: State
  private var observers: [UUID: (State) -> Void] = [:]

  var isActive: Bool { state == .active }

  private init(notificationCenter: NotificationCenter = .default) {
    state = NSApplication.shared.isActive ? .active : .inactive

    notificationCenter.addObserver(
      self,
      selector: #selector(didBecomeActive),
      name: NSApplication.didBecomeActiveNotification,
      object: nil
    )

    notificationCenter.addObserver(
      self,
      selector: #selector(didResignActive),
      name: NSApplication.didResignActiveNotification,
      object: nil
    )
  }

  @discardableResult
  func addObserver(_ handler: @escaping (State) -> Void) -> UUID {
    let id = UUID()
    observers[id] = handler
    return id
  }

  func removeObserver(_ id: UUID) {
    observers.removeValue(forKey: id)
  }

  private func updateState(_ newState: State) {
    guard newState != state else { return }
    state = newState
    observers.values.forEach { $0(newState) }
  }

  #if DEBUG
  /// The read journey's stand-in for the app leaving and coming back to the front, without
  /// taking the screen from whoever is using the Mac.
  func simulate(_ newState: State) {
    updateState(newState)
  }
  #endif

  @objc private func didBecomeActive() {
    updateState(.active)
  }

  @objc private func didResignActive() {
    updateState(.inactive)
  }
}
