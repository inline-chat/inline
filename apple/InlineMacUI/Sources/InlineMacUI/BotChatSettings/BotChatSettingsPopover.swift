import InlineKit
import InlineUI
import SwiftUI

public typealias BotChatSettingsRemoteFolderPicker = @MainActor @Sendable (_ hostInstallationID: String, _ botUserID: Int64, _ hostLabel: String) async throws -> String

public typealias BotChatSettingsLocalFolderPicker = @MainActor @Sendable (
  _ hostInstallationID: String,
  _ botUserID: Int64,
  _ port: UInt16,
  _ capability: String
) async throws -> String

public typealias BotChatSettingsLocalPickerAvailability = @MainActor @Sendable (
  _ hostInstallationID: String,
  _ botUserID: Int64,
  _ port: UInt16,
  _ capability: String
) async -> Bool

public enum BotChatSettingsControlKind: Equatable, Sendable {
  case toggle
  case select
  case info
  case button
  case folder
}

public func botChatSettingsControlKind(for control: BotChatSettingsModel.Control) -> BotChatSettingsControlKind {
  switch control {
  case .toggle: .toggle
  case .select: .select
  case .info: .info
  case .button: .button
  case .folder: .folder
  }
}

public func botChatSettingsSharedDisabledReason(
  in document: BotChatSettingsModel.Document
) -> String? {
  BotChatSettingsLayout.sharedDisabledReason(in: document.sections.flatMap(\.items))
}

/// Agent Settings: who the settings are for, this chat's choices, the
/// provider's settings, then usage.
public struct BotChatSettingsPopover<ThreadConfiguration: View>: View {
  private let coordinator: BotChatSettingsCoordinator
  private let showsThreadConfiguration: Bool
  private let threadConfiguration: ThreadConfiguration
  private let hiddenItemIDs: Set<String>
  private let remoteFolderPicker: BotChatSettingsRemoteFolderPicker?
  private let localFolderPicker: BotChatSettingsLocalFolderPicker?
  private let localFolderPickerAvailable: BotChatSettingsLocalPickerAvailability

  /// - Parameter hiddenItemIDs: provider items the thread configuration
  ///   already shows, so a choice appears once.
  public init(
    coordinator: BotChatSettingsCoordinator,
    showsThreadConfiguration: Bool,
    hiddenItemIDs: Set<String> = [],
    @ViewBuilder threadConfiguration: () -> ThreadConfiguration,
    remoteFolderPicker: BotChatSettingsRemoteFolderPicker? = nil,
    localFolderPicker: BotChatSettingsLocalFolderPicker? = nil,
    localFolderPickerAvailable: @escaping BotChatSettingsLocalPickerAvailability = { _, _, _, _ in false }
  ) {
    self.coordinator = coordinator
    self.showsThreadConfiguration = showsThreadConfiguration
    self.hiddenItemIDs = hiddenItemIDs
    self.threadConfiguration = threadConfiguration()
    self.remoteFolderPicker = remoteFolderPicker
    self.localFolderPicker = localFolderPicker
    self.localFolderPickerAvailable = localFolderPickerAvailable
  }

  private var layout: BotChatSettingsLayout? {
    coordinator.selectedState.document.map { BotChatSettingsLayout(document: $0, hiding: hiddenItemIDs) }
  }

  public var body: some View {
    let layout = layout
    VStack(spacing: 0) {
      BotChatSettingsHeader(coordinator: coordinator)
      Divider()
      ScrollView {
        VStack(alignment: .leading, spacing: AgentSettingsMetrics.groupSpacing) {
          if layout != nil, case let .problem(problem)? = coordinator.selectedState.surfaceStatus {
            BotChatSettingsProblemNotice(problem: problem, onRetry: coordinator.refreshSelected)
          }
          if showsThreadConfiguration {
            AgentSettingsGroup {
              threadConfiguration
            }
          }
          if coordinator.isToolbarVisible {
            providerContent(layout)
          }
        }
        .padding(AgentSettingsMetrics.contentPadding)
      }
      .scrollBounceBehavior(.basedOnSize)
    }
    .frame(width: AgentSettingsMetrics.width)
    .frame(maxHeight: AgentSettingsMetrics.maxHeight)
    .task(id: coordinator.selectedBotID) {
      coordinator.refreshSelectedIfStale()
      while !Task.isCancelled {
        do {
          try await Task.sleep(for: .seconds(30))
        } catch {
          return
        }
        // Keep usage fresh without interrupting the provider's folder browser.
        if self.layout?.hasUsage == true {
          coordinator.refreshSelectedIfStale()
        }
      }
    }
  }

