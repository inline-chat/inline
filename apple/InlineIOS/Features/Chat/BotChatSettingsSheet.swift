import InlineKit
import InlineUI
import SwiftUI

/// Agent Settings: the agent, this chat's output, the provider's settings,
/// then usage. Same arrangement as the Mac popover (`BotChatSettingsLayout`).
struct BotChatSettingsSheet: View {
  let coordinator: BotChatSettingsCoordinator

  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      BotChatSettingsSheetContent(coordinator: coordinator)
        .navigationTitle("Agent Settings")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
          ToolbarItem(placement: .confirmationAction) {
            Button("Done") { dismiss() }
          }
        }
    }
    .task(id: coordinator.selectedBotID) {
      coordinator.refreshSelectedIfStale()
      if let botUserID = coordinator.selectedBotID {
        await AgentWorkStateStore.shared.loadOutputModes(peer: coordinator.peer, botUserID: botUserID)
      }
    }
  }
}

private struct BotChatSettingsSheetContent: View {
  let coordinator: BotChatSettingsCoordinator
  @ObservedObject private var agentWork = AgentWorkStateStore.shared

  /// Output mode applies to agents that report a runtime (the bridge) or
  /// declare the Output capability (the Hermes and OpenClaw plugins).
  private var outputModeBotUserID: Int64? {
    coordinator.selectedBotID.flatMap {
      agentWork.runtimeBotUserIDs.contains($0) || coordinator.outputModeBotIDs.contains($0) ? $0 : nil
    }
  }

  var body: some View {
    let state = coordinator.selectedState
    if let document = state.document {
      let layout = BotChatSettingsLayout(document: document)
      Form {
        BotChatSettingsAgentSection(coordinator: coordinator)
        if case let .problem(problem)? = state.surfaceStatus {
          BotChatSettingsIOSProblemSection(problem: problem, onRetry: coordinator.refreshSelected)
        }
        if let botUserID = outputModeBotUserID {
          AgentOutputModeSection(peer: coordinator.peer, botUserID: botUserID)
        }
        ForEach(layout.sections) { section in
          BotChatSettingsIOSSection(
            section: section,
            pendingItemIDs: state.pendingItemIDs,
            sharedReason: layout.accessNote,
            onInvoke: coordinator.invoke(itemID:value:)
          )
        }
        if layout.hasUsage {
          BotChatSettingsIOSUsageSection(
            layout: layout,
            pendingItemIDs: state.pendingItemIDs,
            onInvoke: coordinator.invoke(itemID:value:)
          )
        }
        if let accessNote = layout.accessNote {
          Section {} footer: {
            Label(accessNote, systemImage: "lock")
          }
        }
      }
      .refreshable { coordinator.refreshSelected() }
    } else if state.phase == .loading || state.phase == .idle {
      ProgressView()
        .accessibilityLabel("Loading agent settings")
    } else if let problem = state.problem {
      ContentUnavailableView {
        Label(problem.message, systemImage: "exclamationmark.triangle")
      } actions: {
        Button("Retry", action: coordinator.refreshSelected)
      }
    } else {
      ContentUnavailableView(
        "No Settings",
        systemImage: "slider.horizontal.3",
        description: Text("This agent has no settings for this chat.")
      )
    }
  }
}

/// Who these settings are for; a switcher when the chat has several agents.
private struct BotChatSettingsAgentSection: View {
  let coordinator: BotChatSettingsCoordinator

  var body: some View {
    if let selectedBot = coordinator.selectedBot {
      Section {
        if coordinator.bots.count > 1 {
          Picker(selection: Binding(
            get: { selectedBot.id },
            set: { coordinator.selectBot($0) }
          )) {
            ForEach(coordinator.bots) { bot in
              Text(bot.displayName).tag(bot.id)
            }
          } label: {
            BotChatSettingsIOSAgentLabel(bot: selectedBot)
          }
          .pickerStyle(.menu)
          .accessibilityLabel("Choose agent")
        } else {
          BotChatSettingsIOSAgentLabel(bot: selectedBot)
        }
      }
    }
  }
}

private struct BotChatSettingsIOSAgentLabel: View {
  let bot: BotChatSettingsBot

  var body: some View {
    HStack(spacing: 10) {
      UserAvatar(user: User(from: bot.user), size: 28)
      Text(bot.displayName)
        .font(.headline)
        .lineLimit(1)
    }
    .accessibilityElement(children: .combine)
  }
}

private struct BotChatSettingsIOSProblemSection: View {
  let problem: BotChatSettingsProblem
  let onRetry: () -> Void

  var body: some View {
    Section {
      HStack(spacing: 10) {
        Image(systemName: "exclamationmark.triangle.fill")
          .foregroundStyle(.orange)
          .accessibilityHidden(true)
        Text(problem.message)
          .frame(maxWidth: .infinity, alignment: .leading)
        Button("Retry", action: onRetry)
          .buttonStyle(.borderless)
      }
    }
  }
}

private struct BotChatSettingsIOSSection: View {
  let section: BotChatSettingsModel.Section
  let pendingItemIDs: Set<String>
  let sharedReason: String?
  let onInvoke: (String, BotChatSettingsMutationValue?) -> Void

  var body: some View {
    Section {
      ForEach(section.items) { item in
        BotChatSettingsIOSItem(
          item: item,
          isPending: pendingItemIDs.contains(item.id),
          showsDisabledReason: item.disabledReason != sharedReason,
          onInvoke: onInvoke
        )
      }
    } header: {
      if let title = section.title { Text(title) }
    } footer: {
      if let description = section.description { Text(description) }
    }
  }
}

