import InlineCLIInstaller
import SwiftUI

struct UpdatesSettingsDetailView: View {
  @Environment(CLIUpdateController.self) private var cliUpdates
  @State private var pendingBridgeConfirmation: BridgeConfirmation?
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
      bridgeSection
    }
    .settingsFormStyle()
    .task {
      await cliUpdates.refresh(automatic: false)
      await cliUpdates.refreshBridges()
    }
    .confirmationDialog(
      Text(pendingBridgeConfirmation?.title ?? ""),
      isPresented: Binding(
        get: { pendingBridgeConfirmation != nil },
        set: { if !$0 { pendingBridgeConfirmation = nil } }
      ),
      presenting: pendingBridgeConfirmation
    ) { confirmation in
      Button(confirmation.actionTitle) { perform(confirmation) }
      Button("Cancel", role: .cancel) {}
    } message: { confirmation in
      Text(confirmation.message)
    }
    .sheet(isPresented: Binding(
      get: { cliUpdates.bridgeLogs != nil },
      set: { if !$0 { cliUpdates.dismissBridgeLogs() } }
    )) {
      BridgeLogsSheet(lines: cliUpdates.bridgeLogs ?? []) { cliUpdates.dismissBridgeLogs() }
    }
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
        if !cliUpdates.canManage && !cliUpdates.homebrewManaged {
          SettingsDetailText(text: "A writable, managed CLI installation is required for automatic updates.")
        }
        if cliUpdates.homebrewManaged {
          SettingsDetailText(text: "Homebrew manages the Terminal CLI. Managed agent bridges update separately.")
          Text("brew upgrade --cask inline").font(.system(.caption, design: .monospaced)).textSelection(.enabled)
        }
        if let failure = cliUpdates.failureText { SettingsDetailText(text: failure) }
        if cliUpdates.canManage {
          HStack {
            if cliUpdates.updateReady || cliUpdates.updateAvailable {
              Button("Update Now") {
                if cliUpdates.installedBridges.isEmpty { cliUpdates.updateNow() }
                else { pendingBridgeConfirmation = .update }
              }
            }
            Button("Check Now") { cliUpdates.checkNow() }
          }
          .disabled(cliUpdates.isBusy || cliUpdates.bridgeAction != nil)
        }
      } header: { SettingsSectionHeader("Inline CLI") }
    }
  }

  @ViewBuilder
  private var bridgeSection: some View {
    if cliUpdates.hasInstallation {
      Section {
        let bridges = cliUpdates.installedBridges
        if bridges.isEmpty {
          if cliUpdates.bridgeAction == nil {
            SettingsEmptyRow(
              "No Agent Bridge",
              description: "Set up an agent to run it from this Mac.",
              systemImage: "point.3.connected.trianglepath.dotted"
            )
          }
        } else {
          ForEach(bridges) { bridge in BridgeStatusRow(bridge: bridge) }
        }
        // Routine status checks keep the last known rows instead of flashing a spinner.
        if let action = cliUpdates.bridgeAction, action != .checking || bridges.isEmpty {
          SettingsLoadingRow(action.title)
        }
        if let versions = cliUpdates.bridgeVersionText { SettingsDetailText(text: versions) }
        if cliUpdates.bridgeMigrationRequired {
          SettingsDetailText(text: "Restart the bridge once agents finish their current work to enable bridge auto-updates.")
        }
        if let failure = cliUpdates.bridgeFailureText {
          SettingsErrorRow("Bridge Command Failed", message: failure)
        }
        if !bridges.isEmpty {
          HStack {
            Button("Restart…") { pendingBridgeConfirmation = .restart }
            if bridges.allSatisfy({ $0.status == "stopped" }) {
              Button("Start") { cliUpdates.controlBridge(.start) }
            } else {
              Button("Stop…") { pendingBridgeConfirmation = .stop }
            }
            Button("Show Logs") { cliUpdates.showBridgeLogs() }
            Button("Refresh") { Task { await cliUpdates.refreshBridges() } }
          }
          .disabled(cliUpdates.isBusy || cliUpdates.bridgeAction != nil)
        }
      } header: {
        SettingsSectionHeader("Agent Bridge", subtitle: "Runs your agents in the background on this Mac.")
      }
    }
  }

  private func perform(_ confirmation: BridgeConfirmation) {
    switch confirmation {
    case .restart: cliUpdates.controlBridge(.restart)
    case .stop: cliUpdates.controlBridge(.stop)
    case .update: cliUpdates.updateNow()
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

private enum BridgeConfirmation {
  case restart, stop, update

  var title: LocalizedStringResource {
    switch self {
    case .restart: "Restart the agent bridge?"
    case .stop: "Stop the agent bridge?"
    case .update: "Update the CLI and restart the agent bridge?"
    }
  }

  var message: LocalizedStringResource {
    switch self {
    case .stop: "Agents won’t reply until the bridge is started again. Any reply in progress is interrupted."
    case .restart, .update: "Agents stop replying while the bridge restarts. Any reply in progress is interrupted."
    }
  }

  var actionTitle: LocalizedStringResource {
    switch self {
    case .restart: "Restart"
    case .stop: "Stop"
    case .update: "Update and Restart"
    }
  }
}

private struct BridgeStatusRow: View {
  let bridge: CLIBridgeStatus

  var body: some View {
    LabeledContent {
      HStack(spacing: 6) {
        Circle().fill(tint).frame(width: 8, height: 8).accessibilityHidden(true)
        Text(label).foregroundStyle(.secondary)
      }
    } label: {
      SettingsRowLabel("\(bridge.displayName ?? bridge.provider.capitalized)", dynamicDescription: description)
    }
  }

  private var description: String {
    var parts: [String] = []
    if let username = bridge.botUsername { parts.append("@\(username)") }
    if !bridge.healthy, let detail = bridge.detail, !detail.isEmpty { parts.append(detail) }
    return parts.joined(separator: " · ")
  }

  private var label: LocalizedStringResource {
    switch bridge.status {
    case "running": bridge.inlineConnected ? "Running" : "Connecting"
    case "starting": "Starting"
    case "restarting": "Restarting"
    case "stopped": "Stopped"
    case "needs_setup": "Needs Setup"
    case "unhealthy": "Not Responding"
    case "unavailable": "Unavailable"
    default: "\(bridge.status.replacingOccurrences(of: "_", with: " ").capitalized)"
    }
  }

  private var tint: Color {
    if bridge.healthy { return .green }
    switch bridge.status {
    case "stopped": return .secondary
    case "running", "starting", "restarting", "needs_setup": return .orange
    default: return .red
    }
  }
}

private struct BridgeLogsSheet: View {
  let lines: [String]
  let onDone: () -> Void

  var body: some View {
    VStack(spacing: 0) {
      ScrollView {
        Text(lines.isEmpty ? "No recent bridge logs." : lines.joined(separator: "\n"))
          .font(.system(.caption, design: .monospaced))
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(16)
      }
      .defaultScrollAnchor(.bottom)
      Divider()
      HStack(spacing: 8) {
        Button("Copy") {
          NSPasteboard.general.clearContents()
          NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
        }
        .disabled(lines.isEmpty)
        Button("Done", action: onDone).keyboardShortcut(.defaultAction)
      }
      .frame(maxWidth: .infinity, alignment: .trailing)
      .padding(16)
    }
    .frame(width: 640, height: 440)
  }
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