  @ViewBuilder
  private func providerContent(_ layout: BotChatSettingsLayout?) -> some View {
    let state = coordinator.selectedState
    if let layout {
      BotChatSettingsLayoutView(
        layout: layout,
        pendingItemIDs: state.pendingItemIDs,
        botUserID: coordinator.selectedBot?.id,
        remoteFolderPicker: remoteFolderPicker,
        localFolderPicker: localFolderPicker,
        localFolderPickerAvailable: localFolderPickerAvailable,
        onInvoke: coordinator.invoke(itemID:value:)
      )
    } else if state.phase == .loading || state.phase == .idle {
      BotChatSettingsPlaceholder(isCompact: showsThreadConfiguration) {
        ProgressView().controlSize(.small)
        Text("Loading settings…")
      }
    } else if let problem = state.problem {
      BotChatSettingsPlaceholder(isCompact: showsThreadConfiguration) {
        Text(problem.message)
        Button("Retry", action: coordinator.refreshSelected)
          .controlSize(.small)
      }
    } else if !showsThreadConfiguration {
      BotChatSettingsPlaceholder(isCompact: false) {
        Text("No settings for this chat")
        Button("Refresh", action: coordinator.refreshSelected)
          .controlSize(.small)
      }
    }
  }
}

// MARK: - Header

/// The agent these settings belong to, with a switcher when the chat has
/// more than one, and a quiet refresh indicator.
private struct BotChatSettingsHeader: View {
  let coordinator: BotChatSettingsCoordinator

  var body: some View {
    HStack(spacing: 8) {
      if let selectedBot = coordinator.selectedBot {
        if coordinator.bots.count > 1 {
          UserAvatar(user: User(from: selectedBot.user), size: 22)
            .accessibilityHidden(true)
          Menu {
            ForEach(coordinator.bots) { bot in
              AgentSettingsMenuItem(bot.displayName, isSelected: bot.id == selectedBot.id) {
                coordinator.selectBot(bot.id)
              }
            }
          } label: {
            Text(selectedBot.displayName)
              .font(.headline)
          }
          .menuStyle(.borderlessButton)
          .fixedSize()
          .accessibilityLabel("Choose agent")
          .accessibilityValue(selectedBot.displayName)
        } else {
          BotChatSettingsBotLabel(bot: selectedBot)
        }
      } else {
        Text("Agent Settings")
          .font(.headline)
      }

      Spacer(minLength: 8)

      if coordinator.selectedState.surfaceStatus == .refreshing {
        ProgressView()
          .controlSize(.mini)
          .help("Refreshing settings…")
          .accessibilityLabel("Refreshing settings")
      }
    }
    .padding(.horizontal, 14)
    .frame(height: 44)
  }
}

private struct BotChatSettingsBotLabel: View {
  let bot: BotChatSettingsBot

  var body: some View {
    HStack(spacing: 7) {
      UserAvatar(user: User(from: bot.user), size: 22)
      Text(bot.displayName)
        .font(.headline)
        .lineLimit(1)
    }
    .accessibilityElement(children: .combine)
  }
}

private struct BotChatSettingsProblemNotice: View {
  let problem: BotChatSettingsProblem
  let onRetry: () -> Void

  var body: some View {
    HStack(spacing: 6) {
      Image(systemName: "exclamationmark.triangle.fill")
        .foregroundStyle(.orange)
        .accessibilityHidden(true)
      Text(problem.message)
        .font(.callout)
        .frame(maxWidth: .infinity, alignment: .leading)
      Button("Retry", action: onRetry)
        .controlSize(.small)
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 7)
    .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
  }
}

private struct BotChatSettingsPlaceholder<Content: View>: View {
  let isCompact: Bool
  @ViewBuilder let content: () -> Content

  var body: some View {
    VStack(spacing: 8, content: content)
      .font(.callout)
      .foregroundStyle(.secondary)
      .frame(maxWidth: .infinity, minHeight: isCompact ? 56 : 140)
  }
}

// MARK: - Provider settings

