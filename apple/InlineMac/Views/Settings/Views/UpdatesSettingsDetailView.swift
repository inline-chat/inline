import SwiftUI

struct UpdatesSettingsDetailView: View {
#if SPARKLE
  @Environment(UpdateController.self) private var updates
#endif

  var body: some View {
#if SPARKLE
    @Bindable var updates = updates
#endif
    Form {
#if SPARKLE
      Section("Status") {
        LabeledContent("Current Status", value: updates.phase.statusText)

        if let lastCheckDate = updates.lastCheckDate {
          LabeledContent("Last Checked") {
            Text(lastCheckDate, style: .relative)
          }
        }

        if let nextCheckDate = updates.nextScheduledCheckDate, updates.mode != .off {
          LabeledContent("Next Check") {
            Text(nextCheckDate, style: .relative)
          }
        }

        if case let .downloading(_, receivedBytes, expectedBytes) = updates.phase {
          if let receivedBytes, let expectedBytes, expectedBytes > 0 {
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
        } else if updates.phase.isBusy {
          ProgressView()
            .frame(maxWidth: .infinity, alignment: .leading)
        }

        if let info = updates.phase.info {
          Text(info.versionLine)
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        if case let .failed(message) = updates.phase {
          Text(message)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }

      Section("Automatic Updates") {
        Picker("Automatic Updates", selection: $updates.mode) {
          ForEach(AutoUpdateMode.allCases) { mode in
            Text(mode.title).tag(mode)
          }
        }
        .pickerStyle(.menu)

        Picker("Update Channel", selection: $updates.channel) {
          ForEach(AutoUpdateChannel.allCases) { channel in
            Text(channel.title).tag(channel)
          }
        }
        .pickerStyle(.menu)
      }

      Section {
        Button(updates.phase.menuTitle) {
          updates.performPrimaryAction()
        }
        .disabled(!updates.allowsPrimaryAction)
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
  private func byteString(for bytes: Int64) -> String {
    let formatter = ByteCountFormatter()
    formatter.countStyle = .file
    return formatter.string(fromByteCount: bytes)
  }
#endif
}

#Preview {
#if SPARKLE
  UpdatesSettingsDetailView()
    .environment(UpdateController())
#else
  UpdatesSettingsDetailView()
#endif
}
