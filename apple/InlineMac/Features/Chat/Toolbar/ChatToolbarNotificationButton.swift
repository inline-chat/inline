import Combine
import GRDB
import InlineKit
import Logger
import SwiftUI

struct ChatToolbarNotificationButton: View {
  let peer: Peer
  let db: AppDatabase
  let toolbarState: ChatToolbarState

  @StateObject private var model: ChatToolbarNotificationModel

  init(peer: Peer, db: AppDatabase, toolbarState: ChatToolbarState) {
    self.peer = peer
    self.db = db
    self.toolbarState = toolbarState
    _model = StateObject(wrappedValue: ChatToolbarNotificationModel(peer: peer, db: db))
  }

  var body: some View {
    Button {
      toolbarState.presentNotificationSettings()
    } label: {
      Label("Notifications", systemImage: model.selection.iconName)
        .labelStyle(.iconOnly)
    }
    .accessibilityLabel("Notifications")
    .help("Notifications")
    .onAppear {
      toolbarState.handleAppear(.notificationSettings)
    }
    .onDisappear {
      toolbarState.handleDisappear(.notificationSettings)
    }
    .modifier(ChatToolbarNotificationPresentations(
      toolbarState: toolbarState,
      anchor: .button(.notificationSettings),
      model: model
    ))
  }
}

struct ChatToolbarNotificationTitlePresentations: ViewModifier {
  let peer: Peer
  let db: AppDatabase
  let toolbarState: ChatToolbarState

  @State private var model: ChatToolbarNotificationModel?

  init(peer: Peer, db: AppDatabase, toolbarState: ChatToolbarState) {
    self.peer = peer
    self.db = db
    self.toolbarState = toolbarState
  }

  func body(content: Content) -> some View {
    content.modifier(ChatToolbarNotificationPresentations(
      toolbarState: toolbarState,
      anchor: .title,
      model: model
    ))
    .onChange(of: toolbarState.presentation, initial: true) { _, presentation in
      guard presentation == .notificationSettings(.title) else { return }
      ensureModel()
    }
  }

  private func ensureModel() {
    guard model == nil else { return }
    model = ChatToolbarNotificationModel(peer: peer, db: db)
  }
}

private struct ChatToolbarNotificationPresentations: ViewModifier {
  let toolbarState: ChatToolbarState
  let anchor: ChatToolbarState.Anchor
  let model: ChatToolbarNotificationModel?

  func body(content: Content) -> some View {
    let presentation = toolbarState.presentation

    content
      .popover(isPresented: Binding(
        get: { presentation == .notificationSettings(anchor) },
        set: { isPresented in
          guard !isPresented, toolbarState.presentation == .notificationSettings(anchor) else { return }
          toolbarState.dismissPresentation()
        }
      ), arrowEdge: .bottom) {
        if let model {
          ChatToolbarNotificationPopover(model: model)
            .padding(.vertical, 10)
            .padding(.horizontal, 8)
        } else {
          ProgressView()
            .controlSize(.small)
            .frame(width: 236, height: 96)
        }
      }
  }
}

private struct ChatToolbarNotificationPopover: View {
  @ObservedObject var model: ChatToolbarNotificationModel
  @EnvironmentObject private var notificationSettings: NotificationSettingsManager

  @FocusState private var focusedOption: DialogNotificationSettingSelection?
  @State private var hoveredOption: DialogNotificationSettingSelection?

  private let overrideOptions: [DialogNotificationSettingSelection] = [.all, .mentions, .none]
  private var options: [DialogNotificationSettingSelection] { [.global] + overrideOptions }

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      notificationRow(.global)

      Divider()
        .padding(.vertical, 2)

