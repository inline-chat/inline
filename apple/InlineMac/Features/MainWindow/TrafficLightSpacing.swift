import AppKit
import InlineMacWindow

@MainActor
final class TrafficLightController {
  private weak var window: TrafficLightInsetWindow?
  private var isTrafficLightsVisible = true
  private var observers: [NSObjectProtocol] = []
  private var presenceObservers: [UUID: (Bool) -> Void] = [:]

  private(set) var insetPreset: TrafficLightInsetPreset

  init(window: TrafficLightInsetWindow, insetPreset: TrafficLightInsetPreset) {
    self.window = window
    self.insetPreset = insetPreset
    setupObservers(window: window)
    refreshPresence()
    applyInsetIfNeeded()
  }

  deinit {
    let notificationCenter = NotificationCenter.default
    observers.forEach { notificationCenter.removeObserver($0) }
    observers.removeAll()
    presenceObservers.removeAll()
  }

  func setInsetPreset(_ preset: TrafficLightInsetPreset) {
    guard insetPreset != preset else { return }
    insetPreset = preset
    applyInsetIfNeeded()
  }

  func addPresenceObserver(_ handler: @escaping (Bool) -> Void) -> UUID {
    let id = UUID()
    presenceObservers[id] = handler
    handler(isTrafficLightsVisible)
    return id
  }

  func removePresenceObserver(_ id: UUID) {
    presenceObservers.removeValue(forKey: id)
  }

  private func setupObservers(window: NSWindow) {
    let notificationCenter = NotificationCenter.default
    observers = [
      notificationCenter.addObserver(
        forName: NSWindow.willEnterFullScreenNotification,
        object: window,
        queue: .main
      ) { [weak self] _ in
        self?.setTrafficLightsVisible(false)
      },
      notificationCenter.addObserver(
        forName: NSWindow.willExitFullScreenNotification,
        object: window,
        queue: .main
      ) { [weak self] _ in
        self?.setTrafficLightsVisible(true)
      },
      notificationCenter.addObserver(
        forName: NSWindow.didEnterFullScreenNotification,
        object: window,
        queue: .main
      ) { [weak self] _ in
        self?.refreshPresence()
      },
      notificationCenter.addObserver(
        forName: NSWindow.didExitFullScreenNotification,
        object: window,
        queue: .main
      ) { [weak self] _ in
        self?.refreshPresence()
        self?.applyInsetIfNeeded()
      },
    ]
  }

  private func refreshPresence() {
    guard let window else { return }
    let isVisible = !window.styleMask.contains(.fullScreen)
    setTrafficLightsVisible(isVisible)
  }

  private func setTrafficLightsVisible(_ isVisible: Bool) {
    guard isTrafficLightsVisible != isVisible else { return }
    isTrafficLightsVisible = isVisible
    presenceObservers.values.forEach { $0(isVisible) }
  }

  private func applyInsetIfNeeded() {
    guard let window, isTrafficLightsVisible else { return }
    window.trafficLightsInset = insetPreset.inset
    window.applyTrafficLightsInset()
  }
}
