import Observation

@MainActor
@Observable
final class ChatToolbarState {
  enum ToolbarButton: Hashable {
    case notificationSettings
    case translate
    case participants
  }

  enum Anchor: Hashable {
    case title
    case button(ToolbarButton)

    var button: ToolbarButton? {
      switch self {
      case .title:
        nil
      case let .button(button):
        button
      }
    }
  }

  enum Presentation: Hashable {
    case notificationSettings(Anchor)
    case translationPopover(Anchor)
    case translationPrompt(Anchor)
    case translationOptions(Anchor)
    case participantsPopover(Anchor)
    case addParticipants(Anchor)

    var anchor: Anchor {
      switch self {
      case let .notificationSettings(anchor),
           let .translationPopover(anchor),
           let .translationPrompt(anchor),
           let .translationOptions(anchor),
           let .participantsPopover(anchor),
           let .addParticipants(anchor):
        anchor
      }
    }
  }

  private(set) var visibleButtons: Set<ToolbarButton> = []
  var presentation: Presentation?

  func handleAppear(_ button: ToolbarButton) {
    visibleButtons.insert(button)
  }

  func handleDisappear(_ button: ToolbarButton) {
    visibleButtons.remove(button)

    guard presentation?.anchor.button == button else { return }
    presentation = nil
  }

  func handleTitleDisappear() {
    guard presentation?.anchor == .title else { return }
    presentation = nil
  }

  func presentNotificationSettings() {
    presentation = .notificationSettings(anchor(for: .notificationSettings))
  }

  func presentTranslationPopover() {
    presentation = .translationPopover(anchor(for: .translate))
  }

  func presentTranslationPrompt() {
    presentation = .translationPrompt(anchor(for: .translate))
  }

  func presentTranslationOptions(from anchor: Anchor? = nil) {
    presentation = .translationOptions(anchor ?? self.anchor(for: .translate))
  }

  func presentParticipantsPopover() {
    presentation = .participantsPopover(anchor(for: .participants))
  }

  func presentAddParticipants(from anchor: Anchor? = nil) {
    presentation = .addParticipants(anchor ?? self.anchor(for: .participants))
  }

  func dismissPresentation() {
    presentation = nil
  }

  private func anchor(for button: ToolbarButton) -> Anchor {
    visibleButtons.contains(button) ? .button(button) : .title
  }
}
