import InlineKit
import InlineUI
import SwiftUI

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

public struct BotChatSettingsPopover: View {
  private let coordinator: BotChatSettingsCoordinator
  private let localFolderPicker: BotChatSettingsLocalFolderPicker?
  private let localFolderPickerAvailable: BotChatSettingsLocalPickerAvailability

  public init(
    coordinator: BotChatSettingsCoordinator,
    localFolderPicker: BotChatSettingsLocalFolderPicker? = nil,
    localFolderPickerAvailable: @escaping BotChatSettingsLocalPickerAvailability = { _, _, _, _ in false }
  ) {
    self.coordinator = coordinator
    self.localFolderPicker = localFolderPicker
    self.localFolderPickerAvailable = localFolderPickerAvailable
  }

  public var body: some View {
    VStack(spacing: 0) {
      BotChatSettingsPopoverHeader(coordinator: coordinator)
      Divider()
      BotChatSettingsPopoverContent(
        coordinator: coordinator,
        botUserID: coordinator.selectedBot?.id,
        localFolderPicker: localFolderPicker,
        localFolderPickerAvailable: localFolderPickerAvailable
      )
    }
    .frame(width: 336, height: 300)
    .task(id: coordinator.selectedBotID) {
      coordinator.refreshSelectedIfStale()
    }
  }
}

private struct BotChatSettingsPopoverHeader: View {
  let coordinator: BotChatSettingsCoordinator

  var body: some View {
    VStack(spacing: 8) {
      HStack(spacing: 10) {
        Text("Agent settings")
          .font(.headline)
          .frame(maxWidth: .infinity, alignment: .leading)

        if let selectedBot = coordinator.selectedBot {
          if coordinator.bots.count > 3 {
            Menu {
              ForEach(coordinator.bots) { bot in
                Button {
                  coordinator.selectBot(bot.id)
                } label: {
                  Label(bot.displayName, systemImage: bot.id == selectedBot.id ? "checkmark" : "circle")
                }
              }
            } label: {
              BotChatSettingsBotLabel(bot: selectedBot, includesAvatar: true)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityLabel("Choose agent")
          } else if coordinator.bots.count == 1 {
            BotChatSettingsBotLabel(bot: selectedBot, includesAvatar: true)
          }
        }

        ProgressView()
          .controlSize(.small)
          .opacity(coordinator.selectedState.isRefreshing ? 1 : 0)
          .frame(width: 14, height: 14)
          .accessibilityLabel("Refreshing agent settings")
          .accessibilityHidden(!coordinator.selectedState.isRefreshing)
      }

      if (2 ... 3).contains(coordinator.bots.count), let selectedBot = coordinator.selectedBot {
        Picker("Agent", selection: Binding(
          get: { selectedBot.id },
          set: coordinator.selectBot
        )) {
          ForEach(coordinator.bots) { bot in
            Text(bot.displayName)
              .lineLimit(1)
              .tag(bot.id)
          }
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .controlSize(.small)
        .accessibilityLabel("Choose agent")
      }
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 11)
  }
}

private struct BotChatSettingsBotLabel: View {
  let bot: BotChatSettingsBot
  let includesAvatar: Bool

  var body: some View {
    HStack(spacing: 6) {
      if includesAvatar {
        UserAvatar(user: User(from: bot.user), size: 20)
      }
      Text(bot.displayName)
        .font(.callout)
        .lineLimit(1)
    }
    .accessibilityElement(children: .combine)
  }
}

private struct BotChatSettingsPopoverContent: View {
  let coordinator: BotChatSettingsCoordinator
  let botUserID: Int64?
  let localFolderPicker: BotChatSettingsLocalFolderPicker?
  let localFolderPickerAvailable: BotChatSettingsLocalPickerAvailability

  @ViewBuilder
  var body: some View {
    let state = coordinator.selectedState
    if state.phase == .loading, state.document == nil {
      BotChatSettingsCenteredState {
        ProgressView()
        Text("Loading settings…")
          .foregroundStyle(.secondary)
      }
    } else if let document = state.document {
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 0) {
          BotChatSettingsDocumentView(
            document: document,
            pendingItemIDs: state.pendingItemIDs,
            botUserID: botUserID,
            localFolderPicker: localFolderPicker,
            localFolderPickerAvailable: localFolderPickerAvailable,
            onInvoke: coordinator.invoke(itemID:value:)
          )
        }
      }
      .overlay(alignment: .bottom) {
        if let problem = state.problem {
          BotChatSettingsProblemBanner(problem: problem, onRetry: coordinator.refreshSelected)
            .padding(8)
        }
      }
    } else if let problem = state.problem {
      BotChatSettingsCenteredState {
        Image(systemName: "bolt.horizontal.circle")
          .font(.title2)
          .foregroundStyle(.secondary)
        Text(problem.message)
          .font(.callout)
        Button("Retry", action: coordinator.refreshSelected)
          .controlSize(.small)
      }
    } else {
      BotChatSettingsCenteredState {
        Image(systemName: "slider.horizontal.3")
          .font(.title2)
          .foregroundStyle(.secondary)
        Text("No settings for this chat")
          .font(.callout)
        Button("Refresh", action: coordinator.refreshSelected)
          .controlSize(.small)
      }
    }
  }
}