private struct BotChatSettingsLayoutView: View {
  let layout: BotChatSettingsLayout
  let pendingItemIDs: Set<String>
  let botUserID: Int64?
  let remoteFolderPicker: BotChatSettingsRemoteFolderPicker?
  let localFolderPicker: BotChatSettingsLocalFolderPicker?
  let localFolderPickerAvailable: BotChatSettingsLocalPickerAvailability
  let onInvoke: (String, BotChatSettingsMutationValue?) -> Void

  var body: some View {
    ForEach(layout.sections) { section in
      AgentSettingsGroup(section.title) {
        ForEach(section.items) { item in
          BotChatSettingsItemRow(
            item: item,
            isPending: pendingItemIDs.contains(item.id),
            showsDisabledReason: item.disabledReason != layout.accessNote,
            botUserID: botUserID,
            remoteFolderPicker: remoteFolderPicker,
            localFolderPicker: localFolderPicker,
            localFolderPickerAvailable: localFolderPickerAvailable,
            onInvoke: onInvoke
          )
        }
        if let description = section.description {
          AgentSettingsNote(description)
            .padding(.vertical, 6)
        }
      }
    }

    if layout.hasUsage {
      AgentSettingsGroup(String(localized: "Usage")) {
        ForEach(layout.meters) { meter in
          AgentSettingsMeterRow(
            meter.title,
            value: meter.value,
            detail: meter.detail,
            fraction: meter.fraction
          ) {
            if meter.id.hasPrefix(ComposeAgentSettingsItem.context), let action = layout.contextAction {
              BotChatSettingsContextAction(
                item: action,
                isPending: pendingItemIDs.contains(action.id),
                onInvoke: onInvoke
              )
            }
          }
        }
        if let summary = layout.usageSummary, case let .info(text, tone) = summary.control {
          BotChatSettingsUsageSummaryRow(summary: text, details: summary.description, tone: tone)
        }
      }
    }

    if let accessNote = layout.accessNote {
      AgentSettingsNote(accessNote, systemImage: "lock")
        .padding(.horizontal, 2)
    }
  }
}

/// Compact, beside the context it frees.
private struct BotChatSettingsContextAction: View {
  let item: BotChatSettingsModel.Item
  let isPending: Bool
  let onInvoke: (String, BotChatSettingsMutationValue?) -> Void

  var body: some View {
    if isPending {
      ProgressView()
        .controlSize(.mini)
        .accessibilityLabel("Compacting context")
    } else {
      Button("Compact") { onInvoke(item.id, nil) }
        .buttonStyle(.link)
        .font(.callout)
        .disabled(item.isDisabled)
        .help(item.disabledReason ?? item.description ?? "")
    }
  }
}

private struct BotChatSettingsItemRow: View {
  let item: BotChatSettingsModel.Item
  let isPending: Bool
  let showsDisabledReason: Bool
  let botUserID: Int64?
  let remoteFolderPicker: BotChatSettingsRemoteFolderPicker?
  let localFolderPicker: BotChatSettingsLocalFolderPicker?
  let localFolderPickerAvailable: BotChatSettingsLocalPickerAvailability
  let onInvoke: (String, BotChatSettingsMutationValue?) -> Void

  private var label: String { item.label ?? "" }

  /// A locked control's own reason, unless the shared access note says it.
  private var lockReason: String? {
    guard item.isDisabled, showsDisabledReason else { return nil }
    return item.disabledReason
  }

  private var help: String {
    if item.isDisabled, let reason = item.disabledReason { return reason }
    return item.description ?? ""
  }

