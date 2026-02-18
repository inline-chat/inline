import Foundation
import SwiftUI

enum UpdateStatus: Equatable {
  case idle
  case checking
  case updateAvailable(version: String, build: String?)
  case downloading(receivedBytes: Int64, expectedBytes: Int64?)
  case extracting
  case readyToInstall(version: String?, build: String?)
  case installing
  case upToDate
  case failed(message: String)

  var statusText: String {
    switch self {
    case .idle:
      return "Idle"
    case .checking:
      return "Checking for updates"
    case .updateAvailable:
      return "Update available"
    case .downloading:
      return "Downloading update"
    case .extracting:
      return "Preparing update"
    case .readyToInstall:
      return "Downloaded and ready to install"
    case .installing:
      return "Installing update"
    case .upToDate:
      return "You're up to date"
    case .failed:
      return "Update failed"
    }
  }

  var menuTitle: String {
    switch self {
    case .idle, .upToDate:
      return "Check for Updates…"
    case .checking:
      return "Checking for Updates…"
    case .updateAvailable(let version, _):
      return "Update \(version) Available…"
    case .downloading(let receivedBytes, let expectedBytes):
      if let expectedBytes, expectedBytes > 0 {
        let progress = min(100, max(0, Int((Double(receivedBytes) / Double(expectedBytes)) * 100)))
        return "Downloading Update… \(progress)%"
      }
      return "Downloading Update…"
    case .extracting:
      return "Preparing Update…"
    case .readyToInstall:
      return "Install Update…"
    case .installing:
      return "Installing Update…"
    case .failed:
      return "Retry Update Check…"
    }
  }

  var allowsManualAction: Bool {
    switch self {
    case .checking, .downloading, .extracting, .installing:
      return false
    default:
      return true
    }
  }

  var isReadyToInstall: Bool {
    if case .readyToInstall = self {
      return true
    }
    return false
  }

  var showsIndeterminateProgress: Bool {
    switch self {
    case .checking, .extracting, .installing:
      return true
    default:
      return false
    }
  }
}

@MainActor
final class UpdateInstallState: ObservableObject {
  @Published private(set) var isReadyToInstall = false
  @Published private(set) var status: UpdateStatus = .idle

#if DEBUG
  @Published var debugForceReady = false {
    didSet {
      refreshReadyState()
    }
  }
#endif

  private var readyToInstall = false
  private var installHandler: (() -> Void)?

  func setChecking() {
    status = .checking
  }

  func setUpdateAvailable(version: String, build: String?) {
    status = .updateAvailable(version: version, build: build)
  }

  func setDownloading(receivedBytes: Int64, expectedBytes: Int64?) {
    status = .downloading(receivedBytes: receivedBytes, expectedBytes: expectedBytes)
  }

  func setExtracting() {
    status = .extracting
  }

  func setReady(version: String? = nil, build: String? = nil, install: @escaping () -> Void) {
    installHandler = install
    readyToInstall = true
    status = .readyToInstall(version: version, build: build)
    refreshReadyState()
  }

  func setInstalling() {
    installHandler = nil
    readyToInstall = false
    status = .installing
    refreshReadyState()
  }

  func setUpToDate() {
    status = .upToDate
  }

  func setError(message: String) {
    status = .failed(message: message)
  }

  func resetToIdle() {
    installHandler = nil
    readyToInstall = false
    status = .idle
    refreshReadyState()
  }

  func install() {
    guard let handler = installHandler else { return }
    installHandler = nil
    readyToInstall = false
    status = .installing
    refreshReadyState()
    handler()
  }

  private func refreshReadyState() {
#if DEBUG
    isReadyToInstall = readyToInstall || debugForceReady
#else
    isReadyToInstall = readyToInstall
#endif
  }
}