      ForEach(overrideOptions, id: \.self) { option in
        notificationRow(option)
      }
    }
    .frame(width: 236, alignment: .leading)
    .onAppear {
      focusedOption = model.selection
    }
    .onMoveCommand { direction in
      moveFocus(direction)
    }
    .accessibilityElement(children: .contain)
    .accessibilityAdjustableAction { direction in
      switch direction {
        case .increment:
          moveFocus(.down)
        case .decrement:
          moveFocus(.up)
        default:
          break
      }
    }
  }

  private func notificationRow(_ option: DialogNotificationSettingSelection) -> some View {
    let selected = model.selection == option
    let focused = focusedOption == option
    let hovered = hoveredOption == option

    return Button {
      model.update(option)
    } label: {
      HStack(spacing: 9) {
        optionIcon(option, selected: selected)

        VStack(alignment: .leading, spacing: 1) {
          Text(title(for: option))
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.primary)
            .lineLimit(1)

          Text(description(for: option))
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
        }

        Spacer(minLength: 0)
      }
      .padding(.horizontal, 8)
      .padding(.vertical, 5)
      .frame(maxWidth: .infinity, alignment: .leading)
      .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
      .background {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .fill(rowBackground(selected: selected, focused: focused, hovered: hovered))
      }
    }
    .buttonStyle(.plain)
    .focusEffectDisabled(true)
    .focused($focusedOption, equals: option)
    .onHover { isHovered in
      hoveredOption = isHovered ? option : nil
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel(title(for: option))
    .accessibilityValue(accessibilityValue(for: option, selected: selected))
    .accessibilityHint(description(for: option))
    .accessibilityAddTraits(selected ? .isSelected : [])
    .accessibilityAction(named: "Select") {
      model.update(option)
    }
  }

  private func optionIcon(_ option: DialogNotificationSettingSelection, selected: Bool) -> some View {
    ZStack {
      Circle()
        .fill(selected ? Color.accentColor : Color.secondary.opacity(0.16))
        .frame(width: 26, height: 26)

      Image(systemName: option.iconName)
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(selected ? Color.white : Color.secondary)
    }
  }

  private func rowBackground(selected: Bool, focused: Bool, hovered: Bool) -> Color {
    if selected {
      return Color.secondary.opacity(0.18)
    }

    if focused || hovered {
      return Color.secondary.opacity(0.12)
    }

    return Color.clear
  }

  private func title(for option: DialogNotificationSettingSelection) -> String {
    switch option {
      case .global:
        "Default"
      default:
        option.title
    }
  }

  private func description(for option: DialogNotificationSettingSelection) -> String {
    switch option {
      case .global:
        "Uses global: \(globalModeTitle)."
      case .all:
        "Every message."
      case .mentions:
        "Mentions and replies."
      case .none:
        "Muted."
    }
  }

  private func accessibilityValue(for option: DialogNotificationSettingSelection, selected: Bool) -> String {
    selected ? "Selected, \(description(for: option))" : description(for: option)
  }

  private func moveFocus(_ direction: MoveCommandDirection) {
    guard let current = focusedOption, let index = options.firstIndex(of: current) else {
      focusedOption = model.selection
      return
    }

    switch direction {
      case .up:
        focusedOption = options[(index - 1 + options.count) % options.count]
      case .down:
        focusedOption = options[(index + 1) % options.count]
      default:
        break
    }
  }

  private var globalModeTitle: String {
    switch notificationSettings.mode {
      case .all:
        "All"
      case .mentions:
        "Any message to you"
      case .onlyMentions:
        "Only mentions"
      case .importantOnly:
        "Zen"
      case .none:
        "None"
    }
  }
}

@MainActor
private final class ChatToolbarNotificationModel: ObservableObject {
  @Published private(set) var selection: DialogNotificationSettingSelection = .global

  private let peer: Peer
  private let db: AppDatabase
  private var dialogCancellable: AnyCancellable?

  init(peer: Peer, db: AppDatabase) {
    self.peer = peer
    self.db = db
    bindDialog()
  }

  deinit {
    dialogCancellable?.cancel()
  }

  func update(_ selected: DialogNotificationSettingSelection) {
    guard selected != selection else { return }

    let previousSelection = selection
    selection = selected

    Task(priority: .userInitiated) {
      do {
        _ = try await Api.realtime.send(.updateDialogNotificationSettings(peerId: peer, selection: selected))
      } catch {
        Log.shared.error("Failed to update dialog notification settings", error: error)
        await MainActor.run {
          self.selection = previousSelection
        }
      }
    }
  }

  private func bindDialog() {
    db.warnIfInMemoryDatabaseForObservation("ChatToolbarNotificationModel.dialog")
    dialogCancellable = ValueObservation
      .tracking { db in
        try Dialog.fetchOne(db, id: Dialog.getDialogId(peerId: self.peer))
      }
      .publisher(in: db.dbWriter, scheduling: .immediate)
      .receive(on: DispatchQueue.main)
      .sink(
        receiveCompletion: { _ in },
        receiveValue: { [weak self] dialog in
          self?.selection = dialog?.notificationSelection ?? .global
        }
      )
  }
}
