import Foundation
import SwiftUI

@MainActor
final class UpdateInstallState: ObservableObject {
  @Published private(set) var isReadyToInstall = false

#if DEBUG
  @Published var debugForceReady = false {
    didSet {
      refreshReadyState()
    }
  }
#endif

  private var readyToInstall = false
  private var installHandler: (() -> Void)?

  func setReady(install: @escaping () -> Void) {
    installHandler = install
    readyToInstall = true
    refreshReadyState()
  }

  func clear() {
    installHandler = nil
    readyToInstall = false
    refreshReadyState()
  }

  func install() {
    guard let handler = installHandler else { return }
    installHandler = nil
    readyToInstall = false
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
