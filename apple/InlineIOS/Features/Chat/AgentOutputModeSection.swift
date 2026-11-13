import InlineKit
import SwiftUI

/// Output in a chat's Agent Settings and in a bot's chat info: one row for
/// this thread, its menu holding the agent's default as a submenu, like on
/// Mac. Shown for agents that report a runtime or declare the Output
/// capability. The caller loads the values (`loadOutputModes`).
struct AgentOutputModeSection: View {
  enum Style {
    /// A form section with the summary as its footer.
    case formSection
    /// Rows inside a chat info card, like Notifications.
    case card
    /// One row with a symbol tile, in a bot's chat info overview.
    case tile
  }

  let peer: Peer
  let botUserID: Int64
  var style: Style = .formSection

  @ObservedObject private var store = AgentWorkStateStore.shared
  @ObservedObject private var grants = AgentGrantStore.shared
  @State private var isUpdating = false

  /// Unknown grants render editable; the server rejects what it must.
  private var canConfigure: Bool {
    grants.access(botUserID: botUserID)?.satisfies(.configure) ?? true
  }

  var body: some View {
    Group {
      switch style {
      case .formSection:
        Section {
          menu
        } footer: {
          footer
        }
      case .card:
        menu
          .padding(.horizontal, 16)
          .padding(.vertical, 12)
        footer
          .font(.footnote)
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal, 16)
          .padding(.bottom, 12)
      case .tile:
        menu
      }
    }
    .task(id: botUserID) {
      grants.ensureLoaded(botUserID: botUserID)
    }
  }

  private var menu: some View {
    let defaultMode = store.defaultOutputMode(botUserID: botUserID)
    let threadMode = store.outputModeOverride(peer: peer, botUserID: botUserID)
    let defaultTitle = String(localized: "Default (\(defaultMode.title))")
    return Menu {
      option(defaultTitle, isSelected: threadMode == nil) { setThreadMode(nil) }
      Divider()
      ForEach(AgentThreadOutputMode.allCases, id: \.self) { mode in
        option(mode.title, description: mode.summary, isSelected: threadMode == mode) { setThreadMode(mode) }
      }
      Divider()
      Menu("Agent Default") {
        ForEach(AgentThreadOutputMode.allCases, id: \.self) { mode in
          option(mode.title, description: mode.summary, isSelected: defaultMode == mode) { setDefaultMode(mode) }
        }
      }
    } label: {
      if style == .tile {
        tileLabel(value: threadMode?.title ?? defaultTitle)
      } else {
        cardLabel(value: threadMode?.title ?? defaultTitle)
      }
    }
    .disabled(!canConfigure || isUpdating)
    .accessibilityLabel("Output")
    .accessibilityValue(threadMode?.title ?? defaultTitle)
  }

  private func tileLabel(value: String) -> some View {
    BotInfoRow(
      systemImage: store.outputMode(peer: peer, botUserID: botUserID) == .friendly ? "text.bubble.fill" : "list.bullet.rectangle.fill",
      tint: .purple,
      title: "Output"
    ) {
      HStack(spacing: 6) {
        if isUpdating { ProgressView() }
        Text(value)
        if canConfigure {
          Image(systemName: "chevron.up.chevron.down")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.tertiary)
        }
      }
      .foregroundStyle(.secondary)
    } detail: {
      if canConfigure {
        Text(store.outputMode(peer: peer, botUserID: botUserID).summary)
          .foregroundStyle(.secondary)
      } else {
        Label("Only the owner can change this", systemImage: "lock")
          .foregroundStyle(.secondary)
      }
    }
    .foregroundStyle(.primary)
  }

  private func cardLabel(value: String) -> some View {
    LabeledContent("Output") {
      HStack(spacing: 6) {
        if isUpdating { ProgressView() }
        Text(value)
          .foregroundStyle(style == .card ? .secondary : .primary)
        if canConfigure {
          Image(systemName: "chevron.up.chevron.down")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(style == .card ? .tertiary : .primary)
        }
      }
    }
    .foregroundStyle(.primary)
  }

  @ViewBuilder
  private var footer: some View {
    if canConfigure {
      Text(store.outputMode(peer: peer, botUserID: botUserID).summary)
    } else {
      Label("Only the agent’s owner can change how it replies.", systemImage: "lock")
    }
  }

  private func option(
    _ title: String,
    description: String? = nil,
    isSelected: Bool,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      if isSelected {
        Label(title, systemImage: "checkmark")
      } else {
        Text(title)
      }
      if let description { Text(description) }
    }
  }

  private func setThreadMode(_ mode: AgentThreadOutputMode?) {
    guard mode != store.outputModeOverride(peer: peer, botUserID: botUserID) else { return }
    perform { try await store.updateOutputModeOverride(mode, peer: peer, botUserID: botUserID) }
  }

  private func setDefaultMode(_ mode: AgentThreadOutputMode) {
    guard mode != store.defaultOutputMode(botUserID: botUserID) else { return }
    perform { try await store.updateDefaultOutputMode(mode, botUserID: botUserID) }
  }

  private func perform(_ operation: @escaping () async throws -> Void) {
    guard !isUpdating else { return }
    isUpdating = true
    Task { @MainActor in
      defer { isUpdating = false }
      do {
        try await operation()
      } catch {
        ToastManager.shared.showToast(
          "Couldn’t change the output mode",
          type: .error,
          systemImage: "exclamationmark.triangle.fill"
        )
      }
    }
  }
}
