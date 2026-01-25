import Auth
import Foundation
import Network

#if canImport(UIKit)
import UIKit
#endif

#if canImport(AppKit)
import AppKit
#endif

final class AuthConnectionAdapter {
  private let auth: Auth
  private let manager: ConnectionManager
  private var task: Task<Void, Never>?

  init(auth: Auth, manager: ConnectionManager) {
    self.auth = auth
    self.manager = manager
  }

  func start() {
    task?.cancel()
    let auth = self.auth
    let manager = self.manager
    task = Task {
      for await event in auth.events {
        guard !Task.isCancelled else { return }

        switch event {
        case .login:
          await manager.setAuthAvailable(true)
          await manager.connectNow()

        case .logout:
          await manager.setAuthAvailable(false)
          await manager.stop()
        }
      }
    }
  }

  func stop() {
    task?.cancel()
    task = nil
  }

  deinit {
    task?.cancel()
    task = nil
  }
}

final class LifecycleConnectionAdapter {
  private let manager: ConnectionManager

  #if canImport(UIKit)
  private var observersInstalled = false
  #endif

  init(manager: ConnectionManager) {
    self.manager = manager
    installObservers()
  }

  deinit {
    NotificationCenter.default.removeObserver(self)
  }

  private func installObservers() {
    #if canImport(UIKit)
    guard !observersInstalled else { return }
    observersInstalled = true

    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleAppDidBecomeActive),
      name: UIApplication.didBecomeActiveNotification,
      object: nil
    )

    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleAppDidEnterBackground),
      name: UIApplication.didEnterBackgroundNotification,
      object: nil
    )
    #elseif canImport(AppKit)
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleAppDidBecomeActive),
      name: NSApplication.didBecomeActiveNotification,
      object: nil
    )
    #endif
  }

  @objc private func handleAppDidBecomeActive() {
    Task { [manager] in
      await manager.setAppActive(true)
    }
  }

  @objc private func handleAppDidEnterBackground() {
    Task { [manager] in
      await manager.setAppActive(false)
    }
  }
}

final class NetworkConnectionAdapter {
  private let manager: ConnectionManager
  private let monitor: NWPathMonitor

  init(manager: ConnectionManager) {
    self.manager = manager
    self.monitor = NWPathMonitor()

    let manager = self.manager
    monitor.pathUpdateHandler = { path in
      let isSatisfied = path.status == .satisfied
      Task { await manager.setNetworkAvailable(isSatisfied) }
    }

    monitor.start(queue: DispatchQueue(label: "RealtimeV2.ConnectionManager.path"))
  }

  deinit {
    monitor.cancel()
  }
}
