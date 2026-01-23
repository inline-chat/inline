import Combine
import Logger
import ServiceManagement

final class LaunchAtLoginController {
  private let log = Log.scoped("LaunchAtLoginController")
  private var cancellables = Set<AnyCancellable>()

  func start() {
    AppSettings.shared.$launchAtLogin
      .removeDuplicates()
      .sink { [weak self] isEnabled in
        self?.apply(isEnabled: isEnabled)
      }
      .store(in: &cancellables)
  }

  private func apply(isEnabled: Bool) {
    let service = SMAppService.mainApp
    let currentlyEnabled = isEnabledStatus(service.status)
    guard currentlyEnabled != isEnabled else {
      return
    }

    do {
      if isEnabled {
        try service.register()
      } else {
        try service.unregister()
      }
    } catch {
      log.error("Launch at login update failed: \(error)")
      let effectiveEnabled = isEnabledStatus(service.status)
      if AppSettings.shared.launchAtLogin != effectiveEnabled {
        AppSettings.shared.launchAtLogin = effectiveEnabled
      }
    }
  }

  private func isEnabledStatus(_ status: SMAppService.Status) -> Bool {
    switch status {
    case .enabled, .requiresApproval:
      return true
    default:
      return false
    }
  }
}
