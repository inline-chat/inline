import AppKit
import SwiftUI

struct UpdatesSettingsDetailView: View {
  @StateObject private var appSettings = AppSettings.shared
  @EnvironmentObject private var updateInstallState: UpdateInstallState

  var body: some View {
    Form {
      #if SPARKLE
      Section("Status") {
        LabeledContent("Current Status", value: updateInstallState.status.statusText)

        if updateInstallState.status.showsIndeterminateProgress {
          ProgressView()
            .frame(maxWidth: .infinity, alignment: .leading)
        }

        if case let .downloading(receivedBytes, expectedBytes) = updateInstallState.status {
          if let expectedBytes, expectedBytes > 0 {
            ProgressView(
              value: min(1, Double(receivedBytes) / Double(expectedBytes))
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            Text("\(byteString(for: receivedBytes)) of \(byteString(for: expectedBytes))")
              .font(.caption)
              .foregroundStyle(.secondary)
          } else {
            ProgressView()
              .frame(maxWidth: .infinity, alignment: .leading)
          }
        }

        if case let .updateAvailable(version, build) = updateInstallState.status {
          Text(versionLine(version: version, build: build))
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        if case let .readyToInstall(version, build) = updateInstallState.status {
          Text(versionLine(version: version, build: build))
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        if case let .failed(message) = updateInstallState.status {
          Text(message)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }

      Section("Automatic Updates") {
        Picker("Automatic Updates", selection: $appSettings.autoUpdateMode) {
          ForEach(AutoUpdateMode.allCases) { mode in
            Text(mode.title).tag(mode)
          }
        }
        .pickerStyle(.menu)

        Picker("Update Channel", selection: $appSettings.autoUpdateChannel) {
          ForEach(AutoUpdateChannel.allCases) { channel in
            Text(channel.title).tag(channel)
          }
        }
        .pickerStyle(.menu)
      }

      Section {
        Button(primaryActionTitle) {
          performPrimaryAction()
        }
        .disabled(!updateInstallState.status.allowsManualAction)
      }
      #else
      Section {
        Text("Updates are unavailable in this build.")
          .foregroundStyle(.secondary)
      }
      #endif
    }
    .formStyle(.grouped)
    .scrollContentBackground(.hidden)
  }

  #if SPARKLE
  private var primaryActionTitle: String {
    if updateInstallState.status.isReadyToInstall {
      return "Install and Relaunch"
    }
    return "Check for Updates..."
  }

  private func performPrimaryAction() {
    if updateInstallState.status.isReadyToInstall {
      updateInstallState.install()
      return
    }
    (NSApp.delegate as? AppDelegate)?.checkForUpdates(nil)
  }

  private func byteString(for bytes: Int64) -> String {
    let formatter = ByteCountFormatter()
    formatter.countStyle = .file
    return formatter.string(fromByteCount: bytes)
  }

  private func versionLine(version: String?, build: String?) -> String {
    let versionText = version ?? "Unknown version"
    if let build, !build.isEmpty {
      return "Version \(versionText) (\(build))"
    }
    return "Version \(versionText)"
  }
  #endif
}

#Preview {
  UpdatesSettingsDetailView()
    .environmentObject(UpdateInstallState())
}
