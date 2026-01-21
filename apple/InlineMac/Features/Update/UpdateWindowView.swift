#if SPARKLE
import Foundation
import SwiftUI

struct UpdateWindowView: View {
  @ObservedObject var viewModel: UpdateViewModel

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
    switch viewModel.state {
    case .idle:
      Text("Idle")
        .foregroundStyle(.secondary)
    case .permission(let state):
      Text(state.message)
      HStack {
        Button("Not Now") { state.deny() }
        Button("Allow Updates") { state.allow() }
          .keyboardShortcut(.defaultAction)
      }
    case .checking(let state):
      VStack(alignment: .leading, spacing: 12) {
        ProgressView()
        HStack {
          Button("Cancel") { state.cancel() }
        }
      }
    case .updateAvailable(let state):
      VStack(alignment: .leading, spacing: 12) {
        Text("Version \(state.version) is available.")
        if let build = state.build {
          Text("Build \(build)")
            .foregroundStyle(.secondary)
        }
        if let size = state.contentLength {
          Text("Download size: \(byteString(for: size))")
            .foregroundStyle(.secondary)
        }
        HStack {
          Button("Later") { state.later() }
          Button("Install and Relaunch") { state.install() }
            .keyboardShortcut(.defaultAction)
        }
      }
    case .downloading(let state):
      VStack(alignment: .leading, spacing: 12) {
        if let expected = state.expectedLength, expected > 0 {
          ProgressView(value: progress(received: state.receivedLength, expected: expected))
          Text("\(byteString(for: state.receivedLength)) of \(byteString(for: expected))")
            .foregroundStyle(.secondary)
        } else {
          ProgressView()
        }
        HStack {
          Button("Cancel") { state.cancel() }
        }
      }
    case .extracting(let state):
      VStack(alignment: .leading, spacing: 12) {
        ProgressView(value: state.progress)
        Text("Preparing update…")
          .foregroundStyle(.secondary)
      }
    case .readyToInstall(let state):
      VStack(alignment: .leading, spacing: 12) {
        Text("Update is ready to install.")
        HStack {
          Button("Later") { state.later() }
          Button("Install and Relaunch") { state.install() }
            .keyboardShortcut(.defaultAction)
        }
      }
    case .installing(let state):
      VStack(alignment: .leading, spacing: 12) {
        ProgressView()
        Text("Installing update…")
          .foregroundStyle(.secondary)
        HStack {
          Button("Retry") { state.retryTerminatingApplication() }
          Button("Dismiss") { state.dismiss() }
        }
      }
    case .notFound(let state):
      VStack(alignment: .leading, spacing: 12) {
        Text("You’re up to date.")
        Button("OK") { state.acknowledgement() }
          .keyboardShortcut(.defaultAction)
      }
    case .error(let state):
      VStack(alignment: .leading, spacing: 12) {
        Text(state.message)
        HStack {
          Button("Dismiss") { state.dismiss() }
          Button("Retry") { state.retry() }
            .keyboardShortcut(.defaultAction)
        }
      }
    }
  }

  private var title: String {
    switch viewModel.state {
    case .idle:
      return "Updates"
    case .permission:
      return "Enable Updates"
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
    case .notFound:
      return "No Update Available"
    case .error:
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
