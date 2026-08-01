#if SPARKLE
import Foundation

enum AutoUpdateChannel: String, CaseIterable, Identifiable {
  case stable
  case beta
  case tip

  var id: String { rawValue }

  var title: String {
    switch self {
    case .stable:
      "Stable"
    case .beta:
      "Beta"
    case .tip:
      "Tip"
    }
  }
}

enum AutoUpdateMode: String, CaseIterable, Identifiable {
  case off
  case check
  case download

  var id: String { rawValue }

  var title: String {
    switch self {
    case .off:
      "Off"
    case .check:
      "Check Automatically"
    case .download:
      "Download Automatically"
    }
  }
}

struct SoftwareUpdateInfo: Equatable {
  let version: String
  let build: String?
  let contentLength: Int64?
  let informationURL: URL?

  var isInformational: Bool { informationURL != nil }

  var versionLine: String {
    if let build, !build.isEmpty, build != version {
      return "Version \(version) (\(build))"
    }
    return "Version \(version)"
  }
}

enum SoftwareUpdatePhase: Equatable {
  case idle
  case checking
  case updateAvailable(SoftwareUpdateInfo)
  case downloading(info: SoftwareUpdateInfo?, receivedBytes: Int64?, expectedBytes: Int64?)
  case extracting(info: SoftwareUpdateInfo?, progress: Double?)
  case readyToInstall(SoftwareUpdateInfo)
  case installing(SoftwareUpdateInfo?)
  case upToDate
  case failed(message: String)

  var statusText: String {
    switch self {
    case .idle:
      "Ready"
    case .checking:
      "Checking for updates"
    case .updateAvailable:
      "Update available"
    case .downloading:
      "Downloading update"
    case .extracting:
      "Preparing update"
    case .readyToInstall:
      "Downloaded and ready to install"
    case .installing:
      "Installing update"
    case .upToDate:
      "You're up to date"
    case .failed:
      "Update failed"
    }
  }

  var menuTitle: String {
    switch self {
    case .idle, .upToDate:
      return "Check for Updates…"
    case .checking:
      return "Checking for Updates…"
    case let .updateAvailable(info):
      return "Update \(info.version) Available…"
    case let .downloading(_, receivedBytes, expectedBytes):
      if let receivedBytes, let expectedBytes, expectedBytes > 0 {
        let progress = min(100, max(0, Int(Double(receivedBytes) / Double(expectedBytes) * 100)))
        return "Downloading Update… \(progress)%"
      }
      return "Downloading Update…"
    case .extracting:
      return "Preparing Update…"
    case .readyToInstall:
      return "Restart to Update…"
    case .installing:
      return "Installing Update…"
    case .failed:
      return "Retry Update Check…"
    }
  }

  var info: SoftwareUpdateInfo? {
    switch self {
    case let .updateAvailable(info), let .readyToInstall(info):
      info
    case let .downloading(info, _, _), let .extracting(info, _), let .installing(info):
      info
    case .idle, .checking, .upToDate, .failed:
      nil
    }
  }

  var isBusy: Bool {
    switch self {
    case .checking, .downloading, .extracting, .installing:
      true
    case .idle, .updateAvailable, .readyToInstall, .upToDate, .failed:
      false
    }
  }
}

#if DEBUG || DEBUG_BUILD
enum DebugSoftwareUpdatePreview: String, CaseIterable, Identifiable {
  case checking
  case updateAvailable
  case informationalUpdate
  case downloading
  case preparing
  case readyToInstall
  case installing
  case upToDate
  case failed

  var id: String { rawValue }

  var title: String {
    switch self {
    case .checking:
      "Checking"
    case .updateAvailable:
      "Update Available"
    case .informationalUpdate:
      "Informational Update"
    case .downloading:
      "Downloading"
    case .preparing:
      "Preparing"
    case .readyToInstall:
      "Ready to Install"
    case .installing:
      "Installing"
    case .upToDate:
      "Up to Date"
    case .failed:
      "Error"
    }
  }

  var phase: SoftwareUpdatePhase {
    let info = SoftwareUpdateInfo(
      version: "1.12.0",
      build: "1120",
      contentLength: 28_400_000,
      informationURL: nil
    )

    return switch self {
    case .checking:
      .checking
    case .updateAvailable:
      .updateAvailable(info)
    case .informationalUpdate:
      .updateAvailable(
        SoftwareUpdateInfo(
          version: "1.12.0",
          build: "1120",
          contentLength: nil,
          informationURL: URL(string: "https://inline.chat")
        )
      )
    case .downloading:
      .downloading(info: info, receivedBytes: 17_600_000, expectedBytes: info.contentLength)
    case .preparing:
      .extracting(info: info, progress: 0.72)
    case .readyToInstall:
      .readyToInstall(info)
    case .installing:
      .installing(info)
    case .upToDate:
      .upToDate
    case .failed:
      .failed(message: "Inline couldn’t connect to the update server. Check your internet connection and try again.")
    }
  }
}
#endif
#endif