private struct BotChatSettingsCenteredState<Content: View>: View {
  @ViewBuilder let content: () -> Content

  var body: some View {
    VStack(spacing: 9, content: content)
      .frame(maxWidth: .infinity, minHeight: 170)
      .padding(20)
  }
}

private struct BotChatSettingsProblemBanner: View {
  let problem: BotChatSettingsProblem
  let onRetry: () -> Void

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: "exclamationmark.triangle")
        .foregroundStyle(.orange)
      Text(problem.message)
        .font(.caption)
        .frame(maxWidth: .infinity, alignment: .leading)
      Button("Retry", action: onRetry)
        .controlSize(.mini)
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 7)
    .background(.background, in: RoundedRectangle(cornerRadius: 8))
    .shadow(color: .black.opacity(0.12), radius: 5, y: 2)
    .accessibilityElement(children: .combine)
  }
}

private struct BotChatSettingsDocumentView: View {
  let document: BotChatSettingsModel.Document
  let pendingItemIDs: Set<String>
  let botUserID: Int64?
  let localFolderPicker: BotChatSettingsLocalFolderPicker?
  let localFolderPickerAvailable: BotChatSettingsLocalPickerAvailability
  let onInvoke: (String, BotChatSettingsMutationValue?) -> Void

  private var sharedDisabledReason: String? {
    botChatSettingsSharedDisabledReason(in: document)
  }

  var body: some View {
    VStack(spacing: 0) {
      ForEach(document.sections) { section in
        if section.id != document.sections.first?.id { Divider().padding(.horizontal, 12) }
        BotChatSettingsSectionView(
          section: section,
          pendingItemIDs: pendingItemIDs,
          sharedDisabledReason: sharedDisabledReason,
          botUserID: botUserID,
          localFolderPicker: localFolderPicker,
          localFolderPickerAvailable: localFolderPickerAvailable,
          onInvoke: onInvoke
        )
      }
      if let sharedDisabledReason {
        Divider().padding(.horizontal, 12)
        BotChatSettingsAccessNote(reason: sharedDisabledReason)
      }
    }
  }
}

public func botChatSettingsSharedDisabledReason(
  in document: BotChatSettingsModel.Document
) -> String? {
  let reasons = document.sections
    .flatMap(\.items)
    .filter(\.isDisabled)
    .compactMap(\.disabledReason)
  guard let first = reasons.first, reasons.allSatisfy({ $0 == first }) else { return nil }
  return first
}

private struct BotChatSettingsAccessNote: View {
  let reason: String

