import SwiftUI

struct UpdatesSettingsDetailView: View {
#if SPARKLE
  @Environment(UpdateController.self) private var updates
#endif

  var body: some View {
    Form {
      #if SPARKLE
      updateSections
      #else
      Section {
        SettingsEmptyRow(
          "Updates Unavailable",
          description: "This build does not include the software update service.",
          systemImage: "arrow.triangle.2.circlepath"
        )
      }
      #endif
    }
    .settingsFormStyle()
  }

  #if SPARKLE
  @ViewBuilder
  private var updateSections: some View {
    @Bindable var updates = updates

    Section {
      LabeledContent {
        Text(updates.phase.statusText)
      } label: {
        SettingsRowLabel("Current Status")
      }

      if let lastCheckDate = updates.lastCheckDate {
        LabeledContent {
          Text(lastCheckDate, style: .relative)
        } label: {
          SettingsRowLabel("Last Checked")
        }
      }

      if let nextCheckDate = updates.nextScheduledCheckDate, updates.mode != .off {
        LabeledContent {
          Text(nextCheckDate, style: .relative)
        } label: {
          SettingsRowLabel("Next Check")
        }
      }

      if updates.phase.isBusy {
        SettingsLoadingRow(updates.phase.loadingTitle)
      }

      if case let .downloading(_, receivedBytes, expectedBytes) = updates.phase,
         let receivedBytes,
         let expectedBytes,
         expectedBytes > 0 {
        ProgressView(value: min(1, Double(receivedBytes) / Double(expectedBytes)))
          .frame(maxWidth: .infinity, alignment: .leading)
        SettingsDetailText(
          text: "\(byteString(for: receivedBytes)) of \(byteString(for: expectedBytes))"
        )
      }

      if let info = updates.phase.info {
        SettingsDetailText(text: info.versionLine)
      }

      if case let .failed(message) = updates.phase {
        SettingsErrorRow("Update Failed", message: message)
      }
    } header: {
      SettingsSectionHeader("Status")
    }

    Section {
      LabeledContent {
        Picker("Automatic Updates", selection: $updates.mode) {
          ForEach(AutoUpdateMode.allCases) { mode in
            Text(mode.title).tag(mode)
          }
        }
        .labelsHidden()
        .pickerStyle(.menu)
      } label: {
        SettingsRowLabel("Automatic Updates")
      }

      LabeledContent {
        Picker("Update Channel", selection: $updates.channel) {
          ForEach(AutoUpdateChannel.allCases) { channel in
            Text(channel.title).tag(channel)
          }
        }
        .labelsHidden()
        .pickerStyle(.menu)
      } label: {
        SettingsRowLabel(
          "Update Channel",
          description: "Stable receives regular releases; Beta receives preview releases."
        )
      }
    } header: {
      SettingsSectionHeader("Automatic Updates")
    }

    Section {
      LabeledContent {
        Button(updates.phase.menuTitle) {
          updates.performPrimaryAction()
        }
        .disabled(!updates.allowsPrimaryAction)
      } label: {
        SettingsRowLabel("Software Update")
      }
    }
  }

  private func byteString(for bytes: Int64) -> String {
    let formatter = ByteCountFormatter()
    formatter.countStyle = .file
    return formatter.string(fromByteCount: bytes)
  }
  #endif
}

#if SPARKLE
private extension SoftwareUpdatePhase {
  var loadingTitle: LocalizedStringResource {
    switch self {
    case .checking:
      "Checking for Updates"
    case .extracting:
      "Preparing Update"
    case .installing:
      "Installing Update"
    case .downloading:
      "Downloading Update"
    default:
      "Working"
    }
  }
}
#endif

#Preview {
#if SPARKLE
  UpdatesSettingsDetailView()
    .environment(UpdateController())
#else
  UpdatesSettingsDetailView()
#endif
}