  var body: some View {
    switch item.control {
    case let .toggle(value):
      AgentSettingsRow(label, isPending: isPending) {
        Toggle(label, isOn: Binding(
          get: { value },
          set: { onInvoke(item.id, .bool($0)) }
        ))
        .labelsHidden()
        .toggleStyle(.switch)
        .controlSize(.mini)
        .disabled(item.isDisabled)
      }
      .help(help)
    case let .select(value, options):
      let selected = options.first(where: { $0.value == value })
      AgentSettingsRow(label, isPending: isPending) {
        AgentSettingsMenu(
          selected?.label ?? value,
          accessibilityLabel: label,
          isEditable: !item.isDisabled,
          lockReason: lockReason
        ) {
          ForEach(options) { option in
            AgentSettingsMenuItem(
              option.label,
              description: option.description,
              isSelected: option.value == value,
              isDisabled: option.isDisabled
            ) {
              guard option.value != value else { return }
              onInvoke(item.id, .string(option.value))
            }
          }
        }
      }
      .help(item.isDisabled ? help : selected?.description ?? item.description ?? "")
    case let .info(text, tone):
      BotChatSettingsInfoRow(label: item.label, text: text, description: item.description, tone: tone)
    case .button:
      HStack(spacing: 6) {
          Button(label) { onInvoke(item.id, nil) }
            .buttonStyle(.link)
            .disabled(item.isDisabled || isPending)
            .accessibilityHint(help)
          if isPending {
            ProgressView().controlSize(.mini)
          }
      }
      .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
      .help(help)
    case .folder:
      if let folder = item.control.folderPresentation {
        BotChatSettingsFolderRow(
          label: label,
          presentation: folder,
          lockReason: lockReason,
          isPending: isPending,
          isDisabled: item.isDisabled,
          disabledReason: item.disabledReason,
          botUserID: botUserID,
          remoteFolderPicker: remoteFolderPicker,
          localFolderPicker: localFolderPicker,
          localFolderPickerAvailable: localFolderPickerAvailable,
          onSelect: { onInvoke(item.id, .string($0)) }
        )
      }
    }
  }
}

/// A read-only fact. Short ones sit on one line like any other row; a
/// longer message, like a setup guide, wraps under its title.
private struct BotChatSettingsInfoRow: View {
  let label: String?
  let text: String
  let description: String?
  let tone: BotChatSettingsModel.InfoTone

  private var isShort: Bool { label != nil && text.count <= 28 }

  var body: some View {
    Group {
      if isShort, let label {
        AgentSettingsRow(label) {
          HStack(spacing: 4) {
            toneIcon
            Text(text)
              .foregroundStyle(.secondary)
              .lineLimit(1)
              .textSelection(.enabled)
          }
        }
      } else {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
          toneIcon
          VStack(alignment: .leading, spacing: 2) {
            if let label { Text(label) }
            Text(text)
              .font(label == nil ? .body : .callout)
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
              .textSelection(.enabled)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 6)
      }
    }
    .help(description ?? "")
    .accessibilityElement(children: .combine)
  }

  @ViewBuilder
  private var toneIcon: some View {
    switch tone {
    case .neutral: EmptyView()
    case .success: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
    case .warning: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
    case .error: Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
    }
  }
}

/// A v1 bridge's usage: its summary, with the limits and reset times one
/// click away. Expanding never invokes a provider command.
struct BotChatSettingsUsageSummaryRow: View {
  let summary: String
  let details: String?
  let tone: BotChatSettingsModel.InfoTone

  @State private var isExpanded = false

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Button {
        isExpanded.toggle()
      } label: {
        HStack(spacing: 6) {
          Text("Account")
            .frame(maxWidth: .infinity, alignment: .leading)
          Text(summary)
            .monospacedDigit()
            .foregroundStyle(tone == .warning ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
          if details != nil {
            Image(systemName: "chevron.right")
              .font(.caption2.weight(.semibold))
              .foregroundStyle(.tertiary)
              .rotationEffect(.degrees(isExpanded ? 90 : 0))
          }
        }
        .frame(minHeight: 28)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .disabled(details == nil)
      .accessibilityLabel("Account usage")
      .accessibilityValue(summary)
      .accessibilityHint(isExpanded ? "Hide usage limits and reset times" : "Show usage limits and reset times")

      if isExpanded, let details {
        AgentSettingsNote(details)
          .textSelection(.enabled)
          .padding(.bottom, 6)
      }
    }
  }
}

// MARK: - Folder

/// The folder as one menu: recent folders on the agent's machine, then
/// picking a new one when this Mac or the agent's machine can.
private struct BotChatSettingsFolderRow: View {
  let label: String
  let presentation: BotChatSettingsModel.FolderPresentation
  let lockReason: String?
  let isPending: Bool
  let isDisabled: Bool
  let disabledReason: String?
  let botUserID: Int64?
  let remoteFolderPicker: BotChatSettingsRemoteFolderPicker?
  let localFolderPicker: BotChatSettingsLocalFolderPicker?
  let localFolderPickerAvailable: BotChatSettingsLocalPickerAvailability
  let onSelect: (String) -> Void

