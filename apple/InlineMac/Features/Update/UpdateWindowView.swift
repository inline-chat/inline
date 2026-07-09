#if SPARKLE
import Foundation
import SwiftUI

struct UpdateWindowView: View {
  let controller: UpdateController

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text(title)
        .font(.title2)
        .fontWeight(.semibold)

      content
    }
    .padding(20)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }

  @ViewBuilder
  private var content: some View {
    switch controller.phase {
    case .idle:
      Text("Inline checks for updates automatically in the background.")
        .foregroundStyle(.secondary)
    case .checking:
      VStack(alignment: .leading, spacing: 12) {
        ProgressView()
        if controller.canCancelCurrentOperation {
          Button("Cancel") { controller.cancel() }
        }
      }
    case let .updateAvailable(info):
      VStack(alignment: .leading, spacing: 12) {
        Text("Version \(info.version) is available.")
        if let build = info.build {
          Text("Build \(build)")
            .foregroundStyle(.secondary)
        }
        if let size = info.contentLength {
          Text("Download size: \(byteString(for: size))")
            .foregroundStyle(.secondary)
        }
        HStack {
          Button("Skip This Version") { controller.skipVersion() }
          Button("Later") { controller.remindLater() }
          Spacer()
          Button(info.isInformational ? "Learn More" : "Install and Relaunch") {
            controller.beginUpdate()
          }
            .keyboardShortcut(.defaultAction)
        }
      }
    case let .downloading(_, receivedBytes, expectedBytes):
      VStack(alignment: .leading, spacing: 12) {
        if let receivedBytes, let expectedBytes, expectedBytes > 0 {
          ProgressView(value: progress(received: receivedBytes, expected: expectedBytes))
          Text("\(byteString(for: receivedBytes)) of \(byteString(for: expectedBytes))")
            .foregroundStyle(.secondary)
        } else {
          ProgressView()
        }
        if controller.canCancelCurrentOperation {
          Button("Cancel") { controller.cancel() }
        }
      }
    case let .extracting(_, progress):
      VStack(alignment: .leading, spacing: 12) {
        if let progress {
          ProgressView(value: progress)
        } else {
          ProgressView()
        }
        Text("Preparing update…")
          .foregroundStyle(.secondary)
      }
    case let .readyToInstall(info):
      VStack(alignment: .leading, spacing: 12) {
        Text("\(info.versionLine) is downloaded and ready.")
        HStack {
          Spacer()
          Button("Restart to Update") { controller.installAndRelaunch() }
            .keyboardShortcut(.defaultAction)
        }
      }
    case .installing:
      VStack(alignment: .leading, spacing: 12) {
        ProgressView()
        Text("Installing update…")
          .foregroundStyle(.secondary)
        if controller.canRetryTermination {
          Button("Retry") { controller.retryTermination() }
        }
      }
    case .upToDate:
      VStack(alignment: .leading, spacing: 12) {
        Text("You’re up to date.")
        Button("OK") { controller.dismissStatus() }
          .keyboardShortcut(.defaultAction)
      }
    case let .failed(message):
      VStack(alignment: .leading, spacing: 12) {
        Text(message)
        HStack {
          Button("Dismiss") { controller.dismissStatus() }
          Button("Retry") { controller.retryCheck() }
            .keyboardShortcut(.defaultAction)
        }
      }
    }
  }

  private var title: String {
    switch controller.phase {
    case .idle:
      return "Updates"
    case .checking:
      return "Checking for Updates"
    case .updateAvailable:
      return "Update Available"
    case .downloading:
      return "Downloading Update"
    case .extracting:
      return "Preparing Update"
    case .readyToInstall:
      return "Ready to Install"
    case .installing:
      return "Installing Update"
    case .upToDate:
      return "No Update Available"
    case .failed:
      return "Update Error"
    }
  }

  private func progress(received: Int64, expected: Int64) -> Double {
    guard expected > 0 else { return 0 }
    return min(1, Double(received) / Double(expected))
  }

  private func byteString(for bytes: Int64) -> String {
    let formatter = ByteCountFormatter()
    formatter.countStyle = .file
    return formatter.string(fromByteCount: bytes)
  }
}
#endif
