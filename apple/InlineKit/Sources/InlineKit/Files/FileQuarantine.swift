#if os(macOS)
import CoreServices
import Foundation
import Logger

/// Marks files downloaded from chats with `com.apple.quarantine`, so Gatekeeper and the
/// "downloaded from the Internet" prompt apply when one is opened. Copies saved to Downloads
/// keep the attribute.
///
/// Sandboxed builds (App Store, Debug) already get it from the system for every file they
/// write; only the unsandboxed Direct build has to set it itself.
enum FileQuarantine {
  static let isNeeded = ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] == nil

  static func markDownloaded(_ url: URL) {
    guard isNeeded, url.isFileURL else { return }
    var values = URLResourceValues()
    values.quarantineProperties = [
      kLSQuarantineAgentNameKey as String: "Inline",
      kLSQuarantineTypeKey as String: kLSQuarantineTypeOtherDownload as String,
    ]
    var url = url
    do {
      try url.setResourceValues(values)
    } catch {
      Log.shared.warning("Failed to quarantine downloaded file: \(error.localizedDescription)")
    }
  }
}
#endif
