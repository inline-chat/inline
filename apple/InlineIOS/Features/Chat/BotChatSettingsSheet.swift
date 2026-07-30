import InlineKit
import SwiftUI

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
    }
  }
}

private struct BotChatSettingsSheetContent: View {
  let coordinator: BotChatSettingsCoordinator

  var body: some View {
    let state = coordinator.selectedState
    if state.phase == .loading, state.document == nil {
      ContentUnavailableView {
        Label("Loading Settings", systemImage: "slider.horizontal.3")
      } description: {
        ProgressView()
          .accessibilityLabel("Loading agent settings")
      }
    } else if let document = state.document {
      Form {
        if coordinator.bots.count > 1 {
          BotChatSettingsAgentSection(coordinator: coordinator)
        }
        ForEach(document.sections) { section in
          BotChatSettingsIOSSection(
            section: section,
            pendingItemIDs: state.pendingItemIDs,
            onInvoke: coordinator.invoke(itemID:value:)
          )
        }
        if let problem = state.problem {
          BotChatSettingsIOSProblemSection(problem: problem, onRetry: coordinator.refreshSelected)
        }
      }
      .refreshable { coordinator.refreshSelected() }
      .overlay(alignment: .topTrailing) {
        if state.isRefreshing {
          ProgressView()
            .controlSize(.small)
            .padding()
            .accessibilityLabel("Refreshing agent settings")
        }
      }
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

private struct BotChatSettingsAgentSection: View {
  let coordinator: BotChatSettingsCoordinator

  var body: some View {
    Section("Agent") {
      Picker("Agent", selection: Binding(
        get: { coordinator.selectedBotID ?? 0 },
        set: coordinator.selectBot
      )) {
        ForEach(coordinator.bots) { bot in
          Text(bot.displayName).tag(bot.id)
        }
      }
    }
  }
}

private struct BotChatSettingsIOSProblemSection: View {
  let problem: BotChatSettingsProblem
  let onRetry: () -> Void

  var body: some View {
    Section {
      Label(problem.message, systemImage: "exclamationmark.triangle")
        .foregroundStyle(.orange)
      Button("Retry", action: onRetry)
    }
  }
}

private struct BotChatSettingsIOSSection: View {
  let section: BotChatSettingsModel.Section
  let pendingItemIDs: Set<String>
  let onInvoke: (String, BotChatSettingsMutationValue?) -> Void

  var body: some View {
    Section {
      ForEach(section.items) { item in
        BotChatSettingsIOSItem(
          item: item,
          isPending: pendingItemIDs.contains(item.id),
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

private struct BotChatSettingsIOSItem: View {
  let item: BotChatSettingsModel.Item
  let isPending: Bool
  let onInvoke: (String, BotChatSettingsMutationValue?) -> Void

  private var label: String { item.label ?? "" }

  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      control
      if let description = item.description, !isButton {
        Text(description)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      if item.isDisabled, let reason = item.disabledReason {
        Text(reason)
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
      .accessibilityHint(accessibilityHint)
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
        pendingIndicator
      }
      .disabled(item.isDisabled)
      .accessibilityHint(accessibilityHint)
      if let selectedDescription = options.first(where: { $0.value == value })?.description {
        Text(selectedDescription)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    case let .info(text, tone):
      Label {
        VStack(alignment: .leading, spacing: 2) {
          if let label = item.label { Text(label).font(.subheadline.weight(.semibold)) }
          Text(text).foregroundStyle(.secondary)
        }
      } icon: {
        Image(systemName: infoSymbol(for: tone))
          .foregroundStyle(infoColor(for: tone))
      }
      .accessibilityElement(children: .combine)
    case .button:
      HStack {
        Button(label) { onInvoke(item.id, nil) }
          .disabled(item.isDisabled || isPending)
        pendingIndicator
      }
      if let description = item.description {
        Text(description)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    case .folder:
      if let folder = item.control.folderPresentation {
        BotChatSettingsIOSFolderControl(
          label: label,
          presentation: folder,
          isDisabled: item.isDisabled,
          disabledReason: item.disabledReason,
          onSelect: { onInvoke(item.id, .string($0)) }
        )
        pendingIndicator
      }
    }
  }

  private var isButton: Bool {
    if case .button = item.control { return true }
    return false
  }

  private var accessibilityHint: String {
    item.disabledReason ?? item.description ?? ""
  }

  @ViewBuilder
  private var pendingIndicator: some View {
    ProgressView()
      .controlSize(.small)
      .opacity(isPending ? 1 : 0)
      .accessibilityLabel("Updating \(label)")
      .accessibilityHidden(!isPending)
  }

  private func infoColor(for tone: BotChatSettingsModel.InfoTone) -> Color {
    switch tone {
    case .neutral: .secondary
    case .success: .green
    case .warning: .orange
    case .error: .red
    }
  }

  private func infoSymbol(for tone: BotChatSettingsModel.InfoTone) -> String {
    switch tone {
    case .neutral: "info.circle"
    case .success: "checkmark.circle"
    case .warning: "exclamationmark.triangle"
    case .error: "xmark.octagon"
    }
  }
}

private struct BotChatSettingsIOSFolderControl: View {
  let label: String
  let presentation: BotChatSettingsModel.FolderPresentation
  let isDisabled: Bool
  let disabledReason: String?
  let onSelect: (String) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      Menu {
        ForEach(presentation.recentFolders) { folder in
          Button {
            onSelect(folder.value)
          } label: {
            if folder.value == presentation.selectedFolder.value {
              Label(menuLabel(folder), systemImage: "checkmark")
            } else {
              Text(menuLabel(folder))
            }
          }
          .disabled(folder.isDisabled)
        }
        Divider()
        Button(presentation.pickerTitle) {}
          .disabled(true)
      } label: {
        LabeledContent(label, value: menuLabel(presentation.selectedFolder))
      }
      .disabled(isDisabled)
      .accessibilityValue(menuLabel(presentation.selectedFolder))
      .accessibilityHint(disabledReason ?? presentation.remotePickerMessage)

      Text("On \(presentation.hostLabel)")
        .font(.caption)
        .foregroundStyle(.secondary)
      Text(presentation.remotePickerMessage)
        .font(.caption)
        .foregroundStyle(.secondary)
      Text(presentation.commandFallback)
        .font(.caption.monospaced())
        .foregroundStyle(.secondary)
        .textSelection(.enabled)
    }
  }

  private func menuLabel(_ folder: BotChatSettingsModel.FolderOption) -> String {
    guard let parentHint = folder.parentHint else { return folder.label }
    return "\(folder.label) — \(parentHint)"
  }
}