  var body: some View {
    Label {
      Text(reason)
        .fixedSize(horizontal: false, vertical: true)
    } icon: {
      Image(systemName: "lock")
    }
    .font(.caption)
    .foregroundStyle(.secondary)
    .padding(.horizontal, 12)
    .padding(.vertical, 9)
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

private struct BotChatSettingsSectionView: View {
  let section: BotChatSettingsModel.Section
  let pendingItemIDs: Set<String>
  let sharedDisabledReason: String?
  let botUserID: Int64?
  let localFolderPicker: BotChatSettingsLocalFolderPicker?
  let localFolderPickerAvailable: BotChatSettingsLocalPickerAvailability
  let onInvoke: (String, BotChatSettingsMutationValue?) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      if section.title != nil || section.description != nil {
        VStack(alignment: .leading, spacing: 2) {
          if let title = section.title {
            Text(title)
              .font(.caption.weight(.semibold))
              .foregroundStyle(.secondary)
          }
          if let description = section.description {
            Text(description)
              .font(.caption2)
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
      }

      ForEach(section.items) { item in
        BotChatSettingsItemView(
          item: item,
          isPending: pendingItemIDs.contains(item.id),
          showsDisabledReason: item.disabledReason != sharedDisabledReason,
          botUserID: botUserID,
          localFolderPicker: localFolderPicker,
          localFolderPickerAvailable: localFolderPickerAvailable,
          onInvoke: onInvoke
        )
      }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 10)
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

private struct BotChatSettingsItemView: View {
  let item: BotChatSettingsModel.Item
  let isPending: Bool
  let showsDisabledReason: Bool
  let botUserID: Int64?
  let localFolderPicker: BotChatSettingsLocalFolderPicker?
  let localFolderPickerAvailable: BotChatSettingsLocalPickerAvailability
  let onInvoke: (String, BotChatSettingsMutationValue?) -> Void

  private var isDisabled: Bool { item.isDisabled }
  private var label: String { item.label ?? "" }
  private var showsDescriptionBelowControl: Bool {
    if case .button = item.control { return false }
    return true
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      control
      if showsDescriptionBelowControl, let description = item.description {
        Text(description)
          .font(.caption2)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      if item.isDisabled, showsDisabledReason, let disabledReason = item.disabledReason {
        Text(disabledReason)
          .font(.caption2)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  @ViewBuilder
  private var control: some View {
    switch item.control {
    case let .toggle(value):
      alignedRow {
        if item.isDisabled {
          Text(value ? "On" : "Off")
            .foregroundStyle(.secondary)
        } else {
          Toggle("", isOn: Binding(
            get: { value },
            set: { onInvoke(item.id, .bool($0)) }
          ))
          .labelsHidden()
          .toggleStyle(.switch)
          .controlSize(.small)
          .disabled(isDisabled)
          .accessibilityLabel(label)
          .accessibilityHint(accessibilityHint)
        }
      }
    case let .select(value, options):
      VStack(alignment: .leading, spacing: 3) {
        alignedRow {
          if item.isDisabled {
            Text(options.first(where: { $0.value == value })?.label ?? value)
              .foregroundStyle(.secondary)
              .lineLimit(1)
          } else {
            Picker("", selection: Binding(
              get: { value },
              set: { onInvoke(item.id, .string($0)) }
            )) {
              ForEach(options) { option in
                Text(option.label)
                  .tag(option.value)
                  .disabled(option.isDisabled)
              }
            }
            .labelsHidden()
            .frame(width: 164)
            .disabled(isDisabled)
            .accessibilityLabel(label)
            .accessibilityHint(accessibilityHint)
          }
        }
        if let optionDescription = options.first(where: { $0.value == value })?.description {
          Text(optionDescription)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
      }
    case let .info(text, tone):
      HStack(alignment: .firstTextBaseline, spacing: 7) {
        Image(systemName: infoSymbol(for: tone))
          .foregroundStyle(infoColor(for: tone))
        VStack(alignment: .leading, spacing: 2) {
          if let itemLabel = item.label {
            Text(itemLabel).font(.caption.weight(.semibold))
          }
          Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
        }
      }
      .accessibilityElement(children: .combine)
    case .button:
      HStack(spacing: 7) {
        if let description = item.description {
          Text(description)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        Button(label) { onInvoke(item.id, nil) }
          .controlSize(.small)
          .disabled(isDisabled || isPending)
          .accessibilityHint(accessibilityHint)
        pendingIndicator
      }
      .frame(maxWidth: .infinity, alignment: .trailing)
    case .folder:
      if let folder = item.control.folderPresentation {
      HStack(spacing: 7) {
        BotChatSettingsFolderControl(
          label: label,
          presentation: folder,
          isDisabled: isDisabled,
          disabledReason: item.disabledReason,
          botUserID: botUserID,
          localFolderPicker: localFolderPicker,
          localFolderPickerAvailable: localFolderPickerAvailable,
          onSelect: { onInvoke(item.id, .string($0)) },
          onPickedFolder: { onInvoke(item.id, .string($0)) }
        )
        pendingIndicator
      }
      }
    }
  }

  private func alignedRow<Control: View>(@ViewBuilder control: () -> Control) -> some View {
    HStack(spacing: 10) {
      Text(label)
        .font(.callout)
        .frame(maxWidth: .infinity, alignment: .leading)
      control()
      pendingIndicator
    }
    .frame(minHeight: 24)
  }

  private var accessibilityHint: String {
    if item.isDisabled, let disabledReason = item.disabledReason { return disabledReason }
    return item.description ?? ""
  }

  @ViewBuilder
  private var pendingIndicator: some View {
    ProgressView()
      .controlSize(.mini)
      .opacity(isPending ? 1 : 0)
      .frame(width: 12, height: 12)
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

private struct BotChatSettingsFolderControl: View {
  let label: String
  let presentation: BotChatSettingsModel.FolderPresentation
  let isDisabled: Bool
  let disabledReason: String?
  let botUserID: Int64?
  let localFolderPicker: BotChatSettingsLocalFolderPicker?
  let localFolderPickerAvailable: BotChatSettingsLocalPickerAvailability
  let onSelect: (String) -> Void
  let onPickedFolder: (String) -> Void

  @State private var isPickingFolder = false
  @State private var pickerError: String?
  @State private var pickerProbe = BotChatSettingsLocalPickerProbeState()

  private var pickerEndpoint: (port: UInt16, capability: String)? {
    guard let port = presentation.localPickerPort,
          let capability = presentation.localPickerCapability
    else { return nil }
    return (port, capability)
  }

  private var canPickLocally: Bool {
    presentation.allowsLocalPicker &&
      localFolderPicker != nil &&
      botUserID != nil &&
      pickerEndpoint != nil &&
      pickerProbe.isReachable
  }

  private var pickerUnavailableReason: String {
    presentation.remotePickerMessage
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 10) {
        Text(label)
          .font(.callout)
          .frame(maxWidth: .infinity, alignment: .leading)
        Menu {
          ForEach(presentation.recentFolders) { folder in
            Button {
              onSelect(folder.value)
            } label: {
              if folder.value == presentation.selectedFolder.value {
                Label(folderMenuLabel(folder), systemImage: "checkmark")
              } else {
                Text(folderMenuLabel(folder))
              }
            }
            .disabled(folder.isDisabled)
          }
          Divider()
          Button(presentation.pickerTitle, action: pickFolder)
            .disabled(!canPickLocally || isPickingFolder)
        } label: {
          Text(presentation.selectedFolder.label)
            .lineLimit(1)
            .frame(minWidth: 120, alignment: .trailing)
        }
        .disabled(isDisabled)
        .accessibilityLabel(label)
        .accessibilityValue(folderMenuLabel(presentation.selectedFolder))
        .accessibilityHint(accessibilityHint)
      }
      if let parentHint = presentation.selectedFolder.parentHint {
        Text(parentHint)
          .font(.caption2)
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, alignment: .trailing)
      }
      Text("On \(presentation.hostLabel)")
        .font(.caption2)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .trailing)
      if !canPickLocally {
        Text(pickerUnavailableReason)
          .font(.caption2)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        Text(presentation.commandFallback)
          .font(.caption2.monospaced())
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
      } else if isPickingFolder {
        Label("Choosing a folder…", systemImage: "folder.badge.plus")
          .font(.caption2)
          .foregroundStyle(.secondary)
      } else if let pickerError {
        Text(pickerError)
          .font(.caption2)
          .foregroundStyle(.red)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
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
        onPickedFolder(workspaceID)
      } catch is CancellationError {
      } catch {
        pickerError = "Couldn’t add that folder. Try again."
      }
      isPickingFolder = false
    }
  }

  private var accessibilityHint: String {
    if let disabledReason { return disabledReason }
    if canPickLocally { return "Choose a recent folder or pick one on this Mac." }
    return "\(pickerUnavailableReason) Use \(presentation.commandFallback)."
  }

  private func folderMenuLabel(_ folder: BotChatSettingsModel.FolderOption) -> String {
    guard let parentHint = folder.parentHint else { return folder.label }
    return "\(folder.label) — \(parentHint)"
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
