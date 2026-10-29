import SwiftUI

struct UpdatesSettingsDetailView: View {
  @Environment(CLIUpdateController.self) private var cliUpdates
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
      cliUpdateSection
    }
    .settingsFormStyle()
    .task { await cliUpdates.refresh(automatic: false) }
  }

  @ViewBuilder
  private var cliUpdateSection: some View {
    @Bindable var cliUpdates = cliUpdates
    if cliUpdates.hasInstallation {
      Section {
        if cliUpdates.canManage {
          Toggle(isOn: $cliUpdates.automaticUpdatesEnabled) {
            SettingsRowLabel("Update Inline CLI Automatically", description: "Keeps the command-line tool and agent bridge on the latest release for your channel.")
          }
        }
        LabeledContent("CLI Status") {
          Text(cliUpdates.statusText).foregroundStyle(.secondary)
        }
        if let version = cliUpdates.versionText { SettingsDetailText(text: version) }
        if cliUpdates.canManage && !cliUpdates.followsAppChannel {
          Button("Use App Update Channel") { cliUpdates.useAppChannel() }
            .disabled(cliUpdates.isBusy)
        }
        if let bridgeVersions = cliUpdates.bridgeVersionText { SettingsDetailText(text: bridgeVersions) }
        if !cliUpdates.canManage && !cliUpdates.homebrewManaged {
          SettingsDetailText(text: "A writable, managed CLI installation is required for automatic updates.")
        }
        if cliUpdates.homebrewManaged {
          SettingsDetailText(text: "Homebrew manages the Terminal CLI. Managed agent bridges update separately.")
          Text("brew upgrade --cask inline").font(.system(.caption, design: .monospaced)).textSelection(.enabled)
        }
        if cliUpdates.bridgeMigrationRequired {
          SettingsDetailText(text: "Once active agent work finishes, run this command to enable bridge auto-updates:")
          Text("inline bridge restart").font(.system(.caption, design: .monospaced)).textSelection(.enabled)
        }
        if let failure = cliUpdates.failureText { SettingsDetailText(text: failure) }
        if cliUpdates.canManage {
          Button(cliUpdates.updateAvailable && !cliUpdates.automaticUpdatesEnabled ? "Update CLI" : "Check Now") {
            if cliUpdates.updateAvailable && !cliUpdates.automaticUpdatesEnabled { cliUpdates.applyNow() }
            else { cliUpdates.checkNow() }
          }
          .disabled(cliUpdates.isBusy)
        }
      } header: { SettingsSectionHeader("Inline CLI") }
    }
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
        SettingsRowLabel(.automaticUpdates)
      }
      .settingsSearchAnchor(.automaticUpdates)

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
          .updateChannel,
          description: "Beta receives preview releases; Tip receives the latest builds several times a day."
        )
      }
      .settingsSearchAnchor(.updateChannel)
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
        SettingsRowLabel(.softwareUpdate)
      }
      .settingsSearchAnchor(.softwareUpdate)
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
    .environment(CLIUpdateController(installer: .init(), channel: { .stable }))
#else
  UpdatesSettingsDetailView()
    .environment(CLIUpdateController(installer: .init(), channel: { .stable }))
#endif
}
