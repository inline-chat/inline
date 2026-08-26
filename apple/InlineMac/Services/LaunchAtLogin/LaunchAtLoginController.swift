import Combine
import Logger
import ServiceManagement

private enum LaunchAtLoginOperation: String, Sendable {
  case enable
  case disable
}

private enum LaunchAtLoginApplyOutcome: Sendable {
  case applied
  case failed(
    operation: LaunchAtLoginOperation,
    effectiveEnabled: Bool,
    details: String
  )
}

private struct LaunchAtLoginUpdateFailure: PrivacySafeErrorCategoryProviding {
  let operation: LaunchAtLoginOperation

  var privacySafeErrorCategory: String {
    "launch_at_login:\(operation.rawValue)_failed"
  }
}

/// ServiceManagement performs synchronous XPC work. Serializing it on a dedicated
/// actor keeps launch and Settings responsive while preserving toggle order.
private actor LaunchAtLoginWorker {
  private var latestRevision = 0

  func apply(isEnabled: Bool, revision: Int) -> LaunchAtLoginApplyOutcome? {
    guard revision >= latestRevision else { return nil }
    latestRevision = revision

    let service = SMAppService.mainApp
    let currentlyEnabled = Self.isEnabledStatus(service.status)
    guard currentlyEnabled != isEnabled else { return .applied }

    let operation: LaunchAtLoginOperation = isEnabled ? .enable : .disable
    do {
      if isEnabled {
        try service.register()
      } else {
        try service.unregister()
      }
      return .applied
    } catch {
      return .failed(
        operation: operation,
        effectiveEnabled: Self.isEnabledStatus(service.status),
        details: String(describing: error)
      )
    }
  }

  private static func isEnabledStatus(_ status: SMAppService.Status) -> Bool {
    switch status {
    case .enabled, .requiresApproval:
      true
    default:
      false
    }
  }
}

@MainActor
final class LaunchAtLoginController {
  private let log = Log.scoped("LaunchAtLoginController")
  private let worker = LaunchAtLoginWorker()
  private var cancellables = Set<AnyCancellable>()
  private var revision = 0

  func start() {
#if DEBUG_BUILD
    // Local debug builds should never auto-register login items.
    if AppSettings.shared.launchAtLogin {
      AppSettings.shared.launchAtLogin = false
    }
    log.info("Launch at login is disabled for DEBUG_BUILD.")
    return
#endif
    AppSettings.shared.$launchAtLogin
      .removeDuplicates()
      .sink { [weak self] isEnabled in
        self?.scheduleApply(isEnabled: isEnabled)
      }
      .store(in: &cancellables)
  }

  private func scheduleApply(isEnabled: Bool) {
    revision &+= 1
    let requestedRevision = revision
    Task { [weak self, worker] in
      guard let outcome = await worker.apply(
        isEnabled: isEnabled,
        revision: requestedRevision
      ) else { return }
      guard let self, requestedRevision == revision else { return }

      if case let .failed(operation, effectiveEnabled, details) = outcome {
        log.error(
          "Launch at login update failed: \(details)",
          error: LaunchAtLoginUpdateFailure(operation: operation)
        )
        if AppSettings.shared.launchAtLogin != effectiveEnabled {
          AppSettings.shared.launchAtLogin = effectiveEnabled
        }
      }
    }
  }
}