  @State private var isPickingFolder = false
  @State private var pickerError: String?
  @State private var pickerProbe = BotChatSettingsLocalPickerProbeState()

  private var pickerEndpoint: (port: UInt16, capability: String)? {
    guard let port = presentation.localPickerPort,
          let capability = presentation.localPickerCapability
    else { return nil }
    return (port, capability)
  }

  private var canBrowseRemotely: Bool {
    presentation.remoteBrowserVersion == 1 && remoteFolderPicker != nil && botUserID != nil
  }

  private var canPickLocally: Bool {
    presentation.allowsLocalPicker &&
      localFolderPicker != nil &&
      botUserID != nil &&
      pickerEndpoint != nil &&
      pickerProbe.isReachable
  }

  private var canPick: Bool { canPickLocally || canBrowseRemotely }

  var body: some View {
    AgentSettingsRow(label, note: pickerError, isPending: isPending || isPickingFolder) {
      AgentSettingsMenu(
        presentation.selectedFolder.label,
        accessibilityLabel: label,
        isEditable: !isDisabled,
        lockReason: lockReason
      ) {
        Section("On \(presentation.hostLabel)") {
          ForEach(presentation.recentFolders) { folder in
            AgentSettingsMenuItem(
              folder.label,
              description: folder.parentHint,
              isSelected: folder.value == presentation.selectedFolder.value,
              isDisabled: folder.isDisabled
            ) {
              onSelect(folder.value)
            }
          }
        }
        Divider()
        Button(presentation.pickerTitle, action: pickFolder)
          .disabled(!canPick || isPickingFolder)
        if !canPick {
          Section {
            Text(presentation.remotePickerMessage)
            Text(presentation.commandFallback)
          }
        }
      }
    }
    .help(accessibilityHint)
    .task(id: pickerProbeID) {
      let probeID = pickerProbeID
      pickerProbe.begin(probeID)
      guard presentation.allowsLocalPicker,
            let botUserID,
            let endpoint = pickerEndpoint
      else { return }
      let isReachable = await localFolderPickerAvailable(
        presentation.hostInstallationID,
        botUserID,
        endpoint.port,
        endpoint.capability
      )
      guard !Task.isCancelled else { return }
      pickerProbe.complete(probeID, isReachable: isReachable)
    }
  }

  private func pickFolder() {
    if canBrowseRemotely, let remoteFolderPicker, let botUserID {
      isPickingFolder = true
      pickerError = nil
      Task { @MainActor in
        do {
          let workspaceID = try await remoteFolderPicker(presentation.hostInstallationID, botUserID, presentation.hostLabel)
          guard !Task.isCancelled else { return }
          onSelect(workspaceID)
        } catch is CancellationError {
        } catch {
          pickerError = "Couldn’t choose that folder. Try again."
        }
        isPickingFolder = false
      }
      return
    }
    guard canPickLocally, let localFolderPicker, let botUserID, let endpoint = pickerEndpoint else { return }
    isPickingFolder = true
    pickerError = nil
    Task { @MainActor in
      do {
        let workspaceID = try await localFolderPicker(
          presentation.hostInstallationID,
          botUserID,
          endpoint.port,
          endpoint.capability
        )
        onSelect(workspaceID)
      } catch is CancellationError {
      } catch {
        pickerError = "Couldn’t add that folder. Try again."
      }
      isPickingFolder = false
    }
  }

  private var accessibilityHint: String {
    if let disabledReason { return disabledReason }
    if canBrowseRemotely { return "Browse files and choose a folder on \(presentation.hostLabel)." }
    if canPickLocally { return "Choose a recent folder or pick one on this Mac." }
    return "On \(presentation.hostLabel). \(presentation.remotePickerMessage)"
  }

  private var pickerProbeID: String {
    let endpoint = pickerEndpoint
    return [
      presentation.hostInstallationID,
      String(botUserID ?? 0),
      String(endpoint?.port ?? 0),
      endpoint?.capability ?? "",
    ].joined(separator: ":")
  }
}

struct BotChatSettingsLocalPickerProbeState: Equatable {
  private(set) var activeID: String?
  private(set) var isReachable = false

  mutating func begin(_ id: String) {
    activeID = id
    isReachable = false
  }

  mutating func complete(_ id: String, isReachable: Bool) {
    guard activeID == id else { return }
    self.isReachable = isReachable
  }
}