/// Limits and the context window as bars, with Compact beside the context.
private struct BotChatSettingsIOSUsageSection: View {
  let layout: BotChatSettingsLayout
  let pendingItemIDs: Set<String>
  let onInvoke: (String, BotChatSettingsMutationValue?) -> Void

  var body: some View {
    Section("Usage") {
      ForEach(layout.meters) { meter in
        VStack(alignment: .leading, spacing: 6) {
          HStack(spacing: 8) {
            Text(meter.title)
              .frame(maxWidth: .infinity, alignment: .leading)
            Text(meter.value)
              .monospacedDigit()
              .foregroundStyle(meter.isHigh ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
          }
          ProgressView(value: min(1, max(0, meter.fraction)))
            .tint(meter.isHigh ? .orange : .accentColor)
            .accessibilityHidden(true)
          if let detail = meter.detail {
            Text(detail)
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
        .accessibilityElement(children: .combine)
      }
      if let summary = layout.usageSummary, case let .info(text, tone) = summary.control {
        VStack(alignment: .leading, spacing: 4) {
          LabeledContent("Account") {
            Text(text)
              .foregroundStyle(tone == .warning ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
          }
          if let details = summary.description {
            Text(details)
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
      }
      if let action = layout.contextAction {
        HStack {
          Button(action.label ?? String(localized: "Compact Context")) { onInvoke(action.id, nil) }
            .disabled(action.isDisabled || pendingItemIDs.contains(action.id))
          Spacer()
          if pendingItemIDs.contains(action.id) {
            ProgressView()
          }
        }
      }
    }
  }
}

private struct BotChatSettingsIOSItem: View {
  let item: BotChatSettingsModel.Item
  let isPending: Bool
  let showsDisabledReason: Bool
  let onInvoke: (String, BotChatSettingsMutationValue?) -> Void

  private var label: String { item.label ?? "" }

  /// Phones can't hover, so a locked control's own reason shows under it.
  private var note: String? {
    if item.isDisabled, showsDisabledReason, let reason = item.disabledReason { return reason }
    switch item.control {
    case .toggle, .button: return item.description
    default: return nil
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      control
      if let note {
        Text(note)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
  }

  @ViewBuilder
  private var control: some View {
    switch item.control {
    case let .toggle(value):
      HStack {
        Toggle(label, isOn: Binding(
          get: { value },
          set: { onInvoke(item.id, .bool($0)) }
        ))
        pendingIndicator
      }
      .disabled(item.isDisabled)
    case let .select(value, options):
      HStack {
        Picker(label, selection: Binding(
          get: { value },
          set: { onInvoke(item.id, .string($0)) }
        )) {
          ForEach(options) { option in
            Text(option.label)
              .tag(option.value)
              .disabled(option.isDisabled)
          }
        }
        .pickerStyle(.menu)
        pendingIndicator
      }
      .disabled(item.isDisabled)
    case let .info(text, tone):
      if let label = item.label, text.count <= 28 {
        LabeledContent(label) {
          HStack(spacing: 4) {
            toneIcon(tone)
            Text(text)
          }
        }
      } else {
        Label {
          VStack(alignment: .leading, spacing: 2) {
            if let label = item.label { Text(label) }
            Text(text).foregroundStyle(.secondary)
          }
        } icon: {
          toneIcon(tone)
        }
        .accessibilityElement(children: .combine)
      }
    case .button:
      HStack {
        Button(label) { onInvoke(item.id, nil) }
          .disabled(item.isDisabled || isPending)
        Spacer()
        pendingIndicator
      }
    case .folder:
      if let folder = item.control.folderPresentation {
        HStack {
          BotChatSettingsIOSFolderControl(
            label: label,
            presentation: folder,
            isDisabled: item.isDisabled,
            onSelect: { onInvoke(item.id, .string($0)) }
          )
          pendingIndicator
        }
      }
    }
  }

  @ViewBuilder
  private var pendingIndicator: some View {
    if isPending {
      ProgressView()
        .accessibilityLabel("Updating \(label)")
    }
  }

  @ViewBuilder
  private func toneIcon(_ tone: BotChatSettingsModel.InfoTone) -> some View {
    switch tone {
    case .neutral: EmptyView()
    case .success: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
    case .warning: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
    case .error: Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
    }
  }
}

/// Recent folders on the agent's machine; adding one happens there.
private struct BotChatSettingsIOSFolderControl: View {
  let label: String
  let presentation: BotChatSettingsModel.FolderPresentation
  let isDisabled: Bool
  let onSelect: (String) -> Void

  var body: some View {
    Menu {
      Section("On \(presentation.hostLabel)") {
        ForEach(presentation.recentFolders) { folder in
          Button {
            onSelect(folder.value)
          } label: {
            if folder.value == presentation.selectedFolder.value {
              Label(folder.label, systemImage: "checkmark")
            } else {
              Text(folder.label)
            }
            if let parentHint = folder.parentHint { Text(parentHint) }
          }
          .disabled(folder.isDisabled)
        }
      }
      Section(presentation.remotePickerMessage) {
        Text(presentation.commandFallback)
      }
    } label: {
      LabeledContent(label, value: presentation.selectedFolder.label)
    }
    .disabled(isDisabled)
    .accessibilityValue(presentation.selectedFolder.label)
  }
}
